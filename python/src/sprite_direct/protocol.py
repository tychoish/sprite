"""Wire-protocol encode/decode and response reassembly.

Mirrors ``sprite-direct.el`` / ``server-quote-arg`` and
``server-unquote-arg``: encoding table is

    & -> &&
    - -> &-
    space -> &_
    newline -> &n

applied in a single pass (not sequential global replaces, which would
double-encode). This is applied to the entire printed Lisp form before
it is sent after ``-eval``, and to each ``-print``/``-print-nonl``/
``-error`` payload before it is read back.
"""

from __future__ import annotations

from typing import List, Optional

_ENCODE_MAP = {
    "&": "&&",
    "-": "&-",
    " ": "&_",
    "\n": "&n",
}

_DECODE_MAP = {
    "&": "&",
    "-": "-",
    "_": " ",
    "n": "\n",
}


def encode(text: str) -> str:
    """Encode TEXT for the wire protocol."""
    out = []
    for ch in text:
        out.append(_ENCODE_MAP.get(ch, ch))
    return "".join(out)


def decode(text: str) -> str:
    """Decode a wire-protocol payload back to raw text."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "&" and i + 1 < n:
            nxt = text[i + 1]
            if nxt in _DECODE_MAP:
                out.append(_DECODE_MAP[nxt])
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


class SpriteEvalError(Exception):
    """Raised when the server responds with an ``-error`` line."""


def parse_response(raw: bytes) -> Optional[str]:
    """Reassemble and parse a full response buffer read to EOF.

    Returns the concatenated, decoded result string, or None if no
    -print/-print-nonl/-error line was present at all. Raises
    SpriteEvalError if an -error line was found.
    """
    text = raw.decode("utf-8", errors="replace")
    lines = text.split("\n")

    accumulator: List[str] = []
    found = False

    for line in lines:
        if not line:
            continue
        if line.startswith("-print-nonl "):
            payload = line[len("-print-nonl ") :]
            accumulator.append(decode(payload))
            found = True
        elif line.startswith("-print "):
            payload = line[len("-print ") :]
            accumulator.append(decode(payload))
            found = True
        elif line.startswith("-error "):
            payload = line[len("-error ") :]
            raise SpriteEvalError(decode(payload))
        elif line.startswith("-emacs-pid "):
            # Preamble sent immediately on connect; never part of the
            # eval value.
            continue
        # Unknown/unrecognized lines are ignored per the "must match
        # exactly" algorithm — only the four markers above are defined.

    if not found:
        return None

    # Emacs's real server.el builds every reply with (pp v), not
    # prin1/%S -- pp always appends a trailing newline (verified
    # against a live `emacs --daemon`; see fixtures/CONTRACT.md).
    # Strip exactly one, matching what a Lisp `read` of the text would
    # discard as insignificant trailing whitespace.
    result = "".join(accumulator)
    if result.endswith("\n"):
        result = result[:-1]
    return result
