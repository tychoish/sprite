/**
 * Blocking (Promise-based) connect-send-receive-parse eval over both
 * Unix-domain sockets and TCP targets.
 *
 * Per the sprite-direct contract, JavaScript ships exactly one API:
 * evalBlocking(), a Promise wrapping Node's already-async `net` module.
 * There is no separate synchronous variant, and no non-blocking variant
 * beyond what awaiting the Promise already gives you for free.
 *
 * Connection targets:
 *   - Unix domain socket: pass the resolved socket path directly as
 *     `target` (e.g. "/run/user/1000/emacs/server"). No key required —
 *     Emacs 29+ authenticates local connections via peer UID (SO_PEERCRED)
 *     rather than a cookie file.
 *   - TCP: pass a "HOST:PORT:KEY" string as `target`, or pass host/port
 *     via `target` as "HOST:PORT" and supply `key` in options. A TCP
 *     target with no key is an error, rejected before any connection is
 *     attempted. TCP is trusted-network-only: the key is sent in the
 *     clear on every request, and there is no TLS layer, matching the
 *     Elisp reference implementation's own assumption.
 *
 * One eval is one connection: a fresh socket is opened per call, the
 * request line is sent, all bytes are buffered until the server closes
 * the connection (EOF), and only then is the response parsed. Sockets
 * are never pooled or reused.
 */

import * as net from "node:net";
import { encode, buildRequestLine, parseResponse } from "./protocol.js";
import { printSexp } from "./sexp.js";

/** Raised when the server returns a `-error` response, or when a TCP
 * target is missing its mandatory auth key. */
export class SpriteEvalError extends Error {
  constructor(message) {
    super(message);
    this.name = "SpriteEvalError";
  }
}

/**
 * Parse `target` into a connection descriptor.
 *
 * - If target contains no ":" (or exactly one, for an IPv6-free bare
 *   path), it's treated as a Unix-domain socket path.
 * - Otherwise it's treated as "HOST:PORT" or "HOST:PORT:KEY" for TCP.
 *
 * This is a small, deliberately simple heuristic: a target is TCP only
 * when it looks like "host:port[:key]" with a numeric port segment;
 * anything else (including paths containing colons, which is unusual
 * but possible) is treated as a Unix socket path.
 */
function parseTarget(target, explicitKey) {
  const parts = target.split(":");
  if (parts.length >= 2 && /^\d+$/.test(parts[1])) {
    const [host, port, tcpKey] = parts;
    const key = explicitKey ?? tcpKey ?? null;
    return { type: "tcp", host, port: Number(port), key };
  }
  return { type: "unix", path: target, key: explicitKey ?? null };
}

/**
 * Open the underlying net socket for a parsed connection descriptor.
 * Kept as a small seam so a future live-daemon integration test suite
 * can substitute a fake/mock transport without touching the rest of
 * this module.
 */
function openSocket(conn) {
  if (conn.type === "unix") {
    return net.createConnection({ path: conn.path });
  }
  return net.createConnection({ host: conn.host, port: conn.port });
}

/**
 * Evaluate FORM (a printed sexp, or a tagged sexp builder form) against
 * TARGET, a Unix socket path or a "HOST:PORT[:KEY]" TCP target string.
 *
 * Options:
 *   - key: explicit auth key, overriding any key embedded in a TCP
 *     target string. Ignored for Unix-socket targets.
 *   - timeoutMs: optional socket idle timeout; on expiry the socket is
 *     destroyed and the returned Promise rejects.
 *
 * Resolves to the raw decoded response string (or null if the server
 * returned no -print/-print-nonl/-error line at all — only the
 * -emacs-pid preamble). Rejects with a SpriteEvalError on a -error
 * response, a missing TCP key, or a socket-level failure.
 */
export function evalBlocking(target, form, { key, timeoutMs } = {}) {
  const conn = parseTarget(target, key);

  if (conn.type === "tcp" && !conn.key) {
    return Promise.reject(
      new SpriteEvalError(
        `sprite-direct: TCP target ${target} requires an auth key`
      )
    );
  }

  const text = typeof form === "string" ? form : printSexp(form);
  const requestLine = buildRequestLine(encode(text), conn.key);

  return new Promise((resolve, reject) => {
    const socket = openSocket(conn);
    let buffer = "";
    let settled = false;

    const fail = (err) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(err instanceof SpriteEvalError ? err : new SpriteEvalError(err.message));
    };

    if (timeoutMs) {
      socket.setTimeout(timeoutMs);
      socket.on("timeout", () => {
        fail(new Error(`sprite-direct: timed out after ${timeoutMs}ms`));
      });
    }

    socket.on("connect", () => {
      socket.write(requestLine);
    });

    // Stopping at EOF (socket "close") alone is not enough: verified
    // against a live emacs --daemon that after sending an -error
    // reply, the server does NOT promptly close the connection the
    // way it does after a successful reply -- an internal cleanup
    // eventually closes it, but only after a multi-second,
    // unspecified delay (on top of Emacs's own ~1-2s delay generating
    // the error reply, which is inherent server-side latency, not a
    // bug here). So finish as soon as a complete "-error PAYLOAD"
    // line has been seen, rather than waiting for the socket to
    // close. -print/-print-nonl still requires waiting for close,
    // since a large value's continuation lines carry no marker for
    // which one is last (see CONTRACT.md).
    const finish = () => {
      if (settled) return;
      settled = true;
      socket.destroy();
      const result = parseResponse(buffer);
      if (result.status === "ok") {
        resolve(result.value);
      } else if (result.status === "error") {
        reject(new SpriteEvalError(result.message));
      } else {
        resolve(null);
      }
    };

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      if (hasCompleteErrorLine(buffer)) {
        finish();
      }
    });

    socket.on("error", (err) => {
      fail(err);
    });

    socket.on("close", finish);
  });
}

/**
 * Return true when buffer contains a full, newline-terminated
 * "-error ..." line. Only text up to the last "\n" is considered
 * "complete" -- a trailing, not-yet-terminated fragment is still in
 * flight.
 */
function hasCompleteErrorLine(buffer) {
  const last = buffer.lastIndexOf("\n");
  if (last < 0) return false;
  return buffer
    .slice(0, last)
    .split("\n")
    .some((line) => line.startsWith("-error "));
}
