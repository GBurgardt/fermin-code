use std::path::PathBuf;

use clap::Parser;
use fermin_code::config::EngineConfig;

#[derive(Parser)]
#[command(
    name = "fermin-engine",
    version,
    about = "Fermín Code App Server engine"
)]
struct Args {
    #[arg(long, env = "FERMIN_ENGINE_CONFIG")]
    config: PathBuf,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    fermin_code::engine::init_tracing();
    let args = Args::parse();
    let config = EngineConfig::load(&args.config)?;
    fermin_code::engine::run(config).await
}
