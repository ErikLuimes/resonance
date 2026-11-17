//! `resonance-mcp`: the MCP server alone, in the App Sandbox. An assistant
//! drives it, and tune text reaches the assistant, so this part gets no more
//! than the socket to the app: no files, no terminal. `resonance mcp` hands
//! over to it.

// Shared with `resonance`, which uses more of it.
#[allow(dead_code)]
#[path = "client.rs"]
mod client;
#[path = "mcp.rs"]
mod mcp;

use std::process::ExitCode;

fn main() -> ExitCode {
    match mcp::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("resonance-mcp: {message}");
            ExitCode::FAILURE
        }
    }
}
