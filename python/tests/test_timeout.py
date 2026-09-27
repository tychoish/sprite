"""Timeout / hung-daemon test suite: exercises eval_blocking's
``timeout=`` argument against daemons that either never reply (a
genuine infinite Elisp loop) or never accept a connection at all, plus
a fast daemon with no timeout configured at all.

IMPORTANT finding, recorded here because it shapes every sub-case
below: a single hung eval (a genuine ``(while t ...)`` busy loop) DOES
block every other connection to the same daemon, not just the
connection that issued it. Emacs's Lisp evaluator is single threaded;
server.el's accept loop cannot service (or even accept()) any other
connection while one Lisp form is running forever -- verified directly
against a live ``emacs --daemon`` before writing this suite. So the
hung-eval daemon in ``test_hung_eval_timeout_fires`` is spawned fresh,
used for nothing else, and killed immediately after; it is never
reused for the "fast daemon, no timeout" case (that case uses
SPRITE_TEST_SOCKET's shared daemon, gated the same way
test_integration.py gates on it, or is skipped).

A second finding: cleanup for a daemon wedged by a hung eval cannot go
through emacsclient (or any -eval RPC) -- that RPC would itself queue
behind the very form that's hanging, hanging the test's own teardown.
Cleanup here always kills the daemon's OS process directly (SIGKILL),
which is why the shared `disposable_daemon` fixture (see conftest.py
for the --fg-daemon/socket-path-length mechanics) does this
unconditionally.
"""

from __future__ import annotations

import os
import time

import pytest

from sprite_direct.conn import eval_blocking
from sprite_direct.sexp import sym

SOCKET = os.environ.get("SPRITE_TEST_SOCKET")

# The `disposable_daemon` fixture used below (a uniquely-named, disposable
# `emacs --fg-daemon`, killed unconditionally on teardown) is defined in
# conftest.py and shared with test_integration.py's TCP/destructive cases.


def _open_fd_count() -> int:
    """Number of open file descriptors for this process, used as a
    simple proxy for "no leaked socket/connection" (case 4)."""
    return len(os.listdir("/proc/self/fd"))


def test_hung_eval_timeout_fires(disposable_daemon):
    """Case 1 + case 4: a genuinely hung eval (an infinite Elisp loop)
    against a configured timeout must raise within a generous (~2x)
    tolerance of the configured duration, must not return a success
    value, and must not leave a lingering open file descriptor for the
    abandoned socket."""
    before_fds = _open_fd_count()

    form = [sym("while"), sym("t"), [sym("sleep-for"), 1]]

    configured = 2.0
    start = time.monotonic()
    with pytest.raises(OSError):
        eval_blocking(disposable_daemon.sock, form, timeout=configured)
    elapsed = time.monotonic() - start

    assert elapsed <= 2 * configured, (
        f"timeout took {elapsed}s, want at most ~2x the configured {configured}s"
    )

    # eval_blocking's `finally: sock.close()` should mean no fd is
    # left open for the abandoned connection once the call has
    # returned/raised. Allow a small amount of slack for unrelated fds
    # (e.g. pytest's own bookkeeping) rather than requiring an exact
    # match.
    after_fds = _open_fd_count()
    assert after_fds <= before_fds + 1, (
        f"open fd count grew from {before_fds} to {after_fds} after a "
        "timed-out eval against a hung daemon; possible socket leak"
    )


@pytest.mark.skipif(
    not SOCKET, reason="SPRITE_TEST_SOCKET not set; skipping live-daemon integration test"
)
def test_no_timeout_configured_fast_daemon_unaffected():
    """Case 2: with no timeout= argument at all, a normal fast-replying
    daemon must still succeed promptly -- omitting timeout must not
    impose some implicit ceiling of its own."""
    start = time.monotonic()
    result = eval_blocking(SOCKET, [sym("+"), 1, 2])
    elapsed = time.monotonic() - start
    assert result == "3"
    assert elapsed <= 2.0, f"expected a prompt reply with no timeout configured, took {elapsed}s"


def test_connect_to_nonexistent_socket_fails_promptly():
    """Case 3 fallback: Python's eval_blocking has no dial-injection
    seam (unlike Go's protocol.WithDialer), and a genuinely slow *dial*
    is hard to construct without external-network tricks (a
    backlog-exhaustion experiment against a real Unix socket returned
    an immediate EAGAIN rather than blocking, confirmed directly while
    writing this suite -- Linux's AF_UNIX listen backlog does not make
    connect() itself hang). So this test falls back to the documented
    substitute: a connection attempt to a socket path that simply
    doesn't exist must fail promptly, not hang, even with a timeout
    configured that's much longer than the failure should take."""
    start = time.monotonic()
    with pytest.raises(OSError):
        eval_blocking(
            "/tmp/sprite-timeout-test-nonexistent-socket-path.sock",
            sym("t"),
            timeout=2.0,
        )
    elapsed = time.monotonic() - start
    assert elapsed <= 2.0, (
        f"connecting to a nonexistent socket path took {elapsed}s, want a prompt failure"
    )
