#!/usr/bin/env node
/**
 * Evaluate `(FUNC arg1 arg2 ...)` in a running sprite daemon, mirroring
 * `cmd/sprite/call.go`'s `runCall`: FUNC and a JSON array of arguments
 * are given as CLI args, translated to sprite-direct's tagged sexp
 * forms, and the raw eval result is printed.
 *
 * This is illustrative only, not a production tool.
 *
 * Usage: node call-with-args.js <socket-path|host:port:key> <func-name> <json-args-array>
 */

import { evalBlocking, quote, sym } from "../src/index.js";

/**
 * Mirrors cmd/sprite/args.go's TranslateArgsJSON/jsonToSexp: translates
 * a decoded JSON value to a sprite-direct sexp form (string -> plain
 * string, number -> plain number, true/false/null ->
 * sym("t")/sym("nil"), array -> a quoted list).
 */
function jsonToSexp(v) {
  if (v === null) return sym("nil");
  if (typeof v === "boolean") return v ? sym("t") : sym("nil");
  if (typeof v === "string") return v;
  if (typeof v === "number") return v;
  if (Array.isArray(v)) return quote(v.map(jsonToSexp));
  throw new TypeError(`unsupported JSON value in args: ${JSON.stringify(v)}`);
}

function translateArgsJSON(raw) {
  if (!raw.trim()) return [];
  const values = JSON.parse(raw);
  if (!Array.isArray(values)) {
    throw new Error("expected a JSON array");
  }
  return values.map(jsonToSexp);
}

async function main() {
  if (process.argv.length !== 5) {
    console.error(
      `usage: ${process.argv[1]} <socket-path|host:port:key> <func-name> <json-args-array>`,
    );
    process.exit(2);
  }
  const [, , target, fn, argsJSON] = process.argv;

  let argSexps;
  try {
    argSexps = translateArgsJSON(argsJSON);
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(1);
    return;
  }

  const form = [sym(fn), ...argSexps];

  const result = await evalBlocking(target, form, { timeoutMs: 5000 });
  console.log(result);
}

main().catch((err) => {
  console.error(`call-with-args: error: ${err.message}`);
  process.exit(1);
});
