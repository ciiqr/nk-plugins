use anyhow::Error;
use camino::Utf8PathBuf;
use clap::{arg, Args, Parser, Subcommand};
use serde::Deserialize;

#[derive(Debug, Parser)]
#[command(about, version)]
pub struct Arguments {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Debug, Subcommand)]
pub enum Commands {
    Provision(Provision),
}

#[derive(Debug, Args)]
pub struct Provision {
    /// Provision info as json
    #[arg(value_name = "info", value_parser = ProvisionInfo::value_parser)]
    pub info: ProvisionInfo,
}

#[derive(Debug, Deserialize, Clone)]
pub struct ProvisionInfo {
    pub sources: Vec<Utf8PathBuf>,
    // pub vars: serde_json::Map<String, serde_json::Value>,
}

impl ProvisionInfo {
    fn value_parser(value: &str) -> Result<Self, Error> {
        Ok(serde_json::from_str(value)?)
    }
}
