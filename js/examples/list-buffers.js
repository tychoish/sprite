#!/usr/bin/env node
/**
 * Evaluate `(mapcar #'buffer-name (buffer-list))` in a running sprite
 * daemon and print each buffer name on its own line.
 *
 * This is illustrative only, not a production tool.
 *
 * Usage: node list-buffers.js <socket-path|host:port:key>
 */

import { evalBlocking, sym } from "../src/index.js";

/**
 * Minimal, best-effort split of a printed Lisp list of strings, e.g.
 * `("*scratch*" "foo.txt")`, into its elements. This is NOT a general
 * Lisp reader (v1 of sprite-direct has none, per fixtures/CONTRACT.md)
 * -- it just strips the outer parens and splits on `" "` between
 * quoted strings. It will mis-parse buffer names that themselves
 * contain a `" ` sequence; that's an accepted limitation of this
 * quick-and-dirty approach.
 */
function parseBufferNameList(raw) {
  let s = (raw ?? "").trim();
  if (s.startsWith("(")) s = s.slice(1);
  if (s.endsWith(")")) s = s.slice(0, -1);
  if (!s) return [];
  // Emacs's printer may wrap a long list's printed representation
  // across embedded newlines (observed against a live daemon);
  // collapse any run of whitespace between elements down to a single
  // space before the best-effort split below.
  s = s.split(/\s+/).join(" ");
  return s.split('" "').map((p) => p.replace(/^"|"$/g, ""));
}

async function main() {
  if (process.argv.length !== 3) {
    console.error(`usage: ${process.argv[1]} <socket-path|host:port:key>`);
    process.exit(2);
  }
  const target = process.argv[2];

  const form = [sym("mapcar"), [sym("function"), sym("buffer-name")], [sym("buffer-list")]];

  const result = await evalBlocking(target, form, { timeoutMs: 5000 });
  for (const name of parseBufferNameList(result)) {
    console.log(name);
  }
}

main().catch((err) => {
  console.error(`list-buffers: error: ${err.message}`);
  process.exit(1);
});
