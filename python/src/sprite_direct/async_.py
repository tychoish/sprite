"""Thread-pool-backed non-blocking evaluation on top of the blocking
:func:`sprite_direct.conn.eval_blocking`, using the daemon-side
``sprite-async-start``/``sprite-async-poll`` registry (see
``sprite-async.el``).

Named ``async_`` (not ``async``, a Python reserved word). Public
re-export name is ``eval_non_blocking`` (see
:mod:`sprite_direct.__init__`).
"""

from __future__ import annotations

import concurrent.futures
import os
import threading
import time
from typing import Callable, List, Optional, Union

from ._async_wire import parse_poll_reply, parse_start_reply
from .conn import eval_blocking
from .protocol import SpriteEvalError
from .sexp import Form, Sym, quote

__all__ = ["SpriteAsyncError", "eval_non_blocking", "resume_future"]


class SpriteAsyncError(SpriteEvalError):
    """Raised when a background evaluation rejects, or its token
    becomes unknown (not found or idle-timed-out) on the daemon side.
    """


_executor_lock = threading.Lock()
_executor: Optional[concurrent.futures.ThreadPoolExecutor] = None


def _get_executor() -> concurrent.futures.ThreadPoolExecutor:
    global _executor
    if _executor is None:
        with _executor_lock:
            if _executor is None:
                _executor = concurrent.futures.ThreadPoolExecutor(
                    max_workers=os.cpu_count() or 4,
                    thread_name_prefix="sprite-direct-async",
                )
    return _executor


def _default_poll_interval() -> Callable[[float], float]:
    """Exponential backoff: 0.05s, doubling, capped at 2.0s."""
    state = {"interval": 0.05}

    def _next(_elapsed: float) -> float:
        current = state["interval"]
        state["interval"] = min(current * 2, 2.0)
        return current

    return _next


def _resolve_poll_sleep(
    poll_interval: Optional[Union[float, Callable[[float], float]]],
) -> Callable[[float], float]:
    if poll_interval is None:
        return _default_poll_interval()
    if callable(poll_interval):
        return poll_interval
    fixed = float(poll_interval)
    return lambda _elapsed: fixed


def _relay_onto(
    target: concurrent.futures.Future, source: concurrent.futures.Future
) -> None:
    """Settle TARGET with SOURCE's outcome (exception or result), once
    SOURCE (an executor-submitted task's own Future) is done. Used as
    an ``add_done_callback`` on the internal worker Future so its
    outcome reaches the public, pre-built Future returned to callers.
    """
    exc = source.exception()
    if exc is not None:
        target.set_exception(exc)
    else:
        target.set_result(source.result())


def _spawn(future: concurrent.futures.Future, work: Callable[[], str]) -> None:
    """Run WORK on the shared executor and relay its outcome onto FUTURE.

    FUTURE must already exist (and have its ``.token`` set, if known)
    before calling this -- WORK's own closure is typically built to
    reference FUTURE directly (e.g. to set ``.token`` once learned
    mid-run), so FUTURE can't be constructed *by* this helper.
    """
    submitted = _get_executor().submit(work)
    submitted.add_done_callback(lambda inner: _relay_onto(future, inner))


def _poll_loop(
    target: str,
    token: str,
    *,
    key: Optional[str],
    timeout: Optional[float],
    poll_interval: Optional[Union[float, Callable[[float], float]]],
) -> str:
    sleep_for = _resolve_poll_sleep(poll_interval)
    start = time.monotonic()
    while True:
        reply = eval_blocking(
            target,
            [Sym("sprite-async-poll"), token],
            key=key,
            timeout=timeout,
        )
        tag, rest = parse_poll_reply(reply or "")
        if tag == ":pending":
            elapsed = time.monotonic() - start
            time.sleep(sleep_for(elapsed))
            continue
        if tag == ":resolved":
            return rest if rest is not None else ""
        if tag == ":rejected":
            raise SpriteAsyncError(rest or "rejected")
        if tag == ":unknown":
            raise SpriteAsyncError(
                f"sprite-async token unknown (not found or expired): {token}"
            )
        raise SpriteAsyncError(f"unrecognized sprite-async-poll reply: {reply!r}")


def eval_non_blocking(
    target: str,
    form: Form,
    *,
    key: Optional[str] = None,
    timeout: Optional[float] = None,
    ttl_seconds: Optional[float] = None,
    poll_interval: Optional[Union[float, Callable[[float], float]]] = None,
) -> concurrent.futures.Future:
    """Start FORM evaluating in the background on TARGET and return a
    :class:`concurrent.futures.Future` that settles once the daemon
    reports the evaluation resolved or rejected.

    The returned Future gains a ``.token`` attribute, set to ``None``
    immediately and updated to the real token string as soon as the
    background worker learns it (shortly after the initial
    ``sprite-async-start`` call completes).
    """
    # NOTE: `future` is created here, *before* submitting any work, so
    # that the worker closure below can safely reference it — closing
    # over a variable via `executor.submit(...)`'s own return value
    # would race the worker thread against the assignment of that
    # return value back in this (the submitting) thread, since the
    # thread pool can start running the submitted callable before
    # `executor.submit(...)` has returned control to this frame.
    future: concurrent.futures.Future = concurrent.futures.Future()
    future.token = None

    def _run() -> str:
        start_form: List[Form] = [Sym("sprite-async-start"), quote(form)]
        if ttl_seconds is not None:
            start_form.append(ttl_seconds)
        start_reply = eval_blocking(target, start_form, key=key, timeout=timeout)
        token = parse_start_reply(start_reply or "")
        future.token = token
        return _poll_loop(
            target,
            token,
            key=key,
            timeout=timeout,
            poll_interval=poll_interval,
        )

    _spawn(future, _run)
    return future


def resume_future(
    target: str,
    token: str,
    *,
    key: Optional[str] = None,
    timeout: Optional[float] = None,
    poll_interval: Optional[Union[float, Callable[[float], float]]] = None,
) -> concurrent.futures.Future:
    """Resume polling an already-known TOKEN, returning a
    :class:`concurrent.futures.Future` shaped identically to the one
    returned by :func:`eval_non_blocking`.
    """
    future: concurrent.futures.Future = concurrent.futures.Future()
    future.token = token

    def _run() -> str:
        return _poll_loop(
            target,
            token,
            key=key,
            timeout=timeout,
            poll_interval=poll_interval,
        )

    _spawn(future, _run)
    return future
