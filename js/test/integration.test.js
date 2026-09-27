/**
 * Live-daemon integration test: exercises evalBlocking against a real
 * `emacs --daemon`, not a fake socket server. Gated on
 * SPRITE_TEST_SOCKET (the resolved Unix-socket path of an
 * already-running daemon), so it is skipped by default in any
 * environment without one -- CI sets this env var after spawning a
 * dedicated test daemon; see .github/workflows/test.yml.
 */

import test from "node:test";
import assert from "node:assert/strict";

import { evalBlocking, SpriteEvalError } from "../src/conn.js";
import { sym } from "../src/sexp.js";

const SOCKET = process.env.SPRITE_TEST_SOCKET;
const maybeTest = SOCKET ? test : test.skip;

maybeTest("arithmetic eval against a live daemon", async () => {
  const result = await evalBlocking(SOCKET, [sym("+"), 1, 2]);
  assert.equal(result, "3");
});

maybeTest("string eval against a live daemon", async () => {
  const result = await evalBlocking(SOCKET, [sym("concat"), "hello", " world"]);
  assert.equal(result, '"hello world"');
});

maybeTest("list eval against a live daemon", async () => {
  const result = await evalBlocking(SOCKET, [sym("list"), 1, 2, 3]);
  assert.equal(result, "(1 2 3)");
});

maybeTest(
  "unbound variable eval rejects with SpriteEvalError",
  async () => {
    // Real Emacs DOES send a genuine -error line for an ordinary eval
    // error, but only if the client doesn't half-close its write side
    // after sending (verified against a live daemon: half-closing
    // races with the server flushing the reply and can silently drop
    // it) -- see conn.js's hasCompleteErrorLine for why this must not
    // simply wait for the socket to close either.
    await assert.rejects(
      () => evalBlocking(SOCKET, sym("this-variable-does-not-exist-anywhere")),
      SpriteEvalError
    );
  }
);
