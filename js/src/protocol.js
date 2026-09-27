/**
 * Wire-protocol encode/decode and response reassembly for sprite-direct.
 *
 * Quoting table (single-pass, one special character at a time — never
 * sequential global replaces, which would double-encode):
 *
 *   & -> &&
 *   - -> &-
 *   (space) -> &_
 *   \n -> &n
 *
 * Applied to the entire printed Lisp form before it goes out after
 * `-eval`, and to each `-print`/`-print-nonl`/`-error` payload before
 * it's read back.
 */

/** Wire-encode a raw string for transmission. */
export function encode(value) {
  let out = "";
  for (const ch of value) {
    switch (ch) {
      case "&":
        out += "&&";
        break;
      case "-":
        out += "&-";
        break;
      case " ":
        out += "&_";
        break;
      case "\n":
        out += "&n";
        break;
      default:
        out += ch;
    }
  }
  return out;
}

/** Wire-decode a payload read back from the server. */
export function decode(value) {
  let out = "";
  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i];
    if (ch === "&") {
      const next = value[i + 1];
      if (next === "&") {
        out += "&";
        i += 1;
      } else if (next === "-") {
        out += "-";
        i += 1;
      } else if (next === "_") {
        out += " ";
        i += 1;
      } else if (next === "n") {
        out += "\n";
        i += 1;
      } else {
        // Not a recognized escape sequence; pass the '&' through as-is.
        out += ch;
      }
    } else {
      out += ch;
    }
  }
  return out;
}

/**
 * Build the request line to send to the server.
 *
 * `-auth KEY` is omitted entirely when key is nullish (local Unix-socket
 * targets authenticate via peer UID, not a cookie).
 */
export function buildRequestLine(encodedForm, key) {
  const auth = key != null ? `-auth ${key} ` : "";
  return `${auth}-eval ${encodedForm} \n`;
}

/**
 * Parse a fully-buffered response (all bytes read to EOF/close) per the
 * response reassembly algorithm:
 *
 *   1. Split on newlines.
 *   2. `-print PAYLOAD` / `-print-nonl PAYLOAD`: decode PAYLOAD, append
 *      to an accumulator in line order.
 *   3. `-error PAYLOAD`: decode PAYLOAD, whole response is an error with
 *      PAYLOAD as the message.
 *   4. `-emacs-pid PID`: ignore (preamble, sent before any result).
 *   5. No `-print`/`-print-nonl`/`-error` line found: treat as empty.
 *
 * Returns one of:
 *   { status: "ok", value: string }
 *   { status: "error", message: string }
 *   { status: "empty" }
 */
export function parseResponse(raw) {
  const lines = raw.split("\n");
  let sawResult = false;
  let value = "";

  for (const line of lines) {
    if (line === "") continue;
    if (line.startsWith("-print-nonl ")) {
      sawResult = true;
      value += decode(line.slice("-print-nonl ".length));
    } else if (line.startsWith("-print ")) {
      sawResult = true;
      value += decode(line.slice("-print ".length));
    } else if (line.startsWith("-error ")) {
      return { status: "error", message: decode(line.slice("-error ".length)) };
    } else if (line.startsWith("-emacs-pid ")) {
      // preamble; ignore
      continue;
    }
    // Unrecognized lines are ignored rather than raising, to stay
    // forward-compatible with server chatter this client doesn't know
    // about yet.
  }

  if (!sawResult) {
    return { status: "empty" };
  }
  // Emacs's real server.el builds every reply with (pp v), not
  // prin1/%S -- pp always appends a trailing newline (verified
  // against a live `emacs --daemon`; see fixtures/CONTRACT.md). Strip
  // exactly one, matching what a Lisp `read` of the text would
  // discard as insignificant trailing whitespace.
  if (value.endsWith("\n")) {
    value = value.slice(0, -1);
  }
  return { status: "ok", value };
}
