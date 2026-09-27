# sprite-direct

Rust client for the `sprite-direct` Emacs server wire protocol (see
`../fixtures/CONTRACT.md`). Default build has zero dependencies beyond
`std`; only a blocking `eval_blocking` is provided (no `tokio`/async
feature, per the CONTRACT's async policy for Rust).

## Usage

```rust
use std::time::Duration;
use sprite_direct::sexp::Sexp;

fn main() {
    let form = Sexp::List(vec![
        Sexp::Sym("+".to_string()),
        Sexp::Int(1),
        Sexp::Int(2),
    ]);

    // Unix socket target: no auth key needed (Emacs 29+ authenticates
    // via peer UID).
    let result = sprite_direct::eval_blocking(
        "/run/user/1000/emacs/server",
        &form,
        None,
        Some(Duration::from_secs(5)),
    );

    match result {
        Ok(value) => println!("{value}"),
        Err(err) => eprintln!("error: {err}"),
    }
}
```

A TCP target is a `HOST:PORT` or `HOST:PORT:KEY` string; a missing key
(from either the target string or the `key` argument) is rejected with
`SpriteError::MissingAuthKey` before any connection is attempted. TCP
is trusted-network-only: the key is sent in the clear in every
request, and there is no TLS layer, matching the Elisp reference
implementation's own assumption.

## Example CLI

```sh
cargo run --example sprite-cli --features cli-example -- <target> [--key KEY]
```

This is illustrative only (not the production CLI tool). It is gated
behind the `cli-example` feature and its `clap` dependency so a plain
`cargo add sprite-direct` never pulls it in.

## Testing

`tests/protocol.rs` loads and iterates `../fixtures/protocol.json`'s
three sections (`encode_decode`, `sexp_print`, `response_reassembly`)
rather than hand-copying cases. `serde`/`serde_json` are
dev-dependencies used only to parse that fixture file in tests; they
are not part of the shipped library.

Live-daemon integration tests (against a real `emacs --daemon`) are a
follow-up — no daemon is assumed available in this sandbox. The
socket-opening step is isolated behind a single seam
(`Target::connect` in `src/lib.rs`) specifically so that's easy to add
later.
