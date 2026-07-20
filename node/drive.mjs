#!/usr/bin/env node
// Thin CLI wrapper over lib.mjs — drives the E2EBridge debug Unix-socket over the wire protocol
// documented in lib.mjs (4-byte BE length + JSON framing).
//
// Socket: pass via SOCK or E2E_SOCK env var (see client() in lib.mjs).
//
// Usage:
//   node drive.mjs tree                      # accessibility tree (identifiers/roles/values) — find selectors
//   node drive.mjs shot <prefix>             # debug.screenshot -> saves each window PNG/JPG next to cwd
//   node drive.mjs perform <id>              # AXPress the element with that accessibility identifier
//   node drive.mjs setval <id> <value>       # set AX value (NOTE: does NOT update SwiftUI bindings — use `type`)
//   node drive.mjs type <text> [id]          # real key events -> updates SwiftUI bindings
//   node drive.mjs key <name> [mods]         # named key + comma-separated modifiers, e.g. key return command
//   node drive.mjs call <op> [argsJSON]      # raw op passthrough, e.g. call debug.ping
//   node drive.mjs ping                      # debug.ping — liveness check
//   node drive.mjs activate                  # debug.activate — bring the app to the foreground
import { client, E2EError } from "./lib.mjs";

const USAGE =
  "usage: drive.mjs tree | shot <prefix> | perform <id> | setval <id> <val> | type <text> [id] | key <name> [mods] | call <op> [json] | ping | activate";
const COMMANDS = ["tree", "shot", "perform", "setval", "type", "key", "call", "ping", "activate"];

const [cmd, a, b] = process.argv.slice(2);

if (!cmd || !COMMANDS.includes(cmd)) {
  console.error(USAGE);
  process.exit(1);
}

try {
  const d = client();
  switch (cmd) {
    case "tree": {
      console.log(await d.flat());
      break;
    }
    case "shot": {
      const paths = await d.shot(a || "shot");
      paths.forEach((p) => console.log(`saved ${p}`));
      break;
    }
    case "perform": {
      console.log(JSON.stringify(await d.perform(a), null, 2));
      break;
    }
    case "setval": {
      console.log(JSON.stringify(await d.setval(a, b), null, 2));
      break;
    }
    case "type": {
      console.log(JSON.stringify(await d.type(a, b), null, 2));
      break;
    }
    case "key": {
      const mods = b ? b.split(",") : [];
      console.log(JSON.stringify(await d.key(a, mods), null, 2));
      break;
    }
    case "call": {
      const args = b ? JSON.parse(b) : {};
      const result = await d.call(a, args);
      const s = JSON.stringify({ ok: true, result });
      console.log(s.length > 2000 ? s.slice(0, 2000) + "…(truncated)" : s);
      break;
    }
    case "ping": {
      console.log(JSON.stringify(await d.ping(), null, 2));
      break;
    }
    case "activate": {
      console.log(JSON.stringify(await d.call("debug.activate", {})));
      break;
    }
  }
} catch (e) {
  if (e instanceof E2EError) {
    console.error("ERR", JSON.stringify({ code: e.code, message: e.message }));
    process.exit(2);
  }
  console.error("FAIL:", e.message);
  process.exit(3);
}
