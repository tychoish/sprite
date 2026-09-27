"""Client library for the sprite-direct Emacs server wire protocol."""

from .conn import SpriteConnectionError, SpriteEvalError, eval_blocking
from .protocol import decode, encode, parse_response
from .sexp import Quote, Sym, print_sexp, quote, sym

__all__ = [
    "SpriteConnectionError",
    "SpriteEvalError",
    "eval_blocking",
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
