"""Shared disposable-daemon helpers for tests that spawn their own
`emacs --fg-daemon` (rather than relying on SPRITE_TEST_SOCKET).

`--fg-daemon=NAME` (not `--daemon=NAME`) is required so the process
tracked here (proc.pid) is actually the daemon process: `--daemon`
double-forks and detaches, so the launched process exits almost
immediately once the real, detached daemon is up, leaving proc.kill()
killing nothing. Verified directly against a live daemon.

Disposable daemon/dir names are kept short and unique (short prefix +
pid + counter): AF_UNIX socket paths have a ~108-byte sun_path limit,
and a long tempdir path plus a long, timestamp-suffixed name can exceed
it, producing an opaque "Service name too long" failure from Emacs
rather than a clean test skip/fail.
"""

from __future__ import annotations

import contextlib
import itertools
import os
import shutil
import subprocess
import tempfile
import time

import pytest

EMACS_PATH = shutil.which("emacs")
_name_counter = itertools.count(1)


def emacs_available() -> bool:
    return EMACS_PATH is not None


def require_emacs():
    if not emacs_available():
        pytest.skip("emacs binary not found on PATH; skipping live-daemon test")


def unique_daemon_name(prefix: str = "spt") -> str:
    return f"{prefix}{os.getpid() % 100000}{next(_name_counter)}"


def wait_for_path(path: str, timeout: float = 20.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.1)
    return False


class DisposableDaemon:
    """A uniquely-named, disposable `emacs --fg-daemon`, in its own
    fresh XDG_RUNTIME_DIR, killed unconditionally on close()."""

    def __init__(self, name: str | None = None):
        require_emacs()
        self.xdg = tempfile.mkdtemp(prefix="x")
        os.chmod(self.xdg, 0o700)
        name = name or unique_daemon_name()
        env = dict(os.environ, XDG_RUNTIME_DIR=self.xdg)
        self.proc = subprocess.Popen(
            [EMACS_PATH, f"--fg-daemon={name}", "--no-init-file", "--no-site-file"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.sock = os.path.join(self.xdg, "emacs", name)
        if not wait_for_path(self.sock):
            out = ""
            if self.proc.poll() is not None:
                out = self.proc.stdout.read().decode("utf-8", "replace")
            self.close()
            raise RuntimeError(f"disposable daemon socket never appeared at {self.sock}: {out}")

    def close(self):
        # Unconditional, direct process kill: cleanup for a daemon that
        # may be wedged by a hung eval cannot go through emacsclient (or
        # any -eval RPC), since that RPC would itself queue behind the
        # hanging form.
        try:
            self.proc.kill()
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            pass
        shutil.rmtree(self.xdg, ignore_errors=True)


@contextlib.contextmanager
def disposable_unix_daemon(name: str | None = None):
    daemon = DisposableDaemon(name)
    try:
        yield daemon.sock, daemon.proc
    finally:
        daemon.close()


@contextlib.contextmanager
def disposable_tcp_daemon(name: str | None = None):
    require_emacs()
    name = name or unique_daemon_name()
    xdg = tempfile.mkdtemp(prefix="x")
    os.chmod(xdg, 0o700)
    authdir = tempfile.mkdtemp(prefix="a") + os.sep
    env = dict(os.environ, XDG_RUNTIME_DIR=xdg)
    eval_expr = f'(setq server-use-tcp t server-auth-dir "{authdir}")'
    proc = subprocess.Popen(
        [EMACS_PATH, f"--fg-daemon={name}", "--no-init-file", "--no-site-file", "--eval", eval_expr],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    auth_file = os.path.join(authdir, name)
    try:
        if not wait_for_path(auth_file):
            proc.kill()
            proc.wait(timeout=5)
            pytest.fail(f"disposable TCP daemon auth file {auth_file} never appeared")
        # server.el writes: line 1 "HOST:PORT PID", line 2 the raw auth
        # key (verified against a live server-use-tcp daemon).
        with open(auth_file) as f:
            lines = f.read().splitlines()
        host, port = lines[0].split()[0].rsplit(":", 1)
        key = lines[1]
        yield host, port, key
    finally:
        proc.kill()
        proc.wait(timeout=5)


@pytest.fixture
def disposable_daemon():
    """Yields a DisposableDaemon, skipping if `emacs` isn't on PATH."""
    require_emacs()
    daemon = DisposableDaemon()
    try:
        yield daemon
    finally:
        daemon.close()
