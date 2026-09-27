//! Reproduces sprite.el's `sprite-open-frame` (sprite.el:687): does NOT
//! use the sprite-direct socket protocol at all -- shells out to a real
//! `emacsclient --no-wait --create-frame`, setting DISPLAY (defaulting
//! to ":0" when unset) and unsetting TERM in the child's environment,
//! exactly mirroring sprite.el's `with-environment-variables` block.
//! This is the one example that is a documented exception to the
//! direct-socket protocol, matching sprite.el's own approach.
//!
//! This is illustrative only, not a production tool.
//!
//! Run with:
//!
//! ```sh
//! cargo run --example open_frame --features cli-example -- <socket-name>
//! ```

use clap::Parser;
use std::process::Command;

#[derive(Parser, Debug)]
#[command(about = "Open a new emacsclient frame connected to a sprite daemon")]
struct Args {
    /// Socket name (or full path) to address via emacsclient --socket-name.
    name: String,
}

fn main() {
    let args = Args::parse();

    // Simplification: sprite.el resolves the address args via
    // `sprite--emacsclient-address-args', which picks `--server-file'
    // for TCP-registered daemons and `--socket-name' for Unix-socket
    // ones. This example doesn't have access to that infrastructure (or
    // to `server-use-tcp''s value), so a bare `--socket-name=<name>' is
    // used unconditionally; a real caller against a TCP-registered
    // daemon would need `--server-file' instead.
    let address_arg = format!("--socket-name={}", args.name);

    let display = std::env::var("DISPLAY").unwrap_or_else(|_| ":0".to_string());

    let status = Command::new("emacsclient")
        .arg("--no-wait")
        .arg("--create-frame")
        .arg(address_arg)
        .env_remove("TERM")
        .env("DISPLAY", display)
        .status();

    match status {
        Ok(status) if status.success() => println!("frame requested"),
        Ok(status) => {
            eprintln!("open_frame: emacsclient exited with {status}");
            std::process::exit(1);
        }
        Err(err) => {
            eprintln!("open_frame: failed to run emacsclient: {err}");
            std::process::exit(1);
        }
    }
}
