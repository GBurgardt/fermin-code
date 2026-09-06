use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

pub const REQUIRED_TEST_MODEL: &str = "gpt-5.6-luna";
pub const REQUIRED_TEST_EFFORT: &str = "high";
pub const DEFAULT_SESSION_MODEL: &str = "gpt-5.6-sol";
pub const DEFAULT_SESSION_EFFORT: &str = "max";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineConfig {
    #[serde(default = "default_engine_bind")]
    pub bind: SocketAddr,
    #[serde(default = "default_engine_id")]
    pub engine_id: String,
    #[serde(default = "default_codex_path")]
    pub codex_path: PathBuf,
    #[serde(default = "default_engine_database")]
    pub database_path: PathBuf,
    pub auth_token_file: PathBuf,
    #[serde(default = "default_workspace_roots")]
    pub workspace_roots: Vec<PathBuf>,
    #[serde(default)]
    pub discovery_roots: Vec<PathBuf>,
    #[serde(default = "default_model")]
    pub default_model: String,
    #[serde(default = "default_effort")]
    pub default_effort: String,
    #[serde(default = "default_max_body_bytes")]
    pub max_body_bytes: usize,
    #[serde(default = "default_max_jsonl_bytes")]
    pub max_jsonl_bytes: usize,
    #[serde(default = "default_heartbeat_seconds")]
    pub heartbeat_seconds: u64,
    #[serde(default)]
    pub relay: Option<RelayClientConfig>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayConfig {
    #[serde(default = "default_relay_bind")]
    pub bind: SocketAddr,
    #[serde(default = "default_relay_database")]
    pub database_path: PathBuf,
    pub auth_token_file: PathBuf,
    pub engine_token_file: PathBuf,
    #[serde(default = "default_heartbeat_seconds")]
    pub heartbeat_seconds: u64,
    #[serde(default = "default_engine_lease_seconds")]
    pub engine_lease_seconds: u64,
    #[serde(default = "default_max_body_bytes")]
    pub max_body_bytes: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayClientConfig {
    pub url: String,
    pub token_file: PathBuf,
    #[serde(default = "default_reconnect_min_ms")]
    pub reconnect_min_ms: u64,
    #[serde(default = "default_reconnect_max_ms")]
    pub reconnect_max_ms: u64,
}

impl EngineConfig {
    pub fn load(path: &Path) -> Result<Self> {
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("read engine config {}", path.display()))?;
        let config: Self = toml::from_str(&raw)
            .with_context(|| format!("parse engine config {}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        validate_loopback(self.bind, "engine.bind")?;
        validate_secret_file(&self.auth_token_file, "authTokenFile")?;
        if self.engine_id.trim().is_empty() {
            bail!("engineId must not be empty");
        }
        if self.workspace_roots.is_empty() {
            bail!("workspaceRoots must contain at least one absolute path");
        }
        for root in &self.workspace_roots {
            if !root.is_absolute() {
                bail!("workspace root must be absolute: {}", root.display());
            }
        }
        for root in &self.discovery_roots {
            if !root.is_absolute() {
                bail!("discovery root must be absolute: {}", root.display());
            }
        }
        if self.default_model.to_ascii_lowercase().contains("grok")
            || self.default_model.to_ascii_lowercase().contains("xai")
        {
            bail!("Grok/xAI models are not supported");
        }
        validate_common_limits(self.max_body_bytes, self.heartbeat_seconds, "engine")?;
        if !(64 * 1024..=64 * 1024 * 1024).contains(&self.max_jsonl_bytes) {
            bail!("engine.maxJsonlBytes must be between 64 KiB and 64 MiB");
        }
        if let Some(relay) = &self.relay {
            validate_secret_file(&relay.token_file, "relay.tokenFile")?;
            validate_relay_url(&relay.url)?;
            if relay.reconnect_min_ms == 0 {
                bail!("relay.reconnectMinMs must be greater than zero");
            }
            if relay.reconnect_max_ms < relay.reconnect_min_ms {
                bail!("relay.reconnectMaxMs must be at least relay.reconnectMinMs");
            }
        }
        Ok(())
    }

    pub fn heartbeat_interval(&self) -> Duration {
        Duration::from_secs(self.heartbeat_seconds.clamp(2, 20))
    }
}

impl RelayConfig {
    pub fn load(path: &Path) -> Result<Self> {
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("read relay config {}", path.display()))?;
        let config: Self = toml::from_str(&raw)
            .with_context(|| format!("parse relay config {}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        validate_loopback(self.bind, "relay.bind")?;
        validate_secret_file(&self.auth_token_file, "authTokenFile")?;
        validate_secret_file(&self.engine_token_file, "engineTokenFile")?;
        validate_common_limits(self.max_body_bytes, self.heartbeat_seconds, "relay")?;
        if self.engine_lease_seconds < self.heartbeat_seconds.saturating_mul(2) {
            bail!("relay.engineLeaseSeconds must be at least two heartbeat intervals");
        }
        Ok(())
    }
}

fn validate_common_limits(max_body_bytes: usize, heartbeat_seconds: u64, role: &str) -> Result<()> {
    if !(1024 * 1024..=128 * 1024 * 1024).contains(&max_body_bytes) {
        bail!("{role}.maxBodyBytes must be between 1 MiB and 128 MiB");
    }
    if !(2..=20).contains(&heartbeat_seconds) {
        bail!("{role}.heartbeatSeconds must be between 2 and 20");
    }
    Ok(())
}

pub fn read_secret(path: &Path) -> Result<String> {
    validate_secret_file(path, "secret")?;
    let metadata = std::fs::symlink_metadata(path)
        .with_context(|| format!("inspect secret file {}", path.display()))?;
    if !metadata.file_type().is_file() {
        bail!("secret path {} must be a regular file", path.display());
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & 0o077 != 0 {
        bail!(
            "secret file {} must not be accessible by group or others",
            path.display()
        );
    }
    let value = std::fs::read_to_string(path)
        .with_context(|| format!("read secret file {}", path.display()))?;
    let value = value.trim().to_owned();
    if value.len() < 32 {
        bail!(
            "secret in {} must contain at least 32 characters",
            path.display()
        );
    }
    Ok(value)
}

fn validate_loopback(bind: SocketAddr, field: &str) -> Result<()> {
    if !bind.ip().is_loopback() {
        bail!("{field} must bind to loopback, got {bind}");
    }
    Ok(())
}

fn validate_secret_file(path: &Path, field: &str) -> Result<()> {
    if !path.is_absolute() {
        bail!("{field} must be an absolute path");
    }
    Ok(())
}

fn validate_relay_url(raw: &str) -> Result<()> {
    let url = url::Url::parse(raw).with_context(|| "relay.url must be a valid URL")?;
    if !url.username().is_empty() || url.password().is_some() {
        bail!("relay.url must not contain credentials");
    }
    if url.fragment().is_some() {
        bail!("relay.url must not contain a fragment");
    }
    let host = url
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("relay.url must contain a host"))?;
    match url.scheme() {
        "wss" => Ok(()),
        "ws" if is_loopback_host(host) => Ok(()),
        _ => bail!("relay URL must use wss:// unless it is loopback testing"),
    }
}

fn is_loopback_host(host: &str) -> bool {
    let unbracketed = host
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .unwrap_or(host);
    unbracketed.eq_ignore_ascii_case("localhost")
        || unbracketed
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

fn default_engine_bind() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 8841)
}

fn default_relay_bind() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 8840)
}

fn default_engine_id() -> String {
    "local-mac".to_owned()
}

fn default_codex_path() -> PathBuf {
    PathBuf::from("codex")
}

fn default_engine_database() -> PathBuf {
    PathBuf::from("fermin-engine.sqlite3")
}

fn default_relay_database() -> PathBuf {
    PathBuf::from("fermin-relay.sqlite3")
}

fn default_workspace_roots() -> Vec<PathBuf> {
    let root = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("projects"))
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("/"));
    vec![root]
}

