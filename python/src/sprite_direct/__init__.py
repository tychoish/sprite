"""Client library for the sprite-direct Emacs server wire protocol."""

from .async_ import SpriteAsyncError
from .async_ import eval_non_blocking as eval_non_blocking
from .async_ import resume_future
from .conn import SpriteConnectionError, SpriteEvalError, eval_blocking
from .protocol import decode, encode, parse_response
from .sexp import Quote, Sym, print_sexp, quote, sym

__all__ = [
    "SpriteConnectionError",
    "SpriteEvalError",
    "SpriteAsyncError",
    "eval_blocking",
    "eval_non_blocking",
    "resume_future",
    "decode",
    "encode",
    "parse_response",
    "Quote",
    "Sym",
    "print_sexp",
    "quote",
    "sym",
]

__version__ = "0.1.0"
