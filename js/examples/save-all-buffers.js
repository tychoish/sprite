#!/usr/bin/env node
/**
 * Evaluate `(save-some-buffers t)` in a running sprite daemon and
 * print a one-line confirmation.
 *
 * This is illustrative only, not a production tool.
 *
 * Usage: node save-all-buffers.js <socket-path|host:port:key>
 */

import { evalBlocking, sym } from "../src/index.js";

async function main() {
  if (process.argv.length !== 3) {
    console.error(`usage: ${process.argv[1]} <socket-path|host:port:key>`);
    process.exit(2);
  }
  const target = process.argv[2];

  const form = [sym("save-some-buffers"), sym("t")];

  await evalBlocking(target, form, { timeoutMs: 5000 });
  console.log("buffers saved");
}

main().catch((err) => {
  console.error(`save-all-buffers: error: ${err.message}`);
  process.exit(1);
});
