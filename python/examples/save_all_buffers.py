#!/usr/bin/env python3
"""Evaluate `(save-some-buffers t)` in a running sprite daemon and
print a one-line confirmation.

This is illustrative only, not a production tool.

Usage: save_all_buffers.py <socket-path|host:port:key>
"""

import sys

from sprite_direct import eval_blocking, sym


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <socket-path|host:port:key>", file=sys.stderr)
        sys.exit(2)
    target = sys.argv[1]

    form = [sym("save-some-buffers"), sym("t")]

    eval_blocking(target, form, timeout=5)
    print("buffers saved")


if __name__ == "__main__":
    main()
