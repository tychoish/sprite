#!/usr/bin/env python3
"""Evaluate `(FUNC arg1 arg2 ...)` in a running sprite daemon,
mirroring `cmd/sprite/call.go`'s `runCall`: FUNC and a JSON array of
arguments are given as CLI args, translated to sprite_direct's tagged
sexp forms, and the raw eval result is printed.

This is illustrative only, not a production tool.

Usage: call_with_args.py <socket-path|host:port:key> <func-name> <json-args-array>
"""

import json
import sys

from sprite_direct import eval_blocking, quote, sym


def json_to_sexp(v):
    """Mirrors cmd/sprite/args.go's TranslateArgsJSON/jsonToSexp:
    translates a decoded JSON value to a sprite_direct sexp form
    (string -> str, number -> int/float, true/false/null ->
    sym("t")/sym("nil"), array -> a quoted list).
    """
    if v is None:
        return sym("nil")
    if isinstance(v, bool):
        return sym("t") if v else sym("nil")
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, list):
        return quote([json_to_sexp(elem) for elem in v])
    raise TypeError(f"unsupported JSON value in args: {v!r}")


def translate_args_json(raw):
    if not raw.strip():
        return []
    values = json.loads(raw)
    if not isinstance(values, list):
        raise ValueError("expected a JSON array")
    return [json_to_sexp(v) for v in values]


def main():
    if len(sys.argv) != 4:
        print(
            f"usage: {sys.argv[0]} <socket-path|host:port:key> <func-name> <json-args-array>",
            file=sys.stderr,
        )
        sys.exit(2)
    target, fn, args_json = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        arg_sexps = translate_args_json(args_json)
    except (ValueError, TypeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    form = [sym(fn)] + arg_sexps

    result = eval_blocking(target, form, timeout=5)
    print(result)


if __name__ == "__main__":
    main()
