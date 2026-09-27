/**
 * Shared disposable-daemon helpers for live-daemon test suites
 * (integration.test.js, timeout.test.js). Spawns a uniquely-named
 * `emacs --fg-daemon` (not `--daemon`, which double-forks and detaches
 * so the tracked pid isn't the real daemon -- see fixtures/CONTRACT.md
 * background) in a fresh, short-pathed XDG_RUNTIME_DIR, waits for its
 * socket/auth file to appear, and returns a `cleanup()` that
 * unconditionally kills the process and removes its temp dirs.
 */

import { spawnSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";

export const EMACS_PATH = (() => {
  const found = spawnSync("which", ["emacs"], { encoding: "utf8" });
  return found.status === 0 ? found.stdout.trim() : null;
})();

export function hasEmacs() {
  return EMACS_PATH !== null;
}

/** Skips test `t` and returns false if no `emacs` binary is on PATH. */
export function requireEmacsOrSkip(t) {
  if (!EMACS_PATH) {
    t.skip("emacs binary not found on PATH; skipping live-daemon test");
    return false;
  }
  return true;
}

let nameCounter = 0;
/** Short, unique disposable-daemon name (AF_UNIX sun_path is ~108 bytes). */
export function uniqueName(prefix) {
  nameCounter += 1;
  return `${prefix}${process.pid % 100000}${nameCounter}`;
}

function waitForPath(p, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve) => {
    const check = () => {
      if (existsSync(p)) {
        resolve(true);
        return;
      }
      if (Date.now() > deadline) {
        resolve(false);
        return;
      }
      setTimeout(check, 100);
    };
    check();
  });
}

/** Spawns a disposable `emacs --fg-daemon` on a Unix socket. Resolves
 * once the socket appears; throws (after killing the process) if it
 * doesn't. Returns { sockPath, child, cleanup }. */
export async function spawnDisposableUnixDaemon(prefix) {
  const name = uniqueName(prefix);
  const xdg = mkdtempSync(join(tmpdir(), "sprite-fg-"));
  const child = spawn(
    EMACS_PATH,
    [`--fg-daemon=${name}`, "--no-init-file", "--no-site-file"],
    { env: { ...process.env, XDG_RUNTIME_DIR: xdg }, stdio: "ignore" }
  );
  const cleanup = () => {
    try {
      child.kill("SIGKILL");
    } catch {
      // already gone
    }
    try {
      rmSync(xdg, { recursive: true, force: true });
    } catch {
      // best-effort
    }
  };
  const sockPath = join(xdg, "emacs", name);
  const ok = await waitForPath(sockPath);
  if (!ok) {
    cleanup();
    throw new Error(`disposable daemon socket ${sockPath} never appeared`);
  }
  return { sockPath, child, cleanup };
}

/** Spawns a disposable `emacs --fg-daemon` with `server-use-tcp`
 * enabled and its own private `server-auth-dir`. Returns { host, port,
 * key, child, cleanup }. */
export async function spawnDisposableTcpDaemon(prefix) {
  const name = uniqueName(prefix);
  const xdg = mkdtempSync(join(tmpdir(), "sprite-fg-"));
  const authDir = mkdtempSync(join(tmpdir(), "sprite-auth-")) + sep;
  const evalExpr = `(setq server-use-tcp t server-auth-dir "${authDir}")`;
  const child = spawn(
    EMACS_PATH,
    [`--fg-daemon=${name}`, "--no-init-file", "--no-site-file", "--eval", evalExpr],
    { env: { ...process.env, XDG_RUNTIME_DIR: xdg }, stdio: "ignore" }
  );
  const cleanup = () => {
    try {
      child.kill("SIGKILL");
    } catch {
      // already gone
    }
    try {
      rmSync(xdg, { recursive: true, force: true });
    } catch {
      // best-effort
    }
    try {
      rmSync(authDir, { recursive: true, force: true });
    } catch {
      // best-effort
    }
  };
  const authFile = join(authDir, name);
  const ok = await waitForPath(authFile);
  if (!ok) {
    cleanup();
    throw new Error(`disposable TCP daemon auth file ${authFile} never appeared`);
  }
  // server.el writes: line 1 "HOST:PORT PID", line 2 the raw auth key
  // (verified against a live server-use-tcp daemon).
  const lines = readFileSync(authFile, "utf8").split("\n");
  const [host, port] = lines[0].split(" ")[0].split(":");
  const key = lines[1];
  return { host, port, key, child, cleanup };
}
