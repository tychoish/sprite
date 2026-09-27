#!/usr/bin/env node
// Native JS micro-benchmark for evalBlocking against a real
// `emacs --daemon`, using Node's built-in perf_hooks rather than a
// shared cross-language driver -- these numbers are for tracking this
// language's own per-call cost over time, not for a cross-language
// latency comparison.
//
// Gated on SPRITE_TEST_SOCKET, same convention as test/integration.test.js.
// Not picked up by `node --test` (lives outside test/, and isn't named
// *.test.js). Run with:
//
//   SPRITE_TEST_SOCKET=/path/to/socket node bench/bench.js [iterations]
//
// Workload is parameterized via the FORMS table below; iterations
// (per workload) defaults to 200, override with the first CLI arg.

import { performance } from "node:perf_hooks";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { evalBlocking, sym } from "../src/index.js";

const execFileAsync = promisify(execFile);

const SOCKET = process.env.SPRITE_TEST_SOCKET;
if (!SOCKET) {
  console.error("SPRITE_TEST_SOCKET not set; skipping benchmark");
  process.exit(0);
}

const ITERATIONS = Number(process.argv[2] ?? 200);

const FORMS = {
  "small-int": [sym("+"), 1, 2],
  "large-string": [sym("make-string"), 5000, 120],
};

const RAW_FORMS = {
  "small-int": "(+ 1 2)",
  "large-string": "(make-string 5000 120)",
};

function percentile(sortedUs, p) {
  const idx = Math.min(sortedUs.length - 1, Math.floor((p / 100) * sortedUs.length));
  return sortedUs[idx];
}

async function timeit(fn, iterations) {
  const samples = [];
  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    await fn();
    samples.push((performance.now() - start) * 1000); // us
  }
  samples.sort((a, b) => a - b);
  // Discard the first (warm-up) sample from the reported percentiles.
  const warm = samples.slice(1);
  return {
    p50: percentile(warm, 50),
    p95: percentile(warm, 95),
    p99: percentile(warm, 99),
  };
}

async function main() {
  const rows = [];

  for (const [name, form] of Object.entries(FORMS)) {
    const stats = await timeit(() => evalBlocking(SOCKET, form), ITERATIONS);
    rows.push(["evalBlocking", name, stats]);
  }

  let emacsclientAvailable = true;
  try {
    await execFileAsync("which", ["emacsclient"]);
  } catch {
    emacsclientAvailable = false;
  }

  if (emacsclientAvailable) {
    for (const [name, form] of Object.entries(RAW_FORMS)) {
      const stats = await timeit(
        () => execFileAsync("emacsclient", [`--socket-name=${SOCKET}`, "--eval", form]),
        ITERATIONS,
      );
      rows.push(["emacsclient", name, stats]);
    }
  }

  console.log("transport,workload,p50(us),p95(us),p99(us)");
  for (const [transport, name, stats] of rows) {
    console.log(
      `${transport},${name},${stats.p50.toFixed(1)},${stats.p95.toFixed(1)},${stats.p99.toFixed(1)}`,
    );
  }
}

main();
