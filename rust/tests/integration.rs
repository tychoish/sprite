//! Live-daemon integration test: exercises eval_blocking against a
//! real `emacs --daemon`, not a fake socket server. Gated on
//! SPRITE_TEST_SOCKET (the resolved Unix-socket path of an
//! already-running daemon), so it is skipped by default in any
//! environment without one -- CI sets this env var after spawning a
//! dedicated test daemon; see .github/workflows/test.yml.

use std::time::Duration;

use sprite_direct::sexp::Sexp;
use sprite_direct::{eval_blocking, SpriteError};

mod common;
use common::{emacs_path, unique_name, TcpDaemon, UnixDaemon};

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

#[test]
fn wrong_type_argument_eval_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test");
        return;
    };

    // (+ 1 "a") is a genuine wrong-type-argument error, distinct in
    // message shape from the unbound-variable case above -- confirms
    // the error path decodes whatever message Emacs actually sends,
    // rather than being hardcoded to one string.
    let form = list(vec![
        Sexp::Sym("+".into()),
        Sexp::Int(1),
        Sexp::Str("a".into()),
    ]);
    match eval_blocking(&socket, &form, None, None) {
        Err(SpriteError::Eval(msg)) => {
            assert!(!msg.is_empty(), "expected a non-empty decoded error message");
        }
        other => panic!("expected Eval error, got {other:?}"),
    }
}

#[test]
fn user_error_eval_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test");
        return;
    };

    // A genuine (user-error "boom") must surface via the same
    // -error/SpriteError::Eval path as any other eval error, not be
    // silently swallowed or routed differently.
    let form = list(vec![Sexp::Sym("user-error".into()), Sexp::Str("boom".into())]);
    match eval_blocking(&socket, &form, None, None) {
        Err(SpriteError::Eval(msg)) => {
            assert!(msg.contains("boom"), "{msg}");
        }
        other => panic!("expected Eval error, got {other:?}"),
    }
}

#[test]
fn large_value_eval_spans_print_nonl_continuation_lines_against_live_daemon() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test");
        return;
    };

    // A 5000-byte string is well beyond Emacs's server-msg-size
    // (1024), forcing the server to split the -print-nonl reply
    // across multiple continuation lines. 120 is the char code for
    // ?x. The result is pp/prin1-quoted, so assert on length/content
    // rather than exact equality.
    let form = list(vec![
        Sexp::Sym("make-string".into()),
        Sexp::Int(5000),
        Sexp::Int(120),
    ]);
    let result = eval_blocking(&socket, &form, None, None).expect("eval_blocking failed");
    let x_count = result.matches('x').count();
    assert_eq!(x_count, 5000, "result: {result}");
    assert!(result.starts_with("\"x"), "{result}");
    assert!(result.ends_with("x\""), "{result}");
}

// --- Disposable-daemon cases for TCP and destructive scenarios ---
//
// These spawn their own emacs daemons (via the shared helpers in
// tests/common/mod.rs) rather than relying on SPRITE_TEST_SOCKET, so
// they're gated independently on the `emacs` binary being on PATH, not
// on SPRITE_TEST_SOCKET.

#[test]
fn tcp_target_no_key_rejected_before_dialing_against_live_daemon() {
    let Some(emacs) = emacs_path() else {
        eprintln!("emacs binary not found on PATH; skipping live-daemon integration test");
        return;
    };
    let name = unique_name("rn");
    let mut daemon = match TcpDaemon::spawn(&emacs, &name) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("could not start disposable TCP daemon: {e}");
            return;
        }
    };

    // Deliberately omit the key: a TCP target the daemon requires a
    // real auth key for must be rejected client-side before any
    // connection is attempted, confirmed here against a live,
    // key-configured TCP daemon rather than only a fake transport.
    let target = format!("{}:{}", daemon.host, daemon.port);
    let form = Sexp::Sym("t".into());
    let result = eval_blocking(&target, &form, None, None);
    assert!(
        matches!(result, Err(SpriteError::MissingAuthKey)),
        "expected MissingAuthKey, got {result:?}"
    );

    daemon.kill();
}

#[test]
fn tcp_target_with_key_round_trips_against_live_daemon() {
    let Some(emacs) = emacs_path() else {
        eprintln!("emacs binary not found on PATH; skipping live-daemon integration test");
        return;
    };
    let name = unique_name("rk");
    let mut daemon = match TcpDaemon::spawn(&emacs, &name) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("could not start disposable TCP daemon: {e}");
            return;
        }
    };

    let target = format!("{}:{}", daemon.host, daemon.port);
    let form = list(vec![Sexp::Sym("+".into()), Sexp::Int(1), Sexp::Int(2)]);
    let result = eval_blocking(&target, &form, Some(&daemon.key), None).expect("eval_blocking failed");
    assert_eq!(result, "3");

    daemon.kill();
}

#[test]
fn daemon_killed_mid_response_raises_clean_error_against_live_daemon() {
    let Some(emacs) = emacs_path() else {
        eprintln!("emacs binary not found on PATH; skipping live-daemon integration test");
        return;
    };
    let name = unique_name("rd");
    let mut daemon = match UnixDaemon::spawn(&emacs, &name) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("could not start disposable daemon: {e}");
            return;
        }
    };

    // SIGSTOP the daemon *before* eval_blocking ever connects, then
    // SIGKILL it a moment later from a background thread. This
    // sidesteps any race over exactly when the request bytes are
    // handed to the kernel: a Unix-domain stream connection is
    // accepted into the listening socket's kernel backlog as soon as
    // connect() is called, without requiring the (stopped, and so
    // unable to run) daemon process to call accept() itself, so the
    // client's connect() and write() both succeed immediately even
    // though the daemon can't read anything -- guaranteeing unread
    // data sits in the kernel receive buffer when SIGKILL later closes
    // the socket. An unread receive buffer at close time is what makes
    // the kernel send a reset (surfaced here as SpriteError::Io
    // wrapping a connection-reset error) instead of a plain close,
    // which is what a live kill at some arbitrary later point (once
    // Emacs has actually read and is busy evaluating) would otherwise
    // produce indistinguishably from a normal completed response.
    let pid = daemon.child.id();
    let _ = std::process::Command::new("kill")
        .args(["-STOP", &pid.to_string()])
        .status();

    let killer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        let _ = std::process::Command::new("kill")
            .args(["-KILL", &pid.to_string()])
            .status();
    });

    let form = list(vec![
        Sexp::Sym("progn".into()),
        list(vec![Sexp::Sym("sleep-for".into()), Sexp::Int(2)]),
        Sexp::Int(1),
    ]);
    let result = eval_blocking(
        daemon.sock_str(),
        &form,
        None,
        Some(Duration::from_secs(10)),
    );

    killer.join().expect("killer thread panicked");

    assert!(
        matches!(result, Err(SpriteError::Io(_))),
        "expected a clean SpriteError::Io after killing the daemon mid-response, got {result:?}"
    );

    daemon.kill();
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
