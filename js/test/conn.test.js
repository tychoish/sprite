/**
 * Connection-layer tests for evalBlocking, using a fake Unix-socket
 * server. These exercise conn.js directly, which the fixture-driven
 * protocol tests do not touch (they only cover the pure encode/decode/
 * sexp/reassembly functions).
 */

import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { evalBlocking, SpriteEvalError } from "../src/conn.js";

function tempSocketPath() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sprite-js-")), "test.sock");
}

/** Start a Unix-domain server that responds once with `response`, then closes. */
function serveOnce(sockPath, response) {
  return new Promise((resolveServerReady) => {
    const server = net.createServer((socket) => {
      socket.on("data", () => {
        socket.end(response);
      });
    });
    server.listen(sockPath, () => resolveServerReady(server));
  });
}

test("evalBlocking over a Unix socket requires no key", async () => {
  const sockPath = tempSocketPath();
  const server = await serveOnce(sockPath, "-emacs-pid 123\n-print 42\n");
  try {
    const result = await evalBlocking(sockPath, 42);
    assert.equal(result, "42");
  } finally {
    server.close();
  }
});

test("evalBlocking rejects with SpriteEvalError on a -error response", async () => {
  const sockPath = tempSocketPath();
  const server = await serveOnce(sockPath, "-emacs-pid 123\n-error boom\n");
  try {
    await assert.rejects(() => evalBlocking(sockPath, 42), SpriteEvalError);
  } finally {
    server.close();
  }
});

test("evalBlocking rejects a TCP target with no key before connecting", async () => {
  // No listener at all on this port -- if it dialed before validating
  // the key, this would reject with a socket connection error instead.
  await assert.rejects(
    () => evalBlocking("127.0.0.1:1", 42),
    SpriteEvalError
  );
});
