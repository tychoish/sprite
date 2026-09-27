"""Connection-layer tests for eval_blocking, using a fake Unix-socket
server. These exercise conn.py directly, which the fixture-driven
protocol tests do not touch (they only cover the pure encode/decode/
sexp/reassembly functions).
"""

import socket
import tempfile
import threading
from pathlib import Path

import pytest

from sprite_direct.conn import SpriteConnectionError, eval_blocking
from sprite_direct.protocol import SpriteEvalError


def _serve_once(sock_path: str, response: bytes) -> threading.Thread:
    """Start a background thread that accepts one connection on
    SOCK_PATH, sends RESPONSE, then closes."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(1)

    def _run():
        conn, _ = server.accept()
        with conn:
            conn.recv(65536)
            conn.sendall(response)
        server.close()

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()
    return thread


def test_eval_blocking_over_unix_socket_no_key_required(tmp_path: Path):
    sock_path = str(tmp_path / "test.sock")
    thread = _serve_once(sock_path, b"-emacs-pid 123\n-print 42\n")
    try:
        result = eval_blocking(sock_path, 42, timeout=5)
    finally:
        thread.join(timeout=5)
    assert result == "42"


def test_eval_blocking_over_unix_socket_raises_on_error_response(tmp_path: Path):
    sock_path = str(tmp_path / "test.sock")
    thread = _serve_once(sock_path, b"-emacs-pid 123\n-error boom\n")
    try:
        with pytest.raises(SpriteEvalError):
            eval_blocking(sock_path, 42, timeout=5)
    finally:
        thread.join(timeout=5)


def test_tcp_target_with_no_key_errors_before_connecting():
    # No listener at all on this port -- if eval_blocking attempted to
    # connect before validating the key, this would raise a socket
    # connection error instead of SpriteConnectionError.
    with pytest.raises(SpriteConnectionError):
        eval_blocking("127.0.0.1:1", 42)
