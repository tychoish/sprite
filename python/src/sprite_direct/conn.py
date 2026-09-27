"""Blocking connect-send-receive-parse client for sprite-direct.

Connection targets
------------------

- Unix domain socket: pass the resolved socket path directly as
  ``target`` (a string not containing two ``:``-delimited numeric
  components — see below). No ``-auth`` key is required in the common
  case (Emacs 29+ authenticates via peer UID).
- TCP: pass ``target`` as ``"HOST:PORT:KEY"`` (host, numeric port, key,
  all colon-separated), or pass ``host:port`` separately via ``target``
  as ``"HOST:PORT"`` and supply ``key`` explicitly. A TCP target with
  no key is an error, raised *before* connecting. TCP is trusted-network
  -only: the key is sent in the clear in every request's ``-auth``
  segment, and there is no TLS layer, matching the Elisp
  implementation's own assumption.

Only one eval per connection: a fresh socket is opened for every call,
the request line is sent, the response is read to EOF, then the
socket is closed. Sockets are never pooled or reused.

The "open a socket" step is factored into :func:`_open_socket` as a
small seam so live-daemon integration tests (a follow-up; no Emacs
daemon is assumed available in this sandbox) can substitute a fake or
a real connection later without touching the request/response logic.
"""

from __future__ import annotations

import socket
from typing import Optional

from .protocol import SpriteEvalError, encode, parse_response
from .sexp import Form, print_sexp

__all__ = ["SpriteEvalError", "SpriteConnectionError", "eval_blocking"]


class SpriteConnectionError(ValueError):
    """Raised for connection-target errors detected before connecting."""


def _is_tcp_target(target: str) -> bool:
    """A TCP target looks like HOST:PORT or HOST:PORT:KEY."""
    parts = target.split(":")
    if len(parts) < 2:
        return False
    # Second component must look like a port number.
    return parts[1].isdigit()


def _parse_target(target: str, key: Optional[str]):
    """Return (kind, connect_info, auth_key) for TARGET.

    kind is "unix" or "tcp". connect_info is the socket path for unix,
    or (host, port) for tcp.
    """
    if _is_tcp_target(target):
        parts = target.split(":", 2)
        host = parts[0]
        port = int(parts[1])
        auth_key = parts[2] if len(parts) == 3 and parts[2] else key
        if not auth_key:
            raise SpriteConnectionError(
                "TCP target requires a key: pass 'HOST:PORT:KEY' or "
                "supply key= explicitly"
            )
        return "tcp", (host, port), auth_key

    return "unix", target, None


def _open_socket(kind: str, connect_info, timeout: Optional[float]) -> socket.socket:
    """Open a fresh socket for one request/response cycle.

    Kept as a small seam so future live-daemon integration tests can
    substitute a different connection strategy.
    """
    if kind == "unix":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    else:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if timeout is not None:
        sock.settimeout(timeout)
    sock.connect(connect_info)
    return sock


def _has_complete_error_line(buf: bytes) -> bool:
    """Return True when BUF contains a full, newline-terminated
    "-error ..." line. Only bytes up to the last b'\\n' are
    considered "complete" -- a trailing, not-yet-terminated fragment
    is still in flight."""
    last = buf.rfind(b"\n")
    if last < 0:
        return False
    return any(line.startswith(b"-error ") for line in buf[:last].split(b"\n"))


def _read_response(sock: socket.socket) -> bytes:
    """Read the response, stopping at EOF (the success-reply case:
    the server closes the connection once a -print/-print-nonl reply
    is fully sent) or as soon as a complete "-error PAYLOAD" line has
    been seen.

    The latter is not an optimization, it is a correctness
    requirement: verified against a live emacs --daemon that after
    sending an -error reply, the server does NOT promptly close the
    connection the way it does after a successful reply -- an
    internal cleanup eventually closes it, but only after a
    multi-second, unspecified delay (on top of Emacs's own ~1-2s
    delay in generating the error reply in the first place, which is
    inherent server-side latency, not a client bug). Waiting
    unconditionally for EOF would add that delay to every real eval
    error. -print/-print-nonl still requires waiting for EOF, since a
    large value's continuation lines carry no marker for which one is
    last (see CONTRACT.md).
    """
    chunks = []
    buf = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
        buf += chunk
        if _has_complete_error_line(buf):
            break
    return b"".join(chunks)


def eval_blocking(
    target: str,
    form: Form,
    *,
    key: Optional[str] = None,
    timeout: Optional[float] = None,
) -> Optional[str]:
    """Evaluate FORM in a running Emacs daemon and return the raw result.

    TARGET is either a Unix-domain socket path, or a TCP target string
    ``"HOST:PORT"`` / ``"HOST:PORT:KEY"``. FORM is a tagged sexp form
    from :mod:`sprite_direct.sexp` (or a bare Python value accepted by
    :func:`sprite_direct.sexp.print_sexp`).

    Returns the concatenated decoded result string, or None if the
    server produced no -print/-print-nonl/-error line at all (only the
    -emacs-pid preamble). Raises :class:`SpriteEvalError` for an
    -error response, and :class:`SpriteConnectionError` before
    connecting if a TCP target has no key.
    """
    kind, connect_info, auth_key = _parse_target(target, key)

    printed = print_sexp(form)
    encoded_form = encode(printed)

    if kind == "tcp":
        request_line = f"-auth {auth_key} -eval {encoded_form} \n"
    else:
        request_line = f"-eval {encoded_form} \n"

    sock = _open_socket(kind, connect_info, timeout)
    try:
        sock.sendall(request_line.encode("utf-8"))
        # Deliberately do NOT half-close the write side here (no
        # shutdown(SHUT_WR)): verified against a live emacs --daemon
        # that doing so races with the server sending a genuine
        # -error reply for an evaluation error (as opposed to a
        # successful result) -- Emacs's connection teardown on
        # observing the client's EOF can beat the -error line being
        # flushed, silently turning a real error into an empty
        # result. Simply write and then read to EOF; the server
        # closes the connection on its own once its reply is fully
        # sent, for both success and error replies.
        raw = _read_response(sock)
    finally:
        sock.close()

    return parse_response(raw)
