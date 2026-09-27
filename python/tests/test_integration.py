"""Live-daemon integration test: exercises eval_blocking against a real
`emacs --daemon`, not a fake socket server. Gated on SPRITE_TEST_SOCKET
(the resolved Unix-socket path of an already-running daemon), so it is
skipped by default in any environment without one -- CI sets this env
var after spawning a dedicated test daemon; see
.github/workflows/test.yml.
"""

import os
import signal
import socket as socket_module
from unittest import mock

import pytest

from sprite_direct.conn import SpriteConnectionError, eval_blocking
from sprite_direct.protocol import SpriteEvalError
from sprite_direct.sexp import sym

from conftest import disposable_tcp_daemon, disposable_unix_daemon, unique_daemon_name

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


def test_wrong_type_argument_eval_raises_sprite_eval_error():
    """(+ 1 "a") is a genuine wrong-type-argument error, distinct in
    message shape from the unbound-variable case above -- confirms the
    error path decodes whatever message Emacs actually sends, rather
    than being hardcoded to one string."""
    with pytest.raises(SpriteEvalError) as excinfo:
        eval_blocking(SOCKET, [sym("+"), 1, "a"], timeout=10)
    assert str(excinfo.value)


def test_user_error_eval_raises_sprite_eval_error():
    """A genuine (user-error "boom") must surface via the same
    -error/SpriteEvalError path as any other eval error, not be
    silently swallowed or routed differently."""
    with pytest.raises(SpriteEvalError, match="boom"):
        eval_blocking(SOCKET, [sym("user-error"), "boom"], timeout=10)


def test_large_value_eval_spans_print_nonl_continuation_lines():
    """A 5000-byte string is well beyond Emacs's server-msg-size
    (1024), forcing the server to split the -print-nonl reply across
    multiple continuation lines. 120 is the char code for ?x. The
    result is pp/prin1-quoted, so assert on length/content rather than
    exact equality."""
    result = eval_blocking(SOCKET, [sym("make-string"), 5000, 120], timeout=10)
    assert result.count("x") == 5000
    assert result.startswith('"x')
    assert result.endswith('x"')


# --- Disposable-daemon cases for TCP and destructive scenarios ---
#
# These spawn their own emacs daemons (via conftest.py's shared
# disposable-daemon helpers) rather than relying on SPRITE_TEST_SOCKET,
# so they're gated independently on the `emacs` binary being on PATH.

def test_tcp_target_no_key_rejected_before_dialing():
    with disposable_tcp_daemon(unique_daemon_name("pn")) as (host, port, _key):
        # Deliberately omit the key: a TCP target the daemon requires a
        # real auth key for must be rejected client-side before any
        # connection is attempted, confirmed here against a live,
        # key-configured TCP daemon rather than only a fake dialer/mock.
        with pytest.raises(SpriteConnectionError, match="key"):
            eval_blocking(f"{host}:{port}", sym("t"), timeout=5)


def test_tcp_target_with_key_round_trips():
    with disposable_tcp_daemon(unique_daemon_name("pk")) as (host, port, key):
        result = eval_blocking(f"{host}:{port}", [sym("+"), 1, 2], key=key, timeout=5)
        assert result == "3"


def test_daemon_killed_mid_response_raises_clean_error():
    """SIGSTOP the daemon process right before the request line is
    handed to the kernel socket buffer (patching socket.sendall), then
    SIGKILL it right after the write returns, and confirm
    eval_blocking raises a clean connection error rather than hanging
    or crashing uncontrolled.

    SIGSTOP-ing first, rather than just killing immediately after the
    write, removes what would otherwise be a timing race: a plain kill
    immediately after sendall returns can still lose (verified
    empirically in an earlier version of this test) if Emacs's event
    loop happens to get scheduled first and read the bytes before the
    kill syscall runs, in which case the kernel sees an empty receive
    buffer at process-death time and delivers a plain EOF --
    indistinguishable from a successful-but-empty response (no error
    at all). A SIGSTOPed process cannot read no matter how much
    wall-clock time elapses, so the request bytes are guaranteed to
    still be sitting unread in the kernel's receive buffer once
    SIGKILL is delivered -- and an unread receive buffer at close time
    is what causes the kernel to send a reset (visible here as
    ConnectionResetError, an OSError subclass) instead of a plain
    close. SIGKILL still terminates a stopped process immediately.
    """
    with disposable_unix_daemon(unique_daemon_name("pd")) as (sock_path, proc):
        real_sendall = socket_module.socket.sendall

        def sendall_then_kill(self, *args, **kwargs):
            proc.send_signal(signal.SIGSTOP)
            result = real_sendall(self, *args, **kwargs)
            proc.kill()
            return result

        form = [sym("progn"), [sym("sleep-for"), 2], 1]
        with mock.patch.object(socket_module.socket, "sendall", sendall_then_kill):
            with pytest.raises(OSError):
                eval_blocking(sock_path, form, timeout=10)
