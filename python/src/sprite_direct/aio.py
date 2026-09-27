"""Thin ``asyncio`` wrapper around :mod:`sprite_direct.async_`."""

from __future__ import annotations

import asyncio
from typing import Any

from . import async_
from .sexp import Form

__all__ = ["eval_non_blocking", "resume_future"]


async def eval_non_blocking(target: str, form: Form, **kwargs: Any) -> str:
    """``await``-able wrapper around :func:`sprite_direct.async_.eval_non_blocking`:
    starts FORM evaluating in the background on TARGET, then awaits
    the underlying :class:`concurrent.futures.Future` on the running
    event loop and returns its resolved result string. KWARGS are
    passed through unchanged (``key``, ``timeout``, ``ttl_seconds``,
    ``poll_interval``).
    """
    loop = asyncio.get_running_loop()
    future = async_.eval_non_blocking(target, form, **kwargs)
    return await asyncio.wrap_future(future, loop=loop)


async def resume_future(target: str, token: str, **kwargs: Any) -> str:
    """``await``-able wrapper around :func:`sprite_direct.async_.resume_future`:
    resumes polling an already-known TOKEN and returns its resolved
    result string. KWARGS are passed through unchanged (``key``,
    ``timeout``, ``poll_interval``).
    """
    loop = asyncio.get_running_loop()
    future = async_.resume_future(target, token, **kwargs)
    return await asyncio.wrap_future(future, loop=loop)
