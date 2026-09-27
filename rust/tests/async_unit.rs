//! Fake-server, mocked unit-style tests for the async (tokio-backed)
//! non-blocking eval API. No live daemon required -- this whole file
//! only compiles/runs under `--features async` since it depends on
//! `sprite_direct::async_eval`, which is itself feature-gated in the
//! library.
//!
//! There is no dialer/stream-override seam exposed by this crate the
//! way e.g. the Go client's `WithDialer` is (see `Target::connect` in
//! `src/lib.rs`, private to the crate). The pragmatic workaround used
//! here: spin up a real `std::net::TcpListener` on `127.0.0.1:0` in a
//! background thread per fake server, and reply based on hand-parsing
//! the incoming `-auth KEY -eval ENCODED_FORM \n` request text (using
//! the crate's own public `protocol::decode`/`protocol::encode` to
//! undo/redo wire quoting). A TCP target always requires an auth key,
//! so every fake-server test dials `127.0.0.1:<port>:test-key`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use sprite_direct::async_eval::{eval_non_blocking, start_async, PollInterval};
use sprite_direct::protocol;
use sprite_direct::sexp::Sexp;
use sprite_direct::SpriteError;

/// A fake daemon: accepts TCP connections and answers each one-shot
/// `-eval` request with whatever `handler` returns for the decoded
/// (unencoded) form text, wrapped as a normal successful `-print`
/// reply (matching the CONTRACT's reassembly algorithm in
/// `protocol::parse_response`).
///
/// Every `sprite-async-start`/`sprite-async-poll` reply this crate
/// cares about *is* a normal successful eval reply -- `:rejected`/
/// `:unknown` are just print values whose text `async_wire` hand-parses,
/// not wire-level `-error` replies -- so a single reply shape covers
/// every scenario below.
struct FakeServer {
    port: u16,
}

impl FakeServer {
    fn start<F>(handler: F) -> FakeServer
    where
        F: Fn(&str) -> String + Send + Sync + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind fake server");
        let port = listener.local_addr().expect("local_addr").port();
        let handler = Arc::new(handler);
        std::thread::spawn(move || {
            for incoming in listener.incoming() {
                let Ok(stream) = incoming else { continue };
                let handler = Arc::clone(&handler);
                std::thread::spawn(move || serve_one(stream, &*handler));
            }
        });
        FakeServer { port }
    }

    /// A TCP target string embedding a key, since TCP targets always
    /// require one (see `SpriteError::MissingAuthKey`).
    fn target(&self) -> String {
        format!("127.0.0.1:{}:test-key", self.port)
    }
}

fn serve_one(mut stream: TcpStream, handler: &(dyn Fn(&str) -> String + Send + Sync)) {
    let request = read_request_line(&mut stream);
    if request.is_empty() {
        return;
    }
    let decoded_form = decode_eval_form(&request);
    let payload = handler(&decoded_form);

    let mut response = String::new();
    response.push_str("-emacs-pid 1\n");
    response.push_str("-print ");
    response.push_str(&protocol::encode(&payload));
    response.push('\n');

    let _ = stream.write_all(response.as_bytes());
    let _ = stream.shutdown(Shutdown::Write);
}

