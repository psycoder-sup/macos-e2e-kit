---
name: e2e-run
description: >-
  Drive an already-onboarded macOS app end-to-end on a real Debug build over its debug.* IPC
  socket — stand up the app, then observe (shot·tree) → act (perform·type·key) → re-observe to
  confirm a UI change actually works, and run its tests/e2e suite with per-file pass/fail
  classification. Use when asked to "e2e the mac app", "run the macos e2e tests", "drive the app
  and verify", "screenshot the app and check it", "맥앱 E2E", "맥 앱 실제로 띄워서 검증".
---

# e2e-run — drive & verify an onboarded macOS app

Orchestrate the consumer app's `e2e/harness.sh` (stand up / tear down its Debug build + any backend)
and this kit's `node/` CLIs — `drive.mjs` to observe and act, `runner.mjs` to run the suite — to prove
a change works **in the running app**, not just in a green build or unit test. Assumes the app is already
onboarded (bridge embedded, AX identifiers declared, `e2e/harness.sh` present); if not, run **e2e-setup** first.

## Core principles (why)

1. **The bridge answers only in builds where the host started it.** `debug.*` ops require the app to
   have called `E2EBridgeServer.start()`, which hosts gate behind `#if DEBUG` — so always drive a
   **Debug** build; a Release/installed build exposes nothing.
2. **One isolated instance per checkout.** The harness derives an instance token (`E2E_INSTANCE`) per git
   worktree, so parallel sessions each get their own socket, app process, and backend — never colliding.
3. **`setval` does NOT update UI-framework bindings.** `d setval` sets the raw AX value; SwiftUI
   `@State`/`onSubmit`/validation won't fire — to make the app observe input like a person typing use
   **`d type`** (real key events). Submit with **`d key return command`** (⌘↵); dismiss with **`d key escape`**.
4. **A disabled control refusing `perform` is a signal, not an error.** `perform` on a disabled element
   returns `perform_failed` — often exactly the state you're asserting (Submit disabled until a field is filled).

## 1. Stand up
```bash
bash e2e/harness.sh up          # idempotent; add --force to rebuild after editing app code
```

Builds the Debug app, brings up any backend, launches it with `E2E_INSTANCE` set, and waits for
`debug.ping`. Re-running `up` while the app is alive just reprints `READY` (no rebuild); `harness.sh
status` reports health. The final stdout line is machine-parseable — **grab `SOCK` from it**:

```
READY inst=<inst> SOCK=<absolute socket path>
```

- **In the background: redirect to a log file and poll it with the Read tool.** A first/full `up` can
  take minutes. NEVER pipe it through `tail` **without `-f`** — a bare `tail` blocks until stdin hits
  EOF (i.e. until `up` finishes), so the shell looks frozen at "No output available" while the build is
  in fact progressing. Instead run `bash e2e/harness.sh up > /tmp/e2e-up.log 2>&1` (run_in_background),
  then Read `/tmp/e2e-up.log` until the `READY … SOCK=…` line appears.

## 2. Observe → act → re-observe

Alias the driver to THIS session's socket (from `READY`):

```bash
d(){ SOCK="<sock from READY>" node ${CLAUDE_PLUGIN_ROOT}/node/drive.mjs "$@"; }  # path contains a space — always quote it
```

- **Observe** — `d tree` (compact AX tree: identifier·role·value·`[focused]`/`[disabled]`·frame — where
  you find selectors) · `d shot <prefix>` saves a PNG per window, then **open it with the Read tool** to
  check layout visually · `d ping` for liveness.
- **Act** — `d perform <id>` (AXPress) · `d type <text> [id]` (focus `id`, real key events) · `d key
  <name> [mods]` (e.g. `d key return command`, `d key escape`, `d key tab`; mods comma-separated) ·
  `d setval <id> <val>` (raw AX value — observe-only) · `d call <op> [json]` (any registered side-channel
  op — read app state to cross-check a UI change).
- Driving never steals the user's focus: the app runs backgrounded (`.accessory`, no Dock icon) and
  key events are delivered window-direct. Launch with `E2E_FOREGROUND=1` only when the user asks to
  watch the run visually — or bring an already-running instance forward on demand with
  `harness.sh up --open` (or `d activate`).

Worked flow (against `examples/DemoApp` — ops `demo.input`/`demo.add`, side-channel `demo.state`):

```bash
d tree | grep demo.input           # confirm loaded + find selectors
d perform demo.add                 # disabled while input empty → perform_failed (expected)
d type "First item" demo.input     # real keys → Add button enables
d call demo.state                  # before: []
d key return command               # ⌘↵ submits
d call demo.state                  # after: ["First item"] → verified
```

## 3. Run the suite
```bash
node ${CLAUDE_PLUGIN_ROOT}/node/runner.mjs --dir tests/e2e --sock "<sock>"
```

Discovers `tests/e2e/*.e2e.mjs`, runs them **sequentially** against the one app instance, and prints
`✓ PASS`/`✗ FAIL <name> (<time>)` per file plus a `N passed, M failed` summary; exit `0` all-pass, `1`
any-fail (or no tests found), `2` setup error (bad flag / unresolved socket). Flags: `--filter <substr>`
(one test), `--artifacts <dir>`, `--timeout <ms>`, `--tap`. On failure the runner auto-captures
`failure-*.png` + `tree.json` into the artifacts dir — **Read those before touching code.** Test file
contract:

```js
export default async ({ d, expect, artifacts, log }) => { /* … */ };
export const name = "…";       // optional (default: filename)
export const timeout = 30000;  // optional per-test override of --timeout
```

## 4. Verdict discipline

Declare pass only on a **three-way cross-check**: the screenshot (Read the PNG and read it visually) +
the AX tree state (`[disabled]`, values) + a data side-channel (`d call <op>`) all agree. Report with
that evidence — screenshot, tree excerpt, before/after side-channel — not just "looks right".

## 5. Tear down (always)
```bash
bash e2e/harness.sh down          # PID-scoped: only THIS instance, never a peer's app
```

Run it once verification is done; `status` should then show the app stopped and socket missing.

## Edge cases

- **App raced its backend** (a data view shows an error/retry) — the app came up before the backend was
  ready. Re-run `harness.sh up` (the backend is healthy now) for a clean load.
- **Submit stays `[disabled]` after `type`** — the target field likely has no accessibility identifier,
  so focus never landed. Add one per `${CLAUDE_PLUGIN_ROOT}/docs/integration.md`, update the harness/tests, and re-run.
- **`d call`/`d ping` won't connect** — the bridge isn't running: wrong build (not Debug, or `start()`
  not called) or the app isn't up. Check `harness.sh status`.
- **Multiple sessions** — each worktree has its own instance; always drive with THIS session's `READY`
  `SOCK`, and pin names with `E2E_INSTANCE=<name>`. Teardown is PID-scoped, so `down` never hits a peer.
- **Identifiers drifted from the docs** — when the UI renames or drops an identifier, update the
  consumer's `e2e/harness.sh` and `tests/e2e` in the same change as the UI, not just this skill.
