//! Evaluates `(FUNC arg1 arg2 ...)` against a running sprite daemon,
//! mirroring `cmd/sprite/call.go`'s `runCall`: FUNC and a JSON array of
//! arguments are given as CLI args, translated to `Sexp` values, and
//! the raw eval result is printed.
//!
//! This is illustrative only, not a production tool.
//!
//! Run with:
//!
//! ```sh
//! cargo run --example call_with_args --features cli-example -- <target> <func> '<json-args-array>'
//! ```

use clap::Parser;
use serde_json::Value;
use sprite_direct::sexp::Sexp;

#[derive(Parser, Debug)]
#[command(about = "Call FUNC with JSON-translated arguments in a sprite-direct target")]
struct Args {
    /// Unix socket path, or a TCP `HOST:PORT` / `HOST:PORT:KEY` string.
    target: String,

    /// Function name to call.
    func: String,

    /// JSON array of arguments, e.g. `[1, "a", true]`.
    args_json: String,
}

/// Mirrors `cmd/sprite/args.go`'s `TranslateArgsJSON`/`jsonToSexp`:
/// translates a top-level JSON array into a `Vec<Sexp>` (string -> Str,
/// integer -> Int, float -> Float, true/false/null -> Sym("t")/Sym("nil"),
/// array -> a quoted list).
fn translate_args_json(raw: &str) -> Result<Vec<Sexp>, String> {
    if raw.trim().is_empty() {
        return Ok(Vec::new());
    }
    let values: Vec<Value> = serde_json::from_str(raw)
        .map_err(|e| format!("parsing args JSON (expected a JSON array): {e}"))?;
    values.iter().map(json_to_sexp).collect()
}

fn json_to_sexp(v: &Value) -> Result<Sexp, String> {
    match v {
        Value::Null => Ok(Sexp::Sym("nil".to_string())),
        Value::Bool(b) => Ok(Sexp::Sym(if *b { "t" } else { "nil" }.to_string())),
        Value::String(s) => Ok(Sexp::Str(s.clone())),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(Sexp::Int(i))
            } else if let Some(f) = n.as_f64() {
                Ok(Sexp::Float(f))
            } else {
                Err(format!("unsupported JSON number: {n}"))
            }
        }
        Value::Array(items) => {
            let elems: Result<Vec<Sexp>, String> = items.iter().map(json_to_sexp).collect();
            let mut list = vec![Sexp::Sym("quote".to_string())];
            list.push(Sexp::List(elems?));
            Ok(Sexp::List(list))
        }
        Value::Object(_) => Err("unsupported JSON value: object".to_string()),
    }
}

fn main() {
    let args = Args::parse();

    let arg_sexps = match translate_args_json(&args.args_json) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("call_with_args: error: {e}");
            std::process::exit(1);
        }
    };

    let mut items = vec![Sexp::Sym(args.func.clone())];
    items.extend(arg_sexps);
    let form = Sexp::List(items);

    match sprite_direct::eval_blocking(&args.target, &form, None, None) {
        Ok(value) => println!("{value}"),
        Err(err) => {
            eprintln!("call_with_args: error: {err}");
            std::process::exit(1);
        }
    }
}
