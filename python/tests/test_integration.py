"""Live-daemon integration test: exercises eval_blocking against a real
`emacs --daemon`, not a fake socket server. Gated on SPRITE_TEST_SOCKET
(the resolved Unix-socket path of an already-running daemon), so it is
skipped by default in any environment without one -- CI sets this env
var after spawning a dedicated test daemon; see
.github/workflows/test.yml.
"""

import os

import pytest

from sprite_direct.conn import eval_blocking
from sprite_direct.protocol import SpriteEvalError
from sprite_direct.sexp import sym

SOCKET = os.environ.get("SPRITE_TEST_SOCKET")

pytestmark = pytest.mark.skipif(
    not SOCKET, reason="SPRITE_TEST_SOCKET not set; skipping live-daemon integration test"
)


def test_arithmetic_eval_against_live_daemon():
    result = eval_blocking(SOCKET, [sym("+"), 1, 2], timeout=5)
    assert result == "3"


def test_string_eval_against_live_daemon():
    result = eval_blocking(SOCKET, [sym("concat"), "hello", " world"], timeout=5)
    assert result == '"hello world"'


def test_list_eval_against_live_daemon():
    result = eval_blocking(SOCKET, [sym("list"), 1, 2, 3], timeout=5)
    assert result == "(1 2 3)"


def test_unbound_variable_eval_raises_sprite_eval_error():
    """Real Emacs DOES send a genuine -error line for an ordinary eval
    error, but only if the client doesn't half-close its write side
    after sending (verified against a live daemon: half-closing races
    with the server flushing the reply and can silently drop it) --
    see conn.py's _read_response for why this must not simply wait
    for EOF either.
    """
    with pytest.raises(SpriteEvalError, match="this-variable-does-not-exist-anywhere"):
        eval_blocking(SOCKET, sym("this-variable-does-not-exist-anywhere"), timeout=10)
