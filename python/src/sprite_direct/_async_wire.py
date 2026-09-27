"""Hand-rolled parsing helpers for the ``sprite-async-start`` /
``sprite-async-poll`` reply text (private module: no Lisp reader
exists in this library, and none is added here — this mirrors the
existing hand-parsing style of :func:`sprite_direct.protocol.parse_response`).
"""

from __future__ import annotations

from typing import Optional, Tuple


def _unquote_prin1_string(text: str) -> str:
    """Strip one leading/trailing ``"`` and unescape ``\\"`` -> ``"``
    and ``\\\\`` -> ``\\`` within TEXT, matching Emacs ``prin1``
    string-printing syntax.
    """
    if len(text) < 2 or not (text.startswith('"') and text.endswith('"')):
        raise ValueError(f"not a prin1-quoted string: {text!r}")
    inner = text[1:-1]
    out = []
    i = 0
    n = len(inner)
    while i < n:
        ch = inner[i]
        if ch == "\\" and i + 1 < n:
            nxt = inner[i + 1]
            if nxt == '"':
                out.append('"')
                i += 2
                continue
            if nxt == "\\":
                out.append("\\")
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def parse_start_reply(text: str) -> str:
    """Parse the reply to ``(sprite-async-start ...)``: a
    ``prin1``-quoted Lisp string containing the bare token.
    """
    return _unquote_prin1_string(text.strip())


def parse_poll_reply(text: str) -> Tuple[str, Optional[str]]:
    """Parse the reply to ``(sprite-async-poll ...)``.

    Returns (tag, rest) where tag is one of ":pending", ":resolved",
    ":rejected", ":unknown" and rest is:

    - None for ":pending"/":unknown"
    - the raw printed value text (verbatim, unparsed) for ":resolved"
    - the unquoted, unescaped error message string for ":rejected"
    """
    stripped = text.strip()
    if not (stripped.startswith("(") and stripped.endswith(")")):
        raise ValueError(f"not a poll reply list: {text!r}")
    inner = stripped[1:-1]
    parts = inner.split(None, 1)
    tag = parts[0] if parts else ""
    rest = parts[1] if len(parts) > 1 else None

    if tag == ":rejected" and rest is not None:
        rest = _unquote_prin1_string(rest)

    return tag, rest
