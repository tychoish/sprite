//! Async (tokio-backed) non-blocking eval, layered on top of the
//! existing sync [`crate::eval_blocking`] via
//! `tokio::task::spawn_blocking`. Gated behind the `async` Cargo
//! feature; the sync API is unaffected either way.
//!
//! This talks to the daemon-side `sprite-async-start`/`sprite-async-poll`
//! registry (see `sprite-async.el`) over the *existing* `-eval` wire
//! command -- there is no new wire-protocol message type. Wire-level
//! reply text for those two calls is hand-parsed in [`crate::async_wire`],
//! matching this crate's no-Lisp-reader MVP scope.

use std::time::Duration;

use tokio::task::JoinHandle;

use crate::async_wire::{self, PollReply};
use crate::sexp::{self, Sexp};
use crate::SpriteError;

/// How long to wait between successive polls of a pending async token.
pub enum PollInterval {
    /// Sleep exactly this duration between polls.
    Fixed(Duration),
    /// Called with the elapsed time since the polling loop started
    /// (before each poll after the first); its return value is the
    /// sleep duration before that next poll.
    Backoff(Box<dyn Fn(Duration) -> Duration + Send + Sync>),
}

/// A handle to a form evaluating in the background on the daemon side.
///
/// Unlike [`eval_non_blocking`], this exposes the daemon-assigned token
/// (via [`AsyncHandle::token`]) before the form has settled, for parity
/// with the other clients' start/poll/token/wait APIs.
pub struct AsyncHandle {
    token: String,
    join: JoinHandle<Result<String, SpriteError>>,
}

impl AsyncHandle {
    /// The daemon-assigned token for this background evaluation.
    pub fn token(&self) -> &str {
        &self.token
    }

    /// Wait for the background evaluation to settle, returning its
    /// resolved value or the mapped rejection/unknown-token error.
    ///
    /// A panic inside the background polling task is converted to
    /// [`SpriteError::TaskPanicked`] rather than left as an unwrapped
    /// `JoinError`.
    pub async fn wait(self) -> Result<String, SpriteError> {
        flatten_join(self.join.await)
    }
}

/// Evaluate `form` in the background at `target` and await its result.
///
/// Convenience wrapper around [`start_async`] for a caller who does not
/// need the token before the result is available; equivalent to
/// `start_async(...).await?.wait().await`.
pub async fn eval_non_blocking(
    target: &str,
    form: &Sexp,
    key: Option<&str>,
    timeout: Option<Duration>,
    ttl_seconds: Option<u64>,
    poll_interval: Option<PollInterval>,
) -> Result<String, SpriteError> {
    start_async(target, form, key, timeout, ttl_seconds, poll_interval)
        .await?
        .wait()
        .await
}

/// Wait for a previously-started async token to settle.
///
/// Convenience wrapper around [`resume_async`]; equivalent to
/// `resume_async(...).await.wait().await`.
pub async fn resume_future(
    target: &str,
    token: &str,
    key: Option<&str>,
    timeout: Option<Duration>,
    poll_interval: Option<PollInterval>,
) -> Result<String, SpriteError> {
    resume_async(target, token, key, timeout, poll_interval)
        .await
        .wait()
        .await
}

/// Register `form` for background evaluation at `target` and return a
/// handle whose token is available immediately.
///
/// This first calls the existing sync [`crate::eval_blocking`] (via
/// `spawn_blocking`, since it performs blocking socket I/O) with
/// `(sprite-async-start (quote FORM) [TTL-SECONDS])` to obtain the
/// token synchronously, then spawns a background task that polls
/// `(sprite-async-poll TOKEN)` until the form settles.
pub async fn start_async(
    target: &str,
    form: &Sexp,
    key: Option<&str>,
    timeout: Option<Duration>,
    ttl_seconds: Option<u64>,
    poll_interval: Option<PollInterval>,
) -> Result<AsyncHandle, SpriteError> {
    let mut start_args = vec![
        Sexp::Sym("sprite-async-start".to_string()),
        sexp::quote(form.clone()),
    ];
    if let Some(ttl) = ttl_seconds {
        start_args.push(Sexp::Int(
            i64::try_from(ttl).unwrap_or(i64::MAX),
        ));
    }
    let start_form = Sexp::List(start_args);

    let raw = eval_blocking_async(
        target.to_string(),
        start_form,
        key.map(str::to_string),
        timeout,
    )
    .await?;
    let token = async_wire::parse_start_reply(&raw);

    Ok(spawn_polling_handle(
        target.to_string(),
        token,
        key.map(str::to_string),
        timeout,
        poll_interval,
    ))
}

/// Resume observing a token obtained from a previous [`start_async`]
/// call (e.g. from another process, or a token persisted across a
/// restart), skipping the initial `sprite-async-start` call.
pub async fn resume_async(
    target: &str,
    token: &str,
    key: Option<&str>,
    timeout: Option<Duration>,
    poll_interval: Option<PollInterval>,
) -> AsyncHandle {
    spawn_polling_handle(
        target.to_string(),
        token.to_string(),
        key.map(str::to_string),
        timeout,
        poll_interval,
    )
}

