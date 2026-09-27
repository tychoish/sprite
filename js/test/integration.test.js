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
import {
  requireEmacsOrSkip,
  spawnDisposableUnixDaemon,
  spawnDisposableTcpDaemon,
} from "./helpers.js";

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

maybeTest("wrong-type-argument eval rejects with SpriteEvalError", async () => {
  // (+ 1 "a") is a genuine wrong-type-argument error, distinct in
  // message shape from the unbound-variable case above -- confirms the
  // error path decodes whatever message Emacs actually sends, rather
  // than being hardcoded to one string.
  await assert.rejects(
    () => evalBlocking(SOCKET, [sym("+"), 1, "a"]),
    (err) => {
      assert.ok(err instanceof SpriteEvalError);
      assert.ok(err.message && err.message.length > 0);
      return true;
    }
  );
});

maybeTest("user-error eval rejects with SpriteEvalError", async () => {
  // A genuine (user-error "boom") must surface via the same
  // -error/SpriteEvalError path as any other eval error, not be
  // silently swallowed or routed differently.
  await assert.rejects(
    () => evalBlocking(SOCKET, [sym("user-error"), "boom"]),
    (err) => {
      assert.ok(err instanceof SpriteEvalError);
      assert.match(err.message, /boom/);
      return true;
    }
  );
});

maybeTest(
  "large value eval spans -print-nonl continuation lines",
  async () => {
    // A 5000-byte string is well beyond Emacs's server-msg-size
    // (1024), forcing the server to split the -print-nonl reply
    // across multiple continuation lines. 120 is the char code for
    // ?x. The result is pp/prin1-quoted, so assert on length/content
    // rather than exact equality.
    const result = await evalBlocking(SOCKET, [sym("make-string"), 5000, 120]);
    const xCount = (result.match(/x/g) || []).length;
    assert.equal(xCount, 5000);
    assert.ok(result.startsWith('"x'));
    assert.ok(result.endsWith('x"'));
  }
);

// --- Disposable-daemon cases for TCP and destructive scenarios ---
//
// These spawn their own emacs daemons via ./helpers.js rather than
// relying on SPRITE_TEST_SOCKET, so they're gated independently on the
// `emacs` binary being on PATH, not on SPRITE_TEST_SOCKET.

test("TCP target with no key is rejected before dialing (live daemon)", async (t) => {
  if (!requireEmacsOrSkip(t)) return;

  const { host, port, cleanup } = await spawnDisposableTcpDaemon("jn");
  try {
    // Deliberately omit the key: a TCP target the daemon requires a
    // real auth key for must be rejected client-side before any
    // connection is attempted, confirmed here against a live,
    // key-configured TCP daemon rather than only a fake transport.
    await assert.rejects(
      () => evalBlocking(`${host}:${port}`, sym("t")),
      SpriteEvalError
    );
  } finally {
    cleanup();
  }
});

test("TCP target with a correct key round-trips (live daemon)", async (t) => {
  if (!requireEmacsOrSkip(t)) return;

  const { host, port, key, cleanup } = await spawnDisposableTcpDaemon("jk");
  try {
    const result = await evalBlocking(`${host}:${port}`, [sym("+"), 1, 2], { key });
    assert.equal(result, "3");
  } finally {
    cleanup();
  }
});

test("daemon killed mid-response raises a clean error, not a hang (live daemon)", async (t) => {
  if (!requireEmacsOrSkip(t)) return;

  const { sockPath, child, cleanup } = await spawnDisposableUnixDaemon("jd");
  try {
    // SIGSTOP the daemon before writing the request, then SIGKILL it
    // right after the write completes, so the request bytes are
    // *guaranteed* to still be sitting unread in the daemon's kernel
    // socket receive buffer at the moment it dies (a stopped process
    // cannot read(), no matter how much wall-clock time elapses, so
    // this isn't a timing race the way killing immediately after an
    // ordinary write is).
    //
    // This matters because a plain SIGKILL sent even immediately after
    // write() (verified empirically) usually loses the race in
    // practice against a live daemon over a Unix socket in Node: by
    // the time our own write()/kill() calls run (through several more
    // JS/libuv layers than e.g. Python's synchronous sendall), Emacs's
    // event loop has often already read the pending bytes, so the
    // kernel sees an empty receive buffer at close time and delivers a
    // plain EOF -- indistinguishable from a successful-but-empty
    // response, i.e. no error at all. An unread receive buffer at
    // close time is what makes the kernel send a reset (ECONNRESET)
    // instead of a plain close, and pausing the daemon via SIGSTOP
    // first removes the timing dependency entirely.
    let killed = false;
    try {
      process.kill(child.pid, "SIGSTOP");
      const form = [sym("progn"), [sym("sleep-for"), 2], 1];
      const evalPromise = evalBlocking(sockPath, form, { timeoutMs: 10000 });
      // Give the write a brief moment to actually reach the kernel
      // socket buffer before killing -- the daemon is stopped, so this
      // cannot race with Emacs consuming it; it only needs to outlast
      // evalBlocking's own connect+write.
      await new Promise((resolve) => setTimeout(resolve, 200));
      if (!killed) {
        killed = true;
        child.kill("SIGKILL");
      }
      await assert.rejects(() => evalPromise);
    } finally {
      if (!killed) {
        child.kill("SIGKILL");
      }
    }
  } finally {
    cleanup();
  }
});
