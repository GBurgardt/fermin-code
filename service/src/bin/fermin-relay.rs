use std::path::PathBuf;

use clap::Parser;
use fermin_code::config::RelayConfig;

#[derive(Parser)]
#[command(name = "fermin-relay", version, about = "Fermín Code public relay")]
struct Args {
    #[arg(long, env = "FERMIN_RELAY_CONFIG")]
    config: PathBuf,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    fermin_code::engine::init_tracing();
    let args = Args::parse();
    let config = RelayConfig::load(&args.config)?;
    fermin_code::relay::run(config).await
}
