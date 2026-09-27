"""Tagged S-expression builder and Lisp-syntax printer.

Builds forms with the tagged constructors below and prints them to
Lisp reader syntax with :func:`print_sexp`. This printing step is
independent of, and happens *before*, the wire-protocol encode/decode
in :mod:`sprite_direct.protocol` — the pipeline is:

    build form -> print_sexp(form) -> encode(text) -> send over wire
"""

from __future__ import annotations

from typing import List, Union


class Sym(str):
    """A symbol: a string subclass that prints bare (unquoted)."""

    __slots__ = ()

    def __repr__(self) -> str:  # pragma: no cover - debugging aid only
        return f"Sym({str.__repr__(self)})"


class Quote:
    """Wraps a form so it prints as ``(quote form)``."""

    __slots__ = ("form",)

    def __init__(self, form: "Form") -> None:
        self.form = form

    def __repr__(self) -> str:  # pragma: no cover - debugging aid only
        return f"Quote({self.form!r})"


Form = Union[Sym, str, int, float, list, Quote]


def sym(name: str) -> Sym:
    """Construct a symbol form."""
    return Sym(name)


def quote(form: Form) -> Quote:
    """Construct a quoted form: prints as ``(quote form)``."""
    return Quote(form)


def _escape_string(value: str) -> str:
    """Escape a Python string Lisp-``prin1``-style: backslash and quote."""
    out = []
    for ch in value:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        else:
            out.append(ch)
    return "".join(out)


def print_sexp(form: Form) -> str:
    """Print a tagged form to Lisp reader syntax (no wire encoding)."""
    if isinstance(form, Sym):
        return str(form)
    if isinstance(form, Quote):
        return f"(quote {print_sexp(form.form)})"
    if isinstance(form, str):
        return f'"{_escape_string(form)}"'
    if isinstance(form, bool):
        # bool is an int subclass in Python; guard against silent
        # misprinting of True/False as 1/0 without an explicit form.
        raise TypeError(
            "bool is not a supported sexp form; use int(0)/int(1) or a Sym"
        )
    if isinstance(form, int):
        return str(form)
    if isinstance(form, float):
        return repr(form)
    if isinstance(form, list):
        return "(" + " ".join(print_sexp(item) for item in form) + ")"
    raise TypeError(f"unsupported sexp form: {form!r}")
