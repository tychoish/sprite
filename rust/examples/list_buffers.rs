//! Evaluates `(mapcar #'buffer-name (buffer-list))` against a running
//! sprite daemon and prints each buffer name on its own line.
//!
//! This is illustrative only, not a production tool.
//!
//! Run with:
//!
//! ```sh
//! cargo run --example list_buffers --features cli-example -- <target>
//! ```

use clap::Parser;
use sprite_direct::sexp::Sexp;

#[derive(Parser, Debug)]
#[command(about = "List buffer names in a sprite-direct target")]
struct Args {
    /// Unix socket path, or a TCP `HOST:PORT` / `HOST:PORT:KEY` string.
    target: String,
}

/// Minimal, best-effort split of a printed Lisp list of strings, e.g.
/// `("*scratch*" "foo.txt")`, into its elements. This is NOT a general
/// Lisp reader (v1 of sprite-direct has none, per fixtures/CONTRACT.md)
/// -- it just strips the outer parens and splits on `" "` between
/// quoted strings. It will mis-parse buffer names that themselves
/// contain a `" ` sequence; that's an accepted limitation.
fn parse_buffer_name_list(raw: &str) -> Vec<String> {
    let s = raw.trim();
    let s = s.strip_prefix('(').unwrap_or(s);
    let s = s.strip_suffix(')').unwrap_or(s);
    if s.is_empty() {
        return Vec::new();
    }
    // Emacs's printer may wrap a long list's printed representation
    // across embedded newlines (observed against a live daemon);
    // collapse any run of whitespace between elements down to a single
    // space before the best-effort split below.
    let collapsed = s.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed
        .split("\" \"")
        .map(|p| p.trim_start_matches('"').trim_end_matches('"').to_string())
        .collect()
}

fn main() {
    let args = Args::parse();

    let form = Sexp::List(vec![
        Sexp::Sym("mapcar".to_string()),
        Sexp::List(vec![
            Sexp::Sym("function".to_string()),
            Sexp::Sym("buffer-name".to_string()),
        ]),
        Sexp::List(vec![Sexp::Sym("buffer-list".to_string())]),
    ]);

    match sprite_direct::eval_blocking(&args.target, &form, None, None) {
        Ok(value) => {
            for name in parse_buffer_name_list(&value) {
                println!("{name}");
            }
        }
        Err(err) => {
            eprintln!("list_buffers: error: {err}");
            std::process::exit(1);
        }
    }
}
