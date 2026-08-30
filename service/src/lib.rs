pub mod api;
pub mod appserver;
pub mod bridge;
pub mod config;
pub mod engine;
pub mod features;
pub mod observer;
pub mod protocol;
pub mod relay;
pub mod store;

pub const BUILD_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const PROTOCOL_VERSION: u16 = 2;