fn default_model() -> String {
    DEFAULT_SESSION_MODEL.to_owned()
}

fn default_effort() -> String {
    DEFAULT_SESSION_EFFORT.to_owned()
}

fn default_max_body_bytes() -> usize {
    52 * 1024 * 1024
}

fn default_max_jsonl_bytes() -> usize {
    64 * 1024 * 1024
}

fn default_heartbeat_seconds() -> u64 {
    10
}

fn default_engine_lease_seconds() -> u64 {
    30
}

fn default_reconnect_min_ms() -> u64 {
    250
}

fn default_reconnect_max_ms() -> u64 {
    30_000
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn shipped_examples_form_one_local_pair_with_separate_credentials() {
        let engine: EngineConfig =
            toml::from_str(include_str!("../config/engine.example.toml")).unwrap();
        let relay: RelayConfig =
            toml::from_str(include_str!("../config/relay.example.toml")).unwrap();
        engine.validate().unwrap();
        relay.validate().unwrap();
        let bridge = engine.relay.as_ref().unwrap();
        assert_eq!(bridge.url, format!("ws://{}/v1/engine/connect", relay.bind));
        assert_eq!(bridge.token_file, relay.engine_token_file);
        assert_ne!(engine.bind, relay.bind);
        assert_ne!(engine.database_path, relay.database_path);
        assert_eq!(engine.database_path.parent(), relay.database_path.parent());
        assert_ne!(engine.auth_token_file, relay.auth_token_file);
        assert_ne!(engine.auth_token_file, relay.engine_token_file);
        assert_ne!(relay.auth_token_file, relay.engine_token_file);
    }

    #[test]
    fn rejects_non_loopback_bind() {
        assert!(validate_loopback("0.0.0.0:8840".parse().unwrap(), "bind").is_err());
    }

    #[test]
    fn default_session_policy_is_sol_max() {
        assert_eq!(default_model(), "gpt-5.6-sol");
        assert_eq!(default_effort(), "max");
    }

    #[test]
    fn common_runtime_limits_fail_closed() {
        assert_eq!(default_max_jsonl_bytes(), 64 * 1024 * 1024);
        assert!(validate_common_limits(1024 * 1024, 2, "test").is_ok());
        assert!(validate_common_limits(1024 * 1024 - 1, 2, "test").is_err());
        assert!(validate_common_limits(1024 * 1024, 1, "test").is_err());
        assert!(validate_common_limits(129 * 1024 * 1024, 10, "test").is_err());
    }

    #[test]
    fn relay_url_requires_tls_except_for_exact_loopback_hosts() {
        assert!(validate_relay_url("wss://relay.example.com/fermin-code").is_ok());
        assert!(validate_relay_url("ws://127.0.0.1:8840/test").is_ok());
        assert!(validate_relay_url("ws://[::1]:8840/test").is_ok());
        assert!(validate_relay_url("ws://localhost:8840/test").is_ok());
        assert!(validate_relay_url("ws://127.0.0.1.example:8840/test").is_err());
        assert!(validate_relay_url("ws://10.42.0.2:8840/test").is_err());
        assert!(validate_relay_url("https://relay.example.com/fermin-code").is_err());
        assert!(validate_relay_url("wss://token@relay.example.com/test").is_err());
        assert!(validate_relay_url("wss://relay.example.com/test#fragment").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn secret_files_must_be_private_regular_files() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("token");
        fs::write(&path, "01234567890123456789012345678901\n").unwrap();

        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            read_secret(&path).unwrap(),
            "01234567890123456789012345678901"
        );

        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        assert!(read_secret(&path).is_err());
        assert!(read_secret(directory.path()).is_err());
    }
}
