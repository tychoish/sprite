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

// Async (tokio-backed) live-daemon tests, layered on top of the sync
// eval_blocking exercised above. These additionally require
// sprite-async.el to be loaded into the test daemon (see
// .github/workflows/test.yml); they follow the same SPRITE_TEST_SOCKET
// skip style as the sync test above (an early return with an eprintln,
// not #[ignore]).

#[cfg(feature = "async")]
use sprite_direct::async_eval::{eval_non_blocking, resume_future, start_async};

#[cfg(feature = "async")]
#[tokio::test]
async fn eval_async_happy_path_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon async integration test");
        return;
    };

    let form = list(vec![Sexp::Sym("+".into()), Sexp::Int(1), Sexp::Int(2)]);
    let result = eval_non_blocking(&socket, &form, None, None, None, None)
        .await
        .expect("eval_non_blocking failed");
    assert_eq!(result, "3");
}

#[cfg(feature = "async")]
#[tokio::test]
async fn eval_async_error_path_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon async integration test");
        return;
    };

    let form = Sexp::Sym("this-variable-does-not-exist-anywhere".into());
    match eval_non_blocking(&socket, &form, None, None, None, None).await {
        Err(err) => {
            let msg = err.to_string();
            assert!(
                msg.contains("this-variable-does-not-exist-anywhere"),
                "{msg}"
            );
        }
        Ok(value) => panic!("expected an error, got Ok({value:?})"),
    }
}

#[cfg(feature = "async")]
#[tokio::test(flavor = "multi_thread")]
async fn eval_async_concurrency_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon async integration test");
        return;
    };

    let mut handles = Vec::new();
    for i in 0..10i64 {
        let socket = socket.clone();
        handles.push(tokio::spawn(async move {
            let form = list(vec![Sexp::Sym("+".into()), Sexp::Int(i), Sexp::Int(100)]);
            let result = eval_non_blocking(&socket, &form, None, None, None, None).await;
            (i, result)
        }));
    }

    for handle in handles {
        let (i, result) = handle.await.expect("concurrent task panicked");
        assert_eq!(
            result.expect("eval_non_blocking failed"),
            (i + 100).to_string()
        );
    }
}

#[cfg(feature = "async")]
#[tokio::test]
async fn eval_async_resume_after_disconnect_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon async integration test");
        return;
    };

    let form = list(vec![
        Sexp::Sym("progn".into()),
        list(vec![Sexp::Sym("sleep-for".into()), Sexp::Int(1)]),
        Sexp::Int(99),
    ]);

    let handle = start_async(&socket, &form, None, None, None, None)
        .await
        .expect("start_async failed");
    let token = handle.token().to_string();
    // Drop the handle without awaiting it, simulating a disconnect:
    // the daemon-side registry keeps the token's result available
    // (see sprite-async.el), so a later, independent resume_future
    // call for the same token must still be able to observe it settle.
    drop(handle);

    let result = resume_future(&socket, &token, None, None, None)
        .await
        .expect("resume_future failed");
    assert_eq!(result, "99");
}
