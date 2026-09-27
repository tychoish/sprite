"""Live-daemon integration tests for eval_non_blocking / resume_future:
exercises async_.py against a real `emacs --daemon` running
sprite-async.el, not a fake socket server. Gated on SPRITE_TEST_SOCKET
exactly like test_integration.py -- skipped by default in any
environment without an already-running, resolved-socket-path test
daemon; see .github/workflows/test.yml, which loads sprite-async.el
into the daemon before running this file.
"""

import os
import time

import pytest

from sprite_direct.async_ import SpriteAsyncError, eval_non_blocking, resume_future
from sprite_direct.sexp import sym

SOCKET = os.environ.get("SPRITE_TEST_SOCKET")

pytestmark = pytest.mark.skipif(
    not SOCKET, reason="SPRITE_TEST_SOCKET not set; skipping live-daemon integration test"
)


def test_eval_non_blocking_arithmetic_against_live_daemon():
    future = eval_non_blocking(SOCKET, [sym("+"), 1, 2])
    assert future.result(timeout=5) == "3"


def test_eval_non_blocking_error_form_raises_sprite_async_error():
    future = eval_non_blocking(SOCKET, sym("this-variable-does-not-exist-anywhere"))
    with pytest.raises(SpriteAsyncError):
        future.result(timeout=5)


def test_eval_non_blocking_concurrent_forms_against_live_daemon():
    n = 10
    futures = [eval_non_blocking(SOCKET, [sym("+"), i, i]) for i in range(n)]
    for i, future in enumerate(futures):
        assert future.result(timeout=5) == str(i + i)


def test_resume_future_recovers_after_disconnect_against_live_daemon():
    future = eval_non_blocking(
        SOCKET, [sym("progn"), [sym("sleep-for"), 1], 99]
    )

    token = None
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        token = future.token
        if token is not None:
            break
        time.sleep(0.01)
    assert token, "future.token was never populated"

    # Deliberately do not wait on `future` here -- simulate a client
    # that started an eval, learned the token, then disconnected
    # (dropped its original future) before the result was ready.
    resumed = resume_future(SOCKET, token)
    assert resumed.result(timeout=5) == "99"
