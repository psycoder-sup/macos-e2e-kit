#!/usr/bin/env node
// E2E test runner — discovers tests/e2e/*.e2e.mjs, runs them sequentially against a single
// running app instance, reports PASS/FAIL per file with timing, auto-captures a screenshot +
// AX tree on failure, and prints a summary.
//
// Usage:
//   node runner.mjs [--dir tests/e2e] [--filter <substring>] [--sock <path>]
//                    [--artifacts .e2e-artifacts] [--timeout 60000] [--tap]
//
// Test file contract (see templates/example.e2e.mjs):
//   export default async ({ d, expect, artifacts, log }) => { ... };
//   export const name = "...";       // optional, default: filename
//   export const timeout = 30000;    // optional, per-test override of --timeout
//
// Exit codes: 0 all tests passed, 1 any test failed (or no test files found), 2 usage/setup error
// (bad args, unresolved socket path) — the last happens before any test runs.
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { client, expect } from "./lib.mjs";

const DEFAULT_TIMEOUT_MS = 60000;

function parseArgs(argv) {
  const args = {
    dir: "tests/e2e",
    filter: undefined,
    sock: undefined,
    artifacts: ".e2e-artifacts",
    timeout: DEFAULT_TIMEOUT_MS,
    tap: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--dir":
        args.dir = argv[++i];
        break;
      case "--filter":
        args.filter = argv[++i];
        break;
      case "--sock":
        args.sock = argv[++i];
        break;
      case "--artifacts":
        args.artifacts = argv[++i];
        break;
      case "--timeout":
        args.timeout = Number(argv[++i]);
        break;
      case "--tap":
        args.tap = true;
        break;
      default:
        console.error(`runner.mjs: unknown argument "${a}"`);
        process.exit(2);
    }
  }
  if (!Number.isFinite(args.timeout) || args.timeout <= 0) {
    console.error("runner.mjs: --timeout must be a positive number of milliseconds");
    process.exit(2);
  }
  return args;
}

function timestamp() {
  return new Date().toISOString().replace("T", " ").replace("Z", "");
}

function fmtSeconds(ms) {
  return (ms / 1000).toFixed(1) + "s";
}

function makeLog(name, tap) {
  return (msg) => {
    const line = `[${timestamp()}] [${name}] ${msg}`;
    console.log(tap ? `# ${line}` : line);
  };
}

// Races a test's promise against a timeout, always clearing the timer so it can't keep the
// process alive after the race settles.
function withTimeout(promise, ms, label) {
  let timer;
  const timeoutPromise = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`test timed out after ${ms}ms${label ? `: ${label}` : ""}`)),
      ms
    );
  });
  return Promise.race([promise, timeoutPromise]).finally(() => clearTimeout(timer));
}

// First line is the error message; a few stack frames follow for context.
function formatError(error) {
  const lines = [error && error.message ? error.message : String(error)];
  if (error && error.stack) {
    lines.push(...error.stack.split("\n").slice(1, 4).map((l) => l.trim()));
  }
  return lines;
}

// Best-effort failure diagnostics — the app may already be dead (crash, timeout), so a capture
// failure here must never mask the actual test failure.
async function captureFailureArtifacts(driver, dir) {
  try {
    await driver.shot("failure", dir);
  } catch {
    // App unreachable — nothing to save.
  }
  try {
    const windows = await driver.tree();
    fs.writeFileSync(path.join(dir, "tree.json"), JSON.stringify(windows, null, 2));
  } catch {
    // App unreachable — nothing to save.
  }
}

