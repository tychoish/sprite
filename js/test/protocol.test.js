import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { encode, decode, parseResponse } from "../src/protocol.js";
import { sym, quote, printSexp, float } from "../src/sexp.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixturesPath = path.resolve(here, "../../fixtures/protocol.json");
const fixtures = JSON.parse(readFileSync(fixturesPath, "utf8"));

/** Convert a fixture {type, value} form node into an actual sexp form. */
function buildForm(node) {
  switch (node.type) {
    case "sym":
      return sym(node.value);
    case "str":
      return node.value;
    case "int":
      return node.value;
    case "float":
      return float(node.value);
    case "list":
      return node.value.map(buildForm);
    case "quote":
      return quote(buildForm(node.value));
    default:
      throw new Error(`unknown fixture form type: ${node.type}`);
  }
}

test("encode_decode fixtures round-trip", () => {
  for (const { decoded, encoded } of fixtures.encode_decode.cases) {
    assert.equal(encode(decoded), encoded, `encode(${JSON.stringify(decoded)})`);
    assert.equal(decode(encoded), decoded, `decode(${JSON.stringify(encoded)})`);
  }
});

test("sexp_print fixtures", () => {
  for (const { form, printed } of fixtures.sexp_print.cases) {
    assert.equal(printSexp(buildForm(form)), printed);
  }
});

test("Float prints with a decimal point for whole numbers", () => {
  assert.equal(printSexp(float(2)), "2.0");
  assert.equal(printSexp(float(1.5)), "1.5");
});

test("response_reassembly fixtures", () => {
  for (const { name, raw_lines: rawLines, expected } of fixtures.response_reassembly
    .cases) {
    const raw = rawLines.join("\n");
    const result = parseResponse(raw);
    assert.equal(result.status, expected.status, name);
    if (expected.status === "ok") {
      assert.equal(result.value, expected.value, name);
    } else if (expected.status === "error") {
      assert.equal(result.message, expected.message, name);
    }
  }
});
