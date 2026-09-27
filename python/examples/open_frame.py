#!/usr/bin/env python3
"""Reproduce sprite.el's `sprite-open-frame` (sprite.el:687): does NOT
use the sprite-direct socket protocol at all -- shells out to a real
`emacsclient --no-wait --create-frame`, setting DISPLAY (defaulting to
":0" when unset) and unsetting TERM in the child's environment, exactly
mirroring sprite.el's `with-environment-variables` block. This is the
one example that is a documented exception to the direct-socket
protocol, matching sprite.el's own approach.

This is illustrative only, not a production tool.

Usage: open_frame.py <socket-name>
"""

import os
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <socket-name>", file=sys.stderr)
        sys.exit(2)
    name = sys.argv[1]

    # Simplification: sprite.el resolves the address args via
    # `sprite--emacsclient-address-args', which picks `--server-file'
    # for TCP-registered daemons and `--socket-name' for Unix-socket
    # ones. This example doesn't have access to that infrastructure (or
    # to `server-use-tcp''s value), so a bare `--socket-name=<name>' is
    # used unconditionally; a real caller against a TCP-registered
    # daemon would need `--server-file' instead.
    address_arg = f"--socket-name={name}"

    env = dict(os.environ)
    env.pop("TERM", None)
    env["DISPLAY"] = os.environ.get("DISPLAY") or ":0"

    result = subprocess.run(
        ["emacsclient", "--no-wait", "--create-frame", address_arg],
        env=env,
    )
    if result.returncode != 0:
        print(f"emacsclient exited with {result.returncode}", file=sys.stderr)
        sys.exit(1)

    print("frame requested")


if __name__ == "__main__":
    main()