function reportResult(tap, index, name, ok, ms, error) {
  if (tap) {
    console.log(`${ok ? "ok" : "not ok"} ${index} - ${name}`);
    if (!ok && error) {
      for (const line of formatError(error)) console.log(`# ${line}`);
    }
    return;
  }
  if (ok) {
    console.log(`✓ PASS ${name} (${fmtSeconds(ms)})`);
  } else {
    console.log(`✗ FAIL ${name} (${fmtSeconds(ms)})`);
    for (const line of formatError(error)) console.log(`  ${line}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  // Resolve the socket path up front and fail fast — before discovering or running any test.
  const sock = args.sock ?? process.env.SOCK ?? process.env.E2E_SOCK;
  if (!sock) {
    console.error("runner.mjs: no socket path — pass --sock <path> or set SOCK / E2E_SOCK env var");
    process.exit(2);
  }

  const testDir = path.resolve(process.cwd(), args.dir);
  let files;
  try {
    files = fs
      .readdirSync(testDir)
      .filter((f) => f.endsWith(".e2e.mjs"))
      .sort();
  } catch (e) {
    console.error(`runner.mjs: cannot read test dir "${testDir}": ${e.message}`);
    process.exit(1);
    return;
  }
  if (args.filter) {
    files = files.filter((f) => f.includes(args.filter));
  }
  if (files.length === 0) {
    console.error(
      `runner.mjs: no test files (*.e2e.mjs) found in "${testDir}"` +
        (args.filter ? ` matching filter "${args.filter}"` : "")
    );
    process.exit(1);
    return;
  }

  const runTimestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const artifactsRoot = path.resolve(process.cwd(), args.artifacts, runTimestamp);
  const d = client({ sock });

  if (args.tap) {
    console.log("TAP version 13");
    console.log(`1..${files.length}`);
  }

  const results = [];
  const runStart = Date.now();

  // Tests run one at a time against a single app instance — running them in parallel would
  // interleave UI events (clicks, key events) against the same windows. This is deliberate.
  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    const absPath = path.join(testDir, file);
    const testBasename = file.endsWith(".e2e.mjs") ? file.slice(0, -".e2e.mjs".length) : file;

    let mod;
    try {
      mod = await import(pathToFileURL(absPath).href);
    } catch (e) {
      results.push({ ok: false });
      reportResult(args.tap, i + 1, testBasename, false, 0, e);
      continue;
    }

    const testFn = mod.default;
    const displayName = mod.name ?? file;
    const testTimeout = mod.timeout ?? args.timeout;

    if (typeof testFn !== "function") {
      const e = new Error(`"${file}" has no default export function`);
      results.push({ ok: false });
      reportResult(args.tap, i + 1, displayName, false, 0, e);
      continue;
    }

    const testArtifactsDir = path.join(artifactsRoot, testBasename);
    fs.mkdirSync(testArtifactsDir, { recursive: true });
    const log = makeLog(displayName, args.tap);
    const start = Date.now();
    try {
      await withTimeout(
        testFn({ d, expect, artifacts: testArtifactsDir, log }),
        testTimeout,
        displayName
      );
      results.push({ ok: true });
      reportResult(args.tap, i + 1, displayName, true, Date.now() - start);
    } catch (e) {
      const ms = Date.now() - start;
      await captureFailureArtifacts(d, testArtifactsDir);
      results.push({ ok: false });
      reportResult(args.tap, i + 1, displayName, false, ms, e);
    }
  }

  // Drop any per-test artifact dirs that ended up empty (passing tests, or a capture that
  // produced nothing), then the run's artifacts root too if nothing was captured at all.
  try {
    for (const entry of fs.readdirSync(artifactsRoot)) {
      const dir = path.join(artifactsRoot, entry);
      if (fs.statSync(dir).isDirectory() && fs.readdirSync(dir).length === 0) {
        fs.rmdirSync(dir);
      }
    }
    if (fs.readdirSync(artifactsRoot).length === 0) {
      fs.rmdirSync(artifactsRoot);
    }
  } catch {
    // Nothing to clean up.
  }

  const passed = results.filter((r) => r.ok).length;
  const failed = results.length - passed;
  const summaryLine = `${passed} passed, ${failed} failed (${fmtSeconds(Date.now() - runStart)} total)`;

  if (args.tap) {
    console.error(summaryLine);
  } else {
    console.log("");
    console.log(summaryLine);
  }

  process.exit(failed === 0 ? 0 : 1);
}

await main();
