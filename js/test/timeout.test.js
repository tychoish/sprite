/**
 * Timeout / hung-daemon test suite: exercises evalBlocking's
 * `timeoutMs` option against daemons that either never reply (a
 * genuine infinite Elisp loop) or never accept a connection at all,
 * plus a fast daemon with no timeout configured at all.
 *
 * IMPORTANT finding, recorded here because it shapes every sub-case
 * below: a single hung eval (a genuine `(while t ...)` busy loop) DOES
 * block every other connection to the same daemon, not just the
 * connection that issued it. Emacs's Lisp evaluator is single
 * threaded; server.el's accept loop cannot service (or even accept())
 * any other connection while one Lisp form is running forever --
 * verified directly against a live `emacs --daemon` before writing
 * this suite. So the hung-eval daemon in the first test below is
 * spawned fresh, used for nothing else, and killed immediately after;
 * it is never reused for the "fast daemon, no timeout" case (that case
 * uses SPRITE_TEST_SOCKET's shared daemon, gated the same way
 * integration.test.js gates on it, or is skipped).
 *
 * A second finding: cleanup for a daemon wedged by a hung eval cannot
 * go through emacsclient (or any -eval RPC) -- that RPC would itself
 * queue behind the very form that's hanging, hanging the test's own
 * teardown. Cleanup here always kills the daemon's OS process directly
 * (SIGKILL).
 *
 * Disposable-daemon spawning (the --fg-daemon-vs-daemon pitfall and the
 * AF_UNIX sun_path length limit) is handled by ./helpers.js, shared with
 * integration.test.js.
 */

import test from "node:test";
import assert from "node:assert/strict";

import { evalBlocking } from "../src/conn.js";
import { sym } from "../src/sexp.js";
import { hasEmacs, spawnDisposableUnixDaemon } from "./helpers.js";

const SOCKET = process.env.SPRITE_TEST_SOCKET;
const maybeTest = SOCKET ? test : test.skip;

const emacsPresent = hasEmacs();
const maybeDaemonTest = emacsPresent ? test : test.skip;

// Case 1 + case 4: a genuinely hung eval (an infinite Elisp loop, not
// merely a slow one) against a configured timeout must fire the
// timeout within a generous (~2x) tolerance of the configured
// duration, must not resolve with a success value, and must not leave
// a lingering active handle for the abandoned socket.
maybeDaemonTest("hung eval timeout fires against a disposable daemon", async () => {
  const { sockPath, cleanup } = await spawnDisposableUnixDaemon("spj");
  try {
    // process._getActiveHandles() is undocumented, but is the
    // simplest available signal in plain Node for "did we leak an
    // open handle" without pulling in extra tooling; used here as a
    // best-effort check with generous tolerance, not an exact
    // assertion, per this suite's own case-4 guidance.
    const before = process._getActiveHandles().length;

    const form = [sym("while"), sym("t"), [sym("sleep-for"), 1]];
    const configured = 2000;

    const start = Date.now();
    await assert.rejects(() => evalBlocking(sockPath, form, { timeoutMs: configured }));
    const elapsed = Date.now() - start;

    assert.ok(
      elapsed <= configured * 2,
      `timeout took ${elapsed}ms, want at most ~2x the configured ${configured}ms`
    );

    // Give the destroyed socket's handle a tick to actually unregister
    // before comparing counts.
    await new Promise((r) => setTimeout(r, 100));
    const after = process._getActiveHandles().length;
    assert.ok(
      after <= before + 1,
      `active handle count grew from ${before} to ${after} after a timed-out eval against a hung daemon; possible leak`
    );
  } finally {
    cleanup();
  }
});

// Case 2: with no timeoutMs option at all, a normal fast-replying
// daemon (the shared SPRITE_TEST_SOCKET one, gated exactly like
// integration.test.js) must still succeed promptly -- omitting
// timeoutMs must not impose some implicit ceiling of its own.
maybeTest("no timeout configured: fast daemon unaffected", async () => {
  const start = Date.now();
  const result = await evalBlocking(SOCKET, [sym("+"), 1, 2]);
  const elapsed = Date.now() - start;
  assert.equal(result, "3");
  assert.ok(elapsed <= 2000, `expected a prompt reply with no timeout configured, took ${elapsed}ms`);
});

// Case 3 fallback: evalBlocking has no dial-injection seam (unlike
// Go's protocol.WithDialer), and a genuinely slow *dial* is hard to
// construct without external-network tricks (a backlog-exhaustion
// experiment against a real Unix socket returned an immediate EAGAIN
// rather than blocking, confirmed directly while writing this suite --
// Linux's AF_UNIX listen backlog does not make connect() itself hang).
// So this test falls back to the documented substitute: a connection
// attempt to a socket path that simply doesn't exist must fail
// promptly, not hang, even with a timeout configured that's much
// longer than the failure should take.
test("connecting to a nonexistent socket path fails promptly", async () => {
  const start = Date.now();
  await assert.rejects(() =>
    evalBlocking("/tmp/sprite-timeout-test-nonexistent-socket-path.sock", sym("t"), {
      timeoutMs: 2000,
    })
  );
  const elapsed = Date.now() - start;
  assert.ok(elapsed <= 2000, `connecting to a nonexistent socket path took ${elapsed}ms, want a prompt failure`);
});
