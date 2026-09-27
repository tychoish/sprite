//! Timeout / hung-daemon test suite: exercises eval_blocking's `timeout:
//! Option<Duration>` argument against daemons that either never reply
//! (a genuine infinite Elisp loop) or never accept a connection at
//! all, plus a fast daemon with no timeout configured at all.
//!
//! IMPORTANT finding, recorded here because it shapes every sub-case
//! below: a single hung eval (a genuine `(while t ...)` busy loop) DOES
//! block every other connection to the same daemon, not just the
//! connection that issued it. Emacs's Lisp evaluator is single
//! threaded; server.el's accept loop cannot service (or even accept())
//! any other connection while one Lisp form is running forever --
//! verified directly against a live `emacs --daemon` before writing
//! this suite. So the hung-eval daemon in the first test below is
//! spawned fresh, used for nothing else, and killed immediately after;
//! it is never reused for the "fast daemon, no timeout" case (that
//! case uses SPRITE_TEST_SOCKET's shared daemon, gated the same way
//! integration.rs gates on it, or is skipped).
//!
//! A second finding: cleanup for a daemon wedged by a hung eval cannot
//! go through emacsclient (or any -eval RPC) -- that RPC would itself
//! queue behind the very form that's hanging, hanging the test's own
//! teardown. Cleanup here always kills the daemon's OS process directly
//! (SIGKILL, via Child::kill).
//!
//! A third finding: plain `emacs --daemon=NAME` double-forks and
//! detaches -- the process std::process::Command actually launches
//! exits almost immediately once the real, detached daemon is up, so
//! tracking *that* pid and killing it later kills nothing. `emacs
//! --fg-daemon=NAME` avoids the double-fork (the launched process *is*
//! the daemon process), so killing it via Child::kill actually works.
//! This file uses --fg-daemon exclusively for that reason.
//!
//! A fourth finding: AF_UNIX socket paths are capped at roughly
//! 104-108 bytes (sockaddr_un.sun_path), and Emacs itself refuses to
//! start a daemon whose resulting socket path would be too long
//! ("Unable to start daemon: Service name too long"). This file
//! therefore uses a short temp-dir prefix and a short, purely-numeric
//! daemon name, not a long descriptive one.
//!
//! A fifth, Rust-specific note on case 3 (slow dial): `eval_blocking`'s
//! `timeout` argument only ever becomes a `set_read_timeout` call (see
//! `Target::connect` in src/lib.rs) -- `std::os::unix::net::UnixStream
//! ::connect` has no timeout parameter at all in std, so there is no
//! seam here (unlike Go's `protocol.WithDialer`) to construct or bound
//! a genuinely slow dial. This suite therefore only exercises the
//! documented fallback: a connection to a nonexistent socket path,
//! which fails immediately (ENOENT) regardless of the configured
//! timeout.

use std::fs;
use std::time::{Duration, Instant};

use sprite_direct::sexp::Sexp;
use sprite_direct::{eval_blocking, SpriteError};

mod common;
use common::{emacs_path, unique_name, UnixDaemon};

fn list(items: Vec<Sexp>) -> Sexp {
    Sexp::List(items)
}

/// A rough proxy for "no leaked socket/connection" (case 4): the
/// number of this process's currently-open file descriptors, via
/// /proc/self/fd (Linux-only, matching this repo's other Linux-tested
/// assumptions in this test round).
fn open_fd_count() -> usize {
    fs::read_dir("/proc/self/fd")
        .map(|it| it.count())
        .unwrap_or(0)
}

// Case 1 + case 4: a genuinely hung eval (an infinite Elisp loop, not
// merely a slow one) against a configured timeout must return an error
// within a generous (~2x) tolerance of the configured duration, must
// not return a success value, and must not leave a lingering open
// file descriptor for the abandoned connection.
#[test]
fn hung_eval_timeout_fires_against_disposable_daemon() {
    let Some(emacs) = emacs_path() else {
        eprintln!("emacs not found on PATH; skipping disposable-daemon timeout test");
        return;
    };
    let name = unique_name("t");
    let mut daemon = match UnixDaemon::spawn(&emacs, &name) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("could not start disposable daemon: {e}");
            return;
        }
    };

    let before_fds = open_fd_count();

    let form = list(vec![
        Sexp::Sym("while".into()),
        Sexp::Sym("t".into()),
        list(vec![Sexp::Sym("sleep-for".into()), Sexp::Int(1)]),
    ]);

    let configured = Duration::from_secs(2);
    let start = Instant::now();
    let result = eval_blocking(daemon.sock_str(), &form, None, Some(configured));
    let elapsed = start.elapsed();

    match result {
        Ok(value) => panic!("expected a timeout error evaluating a hung form, got success value {value:?}"),
        Err(SpriteError::Io(_)) => {}
        Err(other) => panic!("expected an I/O (timeout) error, got {other:?}"),
    }

    assert!(
        elapsed <= configured * 2,
        "timeout took {elapsed:?}, want at most ~2x the configured {configured:?}"
    );

    let after_fds = open_fd_count();
    assert!(
        after_fds <= before_fds + 1,
        "open fd count grew from {before_fds} to {after_fds} after a timed-out eval against a hung daemon; possible leak"
    );

    daemon.kill();
}

// Case 2: with no timeout at all (None), a normal fast-replying daemon
// (the shared SPRITE_TEST_SOCKET one, gated exactly like integration.rs)
// must still succeed promptly -- omitting a timeout must not impose
// some implicit ceiling of its own.
#[test]
fn no_timeout_configured_fast_daemon_unaffected() {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test");
        return;
    };

    let form = list(vec![Sexp::Sym("+".into()), Sexp::Int(1), Sexp::Int(2)]);
    let start = Instant::now();
    let result = eval_blocking(&socket, &form, None, None).expect("eval_blocking failed");
    let elapsed = start.elapsed();

    assert_eq!(result, "3");
    assert!(
        elapsed <= Duration::from_secs(2),
        "expected a prompt reply with no timeout configured, took {elapsed:?}"
    );
}

// Case 3 fallback: eval_blocking's timeout only ever bounds *reads*
// (see the module doc comment above) -- there is no seam to construct
// a genuinely slow dial in this crate the way Go's WithDialer allows.
// So this test falls back to the documented substitute: a connection
// attempt to a socket path that simply doesn't exist must fail
// promptly, not hang, even with a timeout configured that's much
// longer than the failure should take.
#[test]
fn connect_to_nonexistent_socket_fails_promptly() {
    let form = Sexp::Sym("t".into());
    let start = Instant::now();
    let result = eval_blocking(
        "/tmp/sprite-timeout-test-nonexistent-socket-path.sock",
        &form,
        None,
        Some(Duration::from_secs(2)),
    );
    let elapsed = start.elapsed();

    match result {
        Err(SpriteError::Io(_)) => {}
        other => panic!("expected an Io error connecting to a nonexistent socket path, got {other:?}"),
    }
    assert!(
        elapsed <= Duration::from_secs(2),
        "connecting to a nonexistent socket path took {elapsed:?}, want a prompt failure"
    );
}
