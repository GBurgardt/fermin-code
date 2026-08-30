use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "ferminctl", version, about = "Fermín Code diagnostics")]
struct Args {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Doctor {
        #[arg(long, default_value = "codex")]
        codex: PathBuf,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match Args::parse().command {
        Command::Doctor { codex } => fermin_code::engine::doctor(codex).await,
    }
}
