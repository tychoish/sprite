#!/usr/bin/env python3
"""Evaluate `(mapcar #'buffer-name (buffer-list))` in a running sprite
daemon and print each buffer name on its own line.

This is illustrative only, not a production tool.

Usage: list_buffers.py <socket-path|host:port:key>
"""

import sys

from sprite_direct import eval_blocking, sym


def parse_buffer_name_list(raw):
    """Minimal, best-effort split of a printed Lisp list of strings,
    e.g. ``("*scratch*" "foo.txt")``, into its elements. This is NOT a
    general Lisp reader (v1 of sprite-direct has none, per
    fixtures/CONTRACT.md) -- it just strips the outer parens and splits
    on '" "' between quoted strings. It will mis-parse buffer names
    that themselves contain a '" ' sequence; that's an accepted
    limitation of this quick-and-dirty approach.
    """
    s = raw.strip()
    if s.startswith("("):
        s = s[1:]
    if s.endswith(")"):
        s = s[:-1]
    if not s:
        return []
    # Emacs's printer may wrap a long list's printed representation
    # across embedded newlines (observed against a live daemon);
    # collapse any run of whitespace between elements down to a single
    # space before the best-effort split below.
    s = " ".join(s.split())
    parts = s.split('" "')
    return [p.strip('"') for p in parts]


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <socket-path|host:port:key>", file=sys.stderr)
        sys.exit(2)
    target = sys.argv[1]

    form = [
        sym("mapcar"),
        [sym("function"), sym("buffer-name")],
        [sym("buffer-list")],
    ]

    result = eval_blocking(target, form, timeout=5)
    for name in parse_buffer_name_list(result or ""):
        print(name)


if __name__ == "__main__":
    main()
