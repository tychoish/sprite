"""Unit tests for eval_non_blocking / resume_future (async_.py), using a
fake Unix-socket server. Mirrors the style of test_conn.py, but the
fake server here must accept() in a loop and serve *multiple*
sequential replies over separate connections, since eval_non_blocking
makes one `sprite-async-start` call followed by repeated
`sprite-async-poll` calls -- each of which is its own transient
connection per this library's one-connection-per-eval design (see
conn.py).

The fake server distinguishes a `sprite-async-start` request from a
`sprite-async-poll` request by looking for the substring "start" or
"poll" in the raw request bytes: the wire-protocol encoding (see
protocol.py) only rewrites `&`, `-`, space, and newline, so plain
letters -- including the "start"/"poll" substrings themselves -- are
never touched by encoding and remain searchable verbatim.
"""

from __future__ import annotations

import socket
import threading
import time
from pathlib import Path
from typing import Callable, List, Optional

import pytest

from sprite_direct.async_ import SpriteAsyncError, eval_non_blocking, resume_future
from sprite_direct.conn import SpriteConnectionError
from sprite_direct.protocol import encode


def _reply_line(tag_text: str) -> bytes:
    return f"-print {encode(tag_text)}\n".encode("utf-8")


def _start_reply(token: str) -> bytes:
    return _reply_line(f'"{token}"')


def _poll_reply_pending() -> bytes:
    return _reply_line("(:pending)")


def _poll_reply_resolved(value_text: str) -> bytes:
    return _reply_line(f"(:resolved {value_text})")


def _poll_reply_rejected(msg: str) -> bytes:
    return _reply_line(f'(:rejected "{msg}")')


def _poll_reply_unknown() -> bytes:
    return _reply_line("(:unknown)")


class FakeAsyncServer:
    """Accepts connections in a loop on SOCK_PATH, handling each in its
    own thread so concurrent clients (or a single client's sequential
    start-then-poll-then-poll... connections) are all served. DISPATCH
    is called with the raw request bytes for each connection and must
    return the raw reply bytes to send back (or None to send nothing).

    Every request's raw bytes are appended to `.captured`, so tests can
    assert on what was (or wasn't) sent, e.g. that no
    `sprite-async-start` request ever reached a given fake server.
    """

    def __init__(self, sock_path: str, dispatch: Callable[[bytes], Optional[bytes]]):
        self.dispatch = dispatch
        self.captured: List[bytes] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(sock_path)
        self._server.listen(64)
        self._server.settimeout(0.1)
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)

    def start(self) -> "FakeAsyncServer":
        self._thread.start()
        return self

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            data = conn.recv(65536)
            with self._lock:
                self.captured.append(data)
            reply = self.dispatch(data)
            if reply is not None:
                conn.sendall(reply)

    def stop(self) -> None:
        self._stop.set()
        try:
            self._server.close()
        except OSError:
            pass
        self._thread.join(timeout=5)


def _make_dispatch(
    token: str, poll_sequence: List[bytes]
) -> Callable[[bytes], bytes]:
    """A dispatch function that replies with `_start_reply(token)` to
    any request whose bytes contain "start", and otherwise walks
    through POLL_SEQUENCE in order (repeating the last entry if there
    are more poll calls than entries) for anything containing "poll".
    """
    state = {"idx": 0}
    lock = threading.Lock()

    def dispatch(request: bytes) -> bytes:
        text = request.decode("utf-8", errors="replace")
        if "poll" in text:
            with lock:
                idx = min(state["idx"], len(poll_sequence) - 1)
                state["idx"] += 1
            return poll_sequence[idx]
        if "start" in text:
            return _start_reply(token)
        raise AssertionError(f"unrecognized fake-server request: {text!r}")

    return dispatch


