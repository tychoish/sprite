#!/usr/bin/env node
/**
 * Reproduce sprite.el's `sprite-open-frame` (sprite.el:687): does NOT
 * use the sprite-direct socket protocol at all -- shells out to a real
 * `emacsclient --no-wait --create-frame`, setting DISPLAY (defaulting
 * to ":0" when unset) and unsetting TERM in the child's environment,
 * exactly mirroring sprite.el's `with-environment-variables` block.
 * This is the one example that is a documented exception to the
 * direct-socket protocol, matching sprite.el's own approach.
 *
 * This is illustrative only, not a production tool.
 *
 * Usage: node open-frame.js <socket-name>
 */

import { spawnSync } from "node:child_process";

function main() {
  if (process.argv.length !== 3) {
    console.error(`usage: ${process.argv[1]} <socket-name>`);
    process.exit(2);
  }
  const name = process.argv[2];

  // Simplification: sprite.el resolves the address args via
  // `sprite--emacsclient-address-args', which picks `--server-file'
  // for TCP-registered daemons and `--socket-name' for Unix-socket
  // ones. This example doesn't have access to that infrastructure (or
  // to `server-use-tcp''s value), so a bare `--socket-name=<name>' is
  // used unconditionally; a real caller against a TCP-registered
  // daemon would need `--server-file' instead.
  const addressArg = `--socket-name=${name}`;

  const env = { ...process.env };
  delete env.TERM;
  env.DISPLAY = process.env.DISPLAY || ":0";

  const result = spawnSync("emacsclient", ["--no-wait", "--create-frame", addressArg], {
    env,
    stdio: "inherit",
  });

  if (result.error) {
    console.error(`open-frame: failed to run emacsclient: ${result.error.message}`);
    process.exit(1);
  }
  if (result.status !== 0) {
    console.error(`open-frame: emacsclient exited with ${result.status}`);
    process.exit(1);
  }

  console.log("frame requested");
}

main();
