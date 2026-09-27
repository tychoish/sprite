//! Live-daemon integration test: exercises eval_blocking against a
//! real `emacs --daemon`, not a fake socket server. Gated on
//! SPRITE_TEST_SOCKET (the resolved Unix-socket path of an
//! already-running daemon), so it is skipped by default in any
//! environment without one -- CI sets this env var after spawning a
//! dedicated test daemon; see .github/workflows/test.yml.

use sprite_direct::sexp::Sexp;
use sprite_direct::{eval_blocking, SpriteError};

fn list(items: Vec<Sexp>) -> Sexp {
    Sexp::List(items)
}

#[test]
fn arithmetic_eval_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test");
        return;
    };

    let form = list(vec![Sexp::Sym("+".into()), Sexp::Int(1), Sexp::Int(2)]);
    let result = eval_blocking(&socket, &form, None, None).expect("eval_blocking failed");
    assert_eq!(result, "3");

    let form = list(vec![
        Sexp::Sym("concat".into()),
        Sexp::Str("hello".into()),
        Sexp::Str(" world".into()),
    ]);
    let result = eval_blocking(&socket, &form, None, None).expect("eval_blocking failed");
    assert_eq!(result, "\"hello world\"");

    let form = list(vec![
        Sexp::Sym("list".into()),
        Sexp::Int(1),
        Sexp::Int(2),
        Sexp::Int(3),
    ]);
    let result = eval_blocking(&socket, &form, None, None).expect("eval_blocking failed");
    assert_eq!(result, "(1 2 3)");

    // A genuine evaluation error (an unbound variable): verified
    // against a live daemon that the server DOES send a real -error
    // line for this, but only if the client doesn't half-close its
    // write side after sending, and only if the client stops reading
    // as soon as a complete -error line is seen rather than waiting
    // for the socket to close (which the server delays by several
    // seconds after an error reply). See read_response's doc comment
    // in src/lib.rs and fixtures/CONTRACT.md.
    let form = Sexp::Sym("this-variable-does-not-exist-anywhere".into());
    match eval_blocking(&socket, &form, None, None) {
        Err(SpriteError::Eval(msg)) => {
            assert!(msg.contains("this-variable-does-not-exist-anywhere"), "{msg}");
        }
        other => panic!("expected Eval error, got {other:?}"),
    }
}
