//! Minimal example CLI demonstrating `sprite-direct` end to end.
//!
//! This is illustrative only, not a production tool. It connects to a
//! target given on the command line, builds `(+ 1 2)` via the sexp
//! builder, and prints the evaluated result or the error.
//!
//! `clap` is used here purely for example ergonomics; it is gated
//! behind the `cli-example` feature and does not affect a consumer who
//! just `cargo add sprite-direct`s the library.
//!
//! Run with:
//!
//! ```sh
//! cargo run --example sprite-cli --features cli-example -- <target> [--key KEY]
//! ```

use std::time::Duration;

use clap::Parser;
use sprite_direct::sexp::Sexp;

#[derive(Parser, Debug)]
#[command(about = "Evaluate a sample form in a sprite-direct target")]
struct Args {
    /// Unix socket path, or a TCP `HOST:PORT` / `HOST:PORT:KEY` string.
    target: String,

    /// Auth key. Required for TCP targets that don't embed one;
    /// ignored (or sent as `-auth`) for Unix socket targets.
    #[arg(long)]
    key: Option<String>,

    /// Read timeout in seconds.
    #[arg(long)]
    timeout: Option<u64>,
}

fn main() {
    let args = Args::parse();

    let form = Sexp::List(vec![
        Sexp::Sym("+".to_string()),
        Sexp::Int(1),
        Sexp::Int(2),
    ]);

    let timeout = args.timeout.map(Duration::from_secs);

    match sprite_direct::eval_blocking(&args.target, &form, args.key.as_deref(), timeout) {
        Ok(value) => {
            println!("{value}");
        }
        Err(err) => {
            eprintln!("sprite-cli: error: {err}");
            std::process::exit(1);
        }
    }
}
