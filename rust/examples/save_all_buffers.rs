//! Evaluates `(save-some-buffers t)` against a running sprite daemon
//! and prints a one-line confirmation.
//!
//! This is illustrative only, not a production tool.
//!
//! Run with:
//!
//! ```sh
//! cargo run --example save_all_buffers --features cli-example -- <target>
//! ```

use clap::Parser;
use sprite_direct::sexp::Sexp;

#[derive(Parser, Debug)]
#[command(about = "Save all buffers in a sprite-direct target")]
struct Args {
    /// Unix socket path, or a TCP `HOST:PORT` / `HOST:PORT:KEY` string.
    target: String,
}

fn main() {
    let args = Args::parse();

    let form = Sexp::List(vec![
        Sexp::Sym("save-some-buffers".to_string()),
        Sexp::Sym("t".to_string()),
    ]);

    match sprite_direct::eval_blocking(&args.target, &form, None, None) {
        Ok(_) => println!("buffers saved"),
        Err(err) => {
            eprintln!("save_all_buffers: error: {err}");
            std::process::exit(1);
        }
    }
}