/// Read one request line (up to and including the trailing `\n` that
/// terminates every `-eval ... \n` request; see `eval_blocking` in
/// `src/lib.rs`).
fn read_request_line(stream: &mut TcpStream) -> String {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {
                buf.push(byte[0]);
                if buf.last() == Some(&b'\n') {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    String::from_utf8_lossy(&buf).into_owned()
}

/// Pull the `-eval ENCODED` payload out of a request line and
/// wire-decode it back to the printed Lisp form text, e.g.
/// `(sprite-async-poll "tok-1")`.
fn decode_eval_form(request: &str) -> String {
    match request.find("-eval ") {
        Some(idx) => {
            let after = &request[idx + "-eval ".len()..];
            let trimmed = after.strip_suffix(" \n").unwrap_or_else(|| after.trim_end());
            protocol::decode(trimmed)
        }
        None => String::new(),
    }
}

/// Extract the first quoted-string literal in `form`, e.g. the token
/// out of `(sprite-async-poll "tok-1")` -> `tok-1`.
fn extract_token(form: &str) -> Option<String> {
    let start = form.find('"')?;
    let rest = &form[start + 1..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

/// Extract the trailing run of ASCII digits before the form's closing
/// parens, e.g. out of `(sprite-async-start (quote 7))` -> `7`. Used
/// by the concurrency test to round-trip a per-call marker through the
/// quoted form without needing a full Lisp reader.
fn extract_trailing_number(form: &str) -> Option<i64> {
    let digits: String = form
        .chars()
        .rev()
        .skip_while(|c| *c == ')')
        .take_while(|c| c.is_ascii_digit())
        .collect();
    if digits.is_empty() {
        return None;
    }
    digits.chars().rev().collect::<String>().parse().ok()
}

#[tokio::test(flavor = "multi_thread")]
async fn eval_non_blocking_happy_path_resolves_after_pending() {
    let calls: Arc<Mutex<HashMap<String, u32>>> = Arc::new(Mutex::new(HashMap::new()));
    let token_counter = Arc::new(AtomicU64::new(0));

    let server = FakeServer::start(move |form| {
        if form.contains("sprite-async-start") {
            let n = token_counter.fetch_add(1, Ordering::SeqCst);
            format!("\"tok-{n}\"")
        } else if let Some(token) = extract_token(form) {
            let mut calls = calls.lock().expect("lock");
            let count = calls.entry(token).or_insert(0);
            *count += 1;
            if *count < 3 {
                "(:pending)".to_string()
            } else {
                "(:resolved 42)".to_string()
            }
        } else {
            "(:unknown)".to_string()
        }
    });

    let form = Sexp::List(vec![Sexp::Sym("+".to_string()), Sexp::Int(40), Sexp::Int(2)]);
    let result = eval_non_blocking(
        &server.target(),
        &form,
        None,
        None,
        None,
        Some(PollInterval::Fixed(Duration::from_millis(5))),
    )
    .await;

    assert_eq!(result.expect("eval_non_blocking failed"), "42");
}

#[tokio::test(flavor = "multi_thread")]
async fn eval_non_blocking_surfaces_rejected() {
    let server = FakeServer::start(|form| {
        if form.contains("sprite-async-start") {
            "\"tok-rejected\"".to_string()
        } else {
            "(:rejected \"boom\")".to_string()
        }
    });

    let form = Sexp::Sym("t".to_string());
    let result = eval_non_blocking(&server.target(), &form, None, None, None, None).await;

    match result {
        Err(SpriteError::AsyncRejected(msg)) => assert_eq!(msg, "boom"),
        other => panic!("expected AsyncRejected, got {other:?}"),
    }
    // Also exercised via Display, since the caller may just print it.
    let server2 = FakeServer::start(|form| {
        if form.contains("sprite-async-start") {
            "\"tok-rejected-2\"".to_string()
        } else {
            "(:rejected \"boom\")".to_string()
        }
    });
    let form = Sexp::Sym("t".to_string());
    let err = eval_non_blocking(&server2.target(), &form, None, None, None, None)
        .await
        .expect_err("expected an error");
    assert!(err.to_string().contains("boom"), "{err}");
}

#[tokio::test(flavor = "multi_thread")]
async fn eval_non_blocking_surfaces_unknown_token() {
    let server = FakeServer::start(|form| {
        if form.contains("sprite-async-start") {
            "\"tok-unknown\"".to_string()
        } else {
            "(:unknown)".to_string()
        }
    });

    let form = Sexp::Sym("t".to_string());
    let result = eval_non_blocking(&server.target(), &form, None, None, None, None).await;

    match result {
        Err(SpriteError::AsyncUnknownToken(token)) => assert_eq!(token, "tok-unknown"),
        other => panic!("expected AsyncUnknownToken, got {other:?}"),
    }
}

#[tokio::test]
async fn start_async_missing_auth_key_is_a_direct_sync_error() {
    // A TCP target string with no embedded key and none supplied: this
    // must fail synchronously inside eval_blocking, before any dial is
    // attempted, and must NOT be wrapped inside an AsyncHandle -- i.e.
    // start_async itself returns Err directly.
    let form = Sexp::Sym("t".to_string());
    let result = start_async("127.0.0.1:59999", &form, None, None, None, None).await;
    match result {
        Err(SpriteError::MissingAuthKey) => {}
        Ok(_) => panic!("expected MissingAuthKey, got Ok(AsyncHandle)"),
        Err(other) => panic!("expected MissingAuthKey, got {other:?}"),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn eval_non_blocking_concurrent_calls_do_not_cross_contaminate() {
    // The fake server round-trips a per-call marker: the client sends
    // `(sprite-async-start (quote N))`, the server mints a token
    // `tok-N` embedding it, and immediately resolves any poll for
    // `tok-N` to `N` -- so each of the concurrent calls below must get
    // back exactly its own N, never another call's.
    let server = FakeServer::start(|form| {
        if form.contains("sprite-async-start") {
            let n = extract_trailing_number(form).expect("no marker in start form");
            format!("\"tok-{n}\"")
        } else if let Some(token) = extract_token(form) {
            let n: i64 = token
                .strip_prefix("tok-")
                .expect("unexpected token shape")
                .parse()
                .expect("non-numeric token suffix");
            format!("(:resolved {n})")
        } else {
            "(:unknown)".to_string()
        }
    });

    let target = server.target();
    let mut handles = Vec::new();
    for i in 0..20i64 {
        let target = target.clone();
        handles.push(tokio::spawn(async move {
            let form = Sexp::Int(i);
            let result = eval_non_blocking(
                &target,
                &form,
                None,
                None,
                None,
                Some(PollInterval::Fixed(Duration::from_millis(1))),
            )
            .await;
            (i, result)
        }));
    }

    for handle in handles {
        let (i, result) = handle.await.expect("concurrent task panicked");
        assert_eq!(result.expect("eval_non_blocking failed"), i.to_string());
    }
}

/// Panic-to-`SpriteError` propagation.
///
/// `AsyncHandle::wait` and the private `eval_blocking_async` helper
/// both convert an unwrapped `JoinError` (from `tokio::task::spawn`
/// and `tokio::task::spawn_blocking` respectively) into
/// `SpriteError::TaskPanicked` -- see the doc comments in
/// `src/async_eval.rs`. Neither of those `JoinHandle`s is reachable
/// from outside the crate: `AsyncHandle` exposes only `.token()`/
/// `.wait()`, with no way to abort or otherwise force its inner task
/// to fail, and the sync `eval_blocking` this crate wraps has no
/// black-box-reachable panic path (no `unwrap`/index/slice operations
/// on attacker-controlled data on any code path exercised here). Full
/// black-box panic injection into that mapping therefore isn't
/// reachable from this test file.
///
/// The actual panic-to-`SpriteError::TaskPanicked` conversion (via the
/// private `flatten_join`/`spawn_blocking_result` helpers in
/// `src/async_eval.rs`) is covered directly by the internal unit test
/// `async_eval::tests::spawn_blocking_result_panic_becomes_task_panicked`
/// in that same file, which panics inside a real `spawn_blocking`
/// closure. The test below remains as the closest black-box,
/// external-boundary equivalent -- not as the only coverage for this
/// behavior: demonstrate that the general mechanism this mapping relies
/// on -- a `JoinHandle::await` on a cancelled/aborted task resolving to
/// `Err(JoinError)` rather than panicking the awaiter -- actually holds
/// for a task built the same way (`tokio::task::spawn` around an
/// `eval_non_blocking` call against a fake server that never resolves).
#[tokio::test(flavor = "multi_thread")]
async fn aborted_task_yields_join_error_not_a_propagated_panic() {
    let server = FakeServer::start(|form| {
        if form.contains("sprite-async-start") {
            "\"tok-hang\"".to_string()
        } else {
            // Never resolves; keeps the internal poll loop alive so
            // there is something in-flight to abort.
            "(:pending)".to_string()
        }
    });

    let target = server.target();
    let outer = tokio::spawn(async move {
        let form = Sexp::Sym("t".to_string());
        eval_non_blocking(
            &target,
            &form,
            None,
            None,
            None,
            Some(PollInterval::Fixed(Duration::from_secs(1))),
        )
        .await
    });

    // Give the poll loop time to start and issue at least one poll.
    tokio::time::sleep(Duration::from_millis(50)).await;
    outer.abort();

    let result = outer.await;
    let join_err = result.expect_err("expected the aborted task's JoinHandle to error");
    assert!(join_err.is_cancelled(), "{join_err}");
}