def test_eval_non_blocking_happy_path(tmp_path: Path):
    sock_path = str(tmp_path / "happy.sock")
    poll_sequence = [
        _poll_reply_pending(),
        _poll_reply_pending(),
        _poll_reply_resolved("42"),
    ]
    server = FakeAsyncServer(sock_path, _make_dispatch("tok-happy", poll_sequence)).start()
    try:
        future = eval_non_blocking(sock_path, 42, poll_interval=0.01)
        result = future.result(timeout=5)
        assert result == "42"
        assert isinstance(future.token, str)
        assert future.token
    finally:
        server.stop()


def test_eval_non_blocking_rejected_raises_sprite_async_error(tmp_path: Path):
    sock_path = str(tmp_path / "rejected.sock")
    poll_sequence = [_poll_reply_pending(), _poll_reply_rejected("boom")]
    server = FakeAsyncServer(sock_path, _make_dispatch("tok-rejected", poll_sequence)).start()
    try:
        future = eval_non_blocking(sock_path, 42, poll_interval=0.01)
        with pytest.raises(SpriteAsyncError, match="boom"):
            future.result(timeout=5)
    finally:
        server.stop()


def test_eval_non_blocking_unknown_raises_sprite_async_error(tmp_path: Path):
    sock_path = str(tmp_path / "unknown.sock")
    poll_sequence = [_poll_reply_pending(), _poll_reply_unknown()]
    server = FakeAsyncServer(sock_path, _make_dispatch("tok-unknown", poll_sequence)).start()
    try:
        future = eval_non_blocking(sock_path, 42, poll_interval=0.01)
        with pytest.raises(SpriteAsyncError):
            future.result(timeout=5)
    finally:
        server.stop()


def test_eval_non_blocking_predial_error_surfaces_via_future_not_synchronously():
    # No listener at all, and a TCP target with no key -- eval_blocking
    # raises SpriteConnectionError before connecting (see
    # test_conn.py's equivalent sync case). eval_non_blocking must
    # NOT raise this synchronously out of the call itself; it must
    # surface only via the returned future.
    future = eval_non_blocking("127.0.0.1:1", 42)
    exc = future.exception(timeout=5)
    assert isinstance(exc, SpriteConnectionError)
    with pytest.raises(SpriteConnectionError):
        future.result(timeout=5)


def test_eval_non_blocking_concurrent_many_tokens(tmp_path: Path):
    n = 20
    servers: List[FakeAsyncServer] = []
    futures = []
    try:
        for i in range(n):
            sock_path = str(tmp_path / f"conc-{i}.sock")
            poll_sequence = [_poll_reply_pending(), _poll_reply_resolved(str(i))]
            server = FakeAsyncServer(
                sock_path, _make_dispatch(f"tok-{i}", poll_sequence)
            ).start()
            servers.append(server)
            futures.append(eval_non_blocking(sock_path, i, poll_interval=0.01))

        for i, future in enumerate(futures):
            assert future.result(timeout=5) == str(i)
    finally:
        for server in servers:
            server.stop()


def test_resume_future_reuses_token_without_restart(tmp_path: Path):
    orig_sock = str(tmp_path / "orig.sock")
    resume_sock = str(tmp_path / "resume.sock")

    orig_server = FakeAsyncServer(
        orig_sock,
        _make_dispatch(
            "shared-token",
            [_poll_reply_pending(), _poll_reply_resolved("111")],
        ),
    ).start()
    resume_server = FakeAsyncServer(
        resume_sock,
        _make_dispatch(
            "shared-token",
            [_poll_reply_pending(), _poll_reply_resolved("222")],
        ),
    ).start()

    try:
        future = eval_non_blocking(orig_sock, 1, poll_interval=0.01)

        token = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            token = future.token
            if token is not None:
                break
            time.sleep(0.01)
        assert token, "future.token was never populated"

        resumed = resume_future(resume_sock, token, poll_interval=0.01)
        assert resumed.result(timeout=5) == "222"

        # The resume flow must never issue a fresh sprite-async-start
        # call against the resume server.
        assert not any(b"start" in req for req in resume_server.captured)

        # Let the original flow finish too, so no worker thread is left
        # dangling in the shared thread-pool executor after this test.
        assert future.result(timeout=5) == "111"
    finally:
        orig_server.stop()
        resume_server.stop()
