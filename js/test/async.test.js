/**
 * Fan-out / concurrency tests for evalBlocking.
 *
 * This library ships exactly one eval entry point (evalBlocking), which
 * is already Promise-based end-to-end -- see README.md's "For
 * concurrent fan-out..." section. There is no separate async/future
 * API to test here (unlike the sibling Python/Go/Rust sprite-direct
 * clients): concurrent dispatch is just several evalBlocking() calls
 * issued at once and awaited together via Promise.all, exactly as
 * documented. These tests confirm that pattern actually composes
 * correctly -- many simultaneous calls settle independently, in order,
 * with no cross-contamination between targets -- against fake
 * Unix-socket servers, with no live Emacs daemon involved.
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

/**
 * Start a Unix-domain server that replies with `response` on every
 * connection it accepts (each connection gets exactly one reply, but
 * the server itself keeps listening and can serve any number of
 * connections in sequence, or concurrently since Node's net server
 * handles each socket independently).
 */
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

test("fan-out: N concurrent evalBlocking calls to distinct servers settle in order, uncontaminated", async () => {
  const N = 5;
  const sockPaths = Array.from({ length: N }, () => tempSocketPath());
  const servers = await Promise.all(
    sockPaths.map((p, i) => serveOnce(p, `-emacs-pid 123\n-print ${i}\n`)),
  );
  try {
    const results = await Promise.all(sockPaths.map((p) => evalBlocking(p, 42)));
    assert.deepEqual(
      results,
      sockPaths.map((_, i) => String(i)),
    );
  } finally {
    servers.forEach((s) => s.close());
  }
});

test("fan-out: one failing target rejects Promise.all with SpriteEvalError without corrupting the others", async () => {
  const N = 5;
  const failingIndex = 2;
  const sockPaths = Array.from({ length: N }, () => tempSocketPath());
  const servers = await Promise.all(
    sockPaths.map((p, i) =>
      serveOnce(
        p,
        i === failingIndex
          ? "-emacs-pid 123\n-error boom\n"
          : `-emacs-pid 123\n-print ${i}\n`,
      ),
    ),
  );
  try {
    await assert.rejects(
      () => Promise.all(sockPaths.map((p) => evalBlocking(p, 42))),
      SpriteEvalError,
    );

    // A second, independent round against fresh connections to the
    // same servers: verify the other N-1 targets fulfill correctly and
    // only the one target rejects, i.e. the failure doesn't hang or
    // cross-contaminate the rest.
    const settled = await Promise.allSettled(
      sockPaths.map((p) => evalBlocking(p, 42)),
    );
    settled.forEach((outcome, i) => {
      if (i === failingIndex) {
        assert.equal(outcome.status, "rejected");
        assert.ok(outcome.reason instanceof SpriteEvalError);
      } else {
        assert.equal(outcome.status, "fulfilled");
        assert.equal(outcome.value, String(i));
      }
    });
  } finally {
    servers.forEach((s) => s.close());
  }
});

test("concurrency: many simultaneous evalBlocking calls across a handful of servers all settle correctly", async () => {
  const SERVER_COUNT = 5;
  const CALL_COUNT = 40;

  const sockPaths = Array.from({ length: SERVER_COUNT }, () => tempSocketPath());
  const servers = await Promise.all(
    sockPaths.map((p, i) => serveOnce(p, `-emacs-pid 123\n-print server-${i}\n`)),
  );
  try {
    // Round-robin CALL_COUNT concurrent calls across SERVER_COUNT
    // servers, so several servers each handle multiple connections,
    // some of them concurrently.
    const calls = Array.from({ length: CALL_COUNT }, (_, i) => i % SERVER_COUNT);
    const results = await Promise.all(
      calls.map((serverIndex) => evalBlocking(sockPaths[serverIndex], 42)),
    );
    results.forEach((result, i) => {
      const serverIndex = calls[i];
      assert.equal(result, `server-${serverIndex}`);
    });
  } finally {
    servers.forEach((s) => s.close());
  }
});