/// Spawn the background polling task and wrap it (plus the already-known
/// token) in an [`AsyncHandle`].
fn spawn_polling_handle(
    target: String,
    token: String,
    key: Option<String>,
    timeout: Option<Duration>,
    poll_interval: Option<PollInterval>,
) -> AsyncHandle {
    let token_for_handle = token.clone();
    let join = tokio::task::spawn(async move {
        poll_loop(target, token, key, timeout, poll_interval).await
    });
    AsyncHandle {
        token: token_for_handle,
        join,
    }
}

/// Poll `(sprite-async-poll TOKEN)` in a loop until the form settles.
///
/// `:pending` sleeps per `poll_interval` (or the default backoff -- 50ms
/// doubling, capped at 2s -- when `None`) and loops; `:resolved` returns
/// the value verbatim; `:rejected`/`:unknown` return the corresponding
/// mapped [`SpriteError`].
async fn poll_loop(
    target: String,
    token: String,
    key: Option<String>,
    timeout: Option<Duration>,
    poll_interval: Option<PollInterval>,
) -> Result<String, SpriteError> {
    let start = tokio::time::Instant::now();
    let mut default_next = Duration::from_millis(50);

    loop {
        let poll_form = Sexp::List(vec![
            Sexp::Sym("sprite-async-poll".to_string()),
            Sexp::Str(token.clone()),
        ]);

        let raw =
            eval_blocking_async(target.clone(), poll_form, key.clone(), timeout).await?;

        match async_wire::parse_poll_reply(&raw) {
            PollReply::Pending => {
                let sleep_for = match &poll_interval {
                    Some(PollInterval::Fixed(d)) => *d,
                    Some(PollInterval::Backoff(f)) => f(start.elapsed()),
                    None => {
                        let d = default_next;
                        default_next = (default_next * 2).min(Duration::from_secs(2));
                        d
                    }
                };
                tokio::time::sleep(sleep_for).await;
            }
            PollReply::Resolved(value) => return Ok(value),
            PollReply::Rejected(msg) => return Err(SpriteError::AsyncRejected(msg)),
            PollReply::Unknown => return Err(SpriteError::AsyncUnknownToken(token)),
        }
    }
}

/// Run [`crate::eval_blocking`] on a blocking thread via
/// `tokio::task::spawn_blocking`, converting a panic inside that thread
/// (a `JoinError`) into [`SpriteError::TaskPanicked`] rather than
/// leaving it unwrapped.
async fn eval_blocking_async(
    target: String,
    form: Sexp,
    key: Option<String>,
    timeout: Option<Duration>,
) -> Result<String, SpriteError> {
    spawn_blocking_result(move || crate::eval_blocking(&target, &form, key.as_deref(), timeout))
        .await
}

/// Run `f` on a blocking thread via `tokio::task::spawn_blocking`,
/// flattening the resulting `Result<Result<String, SpriteError>,
/// JoinError>` via [`flatten_join`]. Split out from
/// [`eval_blocking_async`] so the panic-to-[`SpriteError::TaskPanicked`]
/// conversion can be exercised directly with an arbitrary (e.g.
/// panicking) closure in tests, without going through
/// `crate::eval_blocking`.
async fn spawn_blocking_result<F>(f: F) -> Result<String, SpriteError>
where
    F: FnOnce() -> Result<String, SpriteError> + Send + 'static,
{
    flatten_join(tokio::task::spawn_blocking(f).await)
}

/// Shared conversion from a task's `Result<Result<String, SpriteError>,
/// JoinError>` (as produced by awaiting either `tokio::task::spawn` or
/// `tokio::task::spawn_blocking`) into the flat `Result<String,
/// SpriteError>` the rest of this module works with: an unwrapped
/// `JoinError` (a panic, or -- for `AsyncHandle::wait` -- also a
/// cancellation) becomes [`SpriteError::TaskPanicked`].
fn flatten_join(
    result: Result<Result<String, SpriteError>, tokio::task::JoinError>,
) -> Result<String, SpriteError> {
    match result {
        Ok(inner) => inner,
        Err(e) => Err(SpriteError::TaskPanicked(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Exercises the real panic-to-[`SpriteError::TaskPanicked`]
    /// conversion path ([`flatten_join`], via [`spawn_blocking_result`])
    /// with a closure that actually panics inside the blocking thread,
    /// rather than the black-box abort-based analog in
    /// `tests/async_unit.rs` (which can only reach a *cancelled* task,
    /// not a genuinely panicked one, since neither `AsyncHandle` nor
    /// this module's private helpers are reachable from outside the
    /// crate).
    #[tokio::test]
    async fn spawn_blocking_result_panic_becomes_task_panicked() {
        let result: Result<String, SpriteError> =
            spawn_blocking_result(move || -> Result<String, SpriteError> {
                panic!("boom");
            })
            .await;

        match result {
            Err(SpriteError::TaskPanicked(msg)) => {
                assert!(
                    msg.to_lowercase().contains("panic") || msg.contains("boom"),
                    "unexpected TaskPanicked message: {msg}"
                );
            }
            other => panic!("expected Err(SpriteError::TaskPanicked(_)), got {other:?}"),
        }
    }

    // `AsyncHandle::wait`'s `JoinError` mapping is the exact same
    // `flatten_join` call used by `spawn_blocking_result` (and thus by
    // `eval_blocking_async`) above, so the test above already covers
    // this shared conversion; no separate near-duplicate test is added
    // for the `tokio::task::spawn`-based polling task.
}
