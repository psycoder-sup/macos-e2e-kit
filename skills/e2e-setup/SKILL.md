---
name: e2e-setup
description: This skill should be used when the user asks to "set up e2e for my mac app", "add the e2e bridge", "onboard this app for e2e", "wire up e2e testing", "add accessibility identifiers for e2e testing", "맥앱 E2E 셋업", "E2E 브리지 추가" — it onboards a macOS app repo (one-time, not per session) for agent-driven E2E testing by embedding the debug IPC bridge, adopting accessibility-identifier conventions, and scaffolding the harness and a starter test.
---

# E2E Setup

Onboard a macOS app repo for agent-driven E2E testing. Run this once per app repo — not once per
session. Once onboarding is verified, use the `e2e-run` skill every session to actually drive the
app through the scaffolded harness and tests.

All work happens in the **consumer app repo** (the app being onboarded), not in this plugin's own
repo. `docs/integration.md` in this plugin is the full reference this skill summarizes — consult
it for anything a step below doesn't cover in enough depth; don't duplicate it from memory.

## 1. Add the E2EBridge package and start it

Add the Swift package dependency to the consumer app's `Package.swift` (or an Xcode project's
package dependencies):

```swift
.package(url: "https://github.com/<you>/macos-e2e-kit", from: "0.1.0"),
// or, developing against a local checkout:
// .package(path: "../macos-e2e-kit/swift"),
```

and a target dependency on `.product(name: "E2EBridge", package: "macos-e2e-kit")`.

Then start the bridge, gated to debug builds. The real integration is ~3 lines
(verified against `swift/Sources/E2EBridgeCore/E2EBridgeServer.swift`):

```swift
#if DEBUG
let e2e = E2EBridgeServer(driver: AppKitDebugBridge())
try? e2e.start()
#endif
```

Store `e2e` as a property (e.g. on the `AppDelegate`/`App` struct), not a local — a deallocated
local calls `stop()` implicitly and the socket disappears.

**Bare SwiftPM executables** (no `.app` bundle, no `Info.plist`) have a `nil`
`Bundle.main.bundleIdentifier`, so the bridge can't derive a socket directory from it. Pass an
explicit bundle id instead via `socketPath: E2ESocketPath.default(bundleID: "com.example.myapp")`,
and use that same id as `BUNDLE_ID` in the harness (step 3). See
`examples/DemoApp/Sources/DemoApp/main.swift` for the working pattern — including starting the
bridge from `applicationDidFinishLaunching` (not before `app.run()`), which is what makes the
accessibility tree populated by the time a client connects.

**Focus:** never `NSApp.activate`/`makeKeyAndOrderFront` unconditionally at launch — gate on
`BackgroundDrivenMode.isRequested` (DemoApp's `main.swift` is the reference) so harness-driven runs
stay backgrounded and don't steal the user's focus. SwiftUI-lifecycle apps MUST add
`BackgroundDrivenMode.applyIfRequested()` in `App.init()` (gated `#if DEBUG && canImport(E2EBridgeAX)`)
— SwiftUI activates the app during scene bring-up, so wiring it anywhere later (e.g.
`applicationDidFinishLaunching`) is too late. AppKit `main` owners call it before `run()`.
`E2E_FOREGROUND=1` opts out for visual debugging.

Full detail (the `fallback` escape hatch, debug-gating strategies for stricter hosts, instance
isolation via `E2E_INSTANCE`): `${CLAUDE_PLUGIN_ROOT}/docs/integration.md` §§1-4.

## 2. Adopt accessibility identifier conventions

The AX driver walks the app's accessibility tree and selects elements by `identifier`. These
conventions are hard-won — skip them and elements become invisible or unaddressable to
`debug.ui_tree`/`debug.ui_perform`:

- **Every interactive control gets an explicit identifier**, namespaced `area.thing.action`
  (e.g. `.accessibilityIdentifier("todos.addButton.tap")`).
- **Wrap clickable custom rows/cards in a real `Button`** (styled to look like a row if needed) —
  a plain `.onTapGesture` exposes no AXPress action for `debug.ui_perform` to press.
- **Set explicit identifiers on SF Symbol / image buttons.** Without one, the symbol's own name
  leaks into the AX tree as the identifier, and two buttons that happen to share a symbol (two
  "trash" icons in different rows) collide under one id.
- **Thread an `id:` parameter through shared/reusable helper views** so each instance gets its own
  identifier instead of every instance emitting the same one.
- **`contextMenu` items are not AXPress-able.** Where a test needs that action, expose an
  identifier'd alternative (a visible button, a `Menu`, or a keyboard shortcut via `debug.key`).

Full detail and code examples: `${CLAUDE_PLUGIN_ROOT}/docs/integration.md` §5.

## 3. Scaffold the harness and a starter test

Run the init script against the consumer repo (defaults to the current directory):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/e2e-setup/scripts/init.sh [target-dir]
```

This copies `templates/harness.template.sh` → `<target>/e2e/harness.sh` (made executable) and
`templates/example.e2e.mjs` → `<target>/tests/e2e/smoke.e2e.mjs`, skipping either that already
exists rather than overwriting it. Then fill in the FILL-IN functions `e2e/harness.sh` calls out:

| function | required | purpose |
|---|---|---|
| `build_app` | yes | build the app for E2E testing; non-zero exit fails `up` |
| `backend_up` / `backend_down` | no (no-op default) | start/stop any dependent services (DB, mock server) |
| `launch_app` | yes | launch the built binary — **must** `export E2E_INSTANCE="$inst"` before launching (so the app's `E2ESocketPath` derives the matching suffixed socket) and record the PID to `"$state/app.pid"` |
| `app_ready_extra` | no (no-op default) | extra readiness checks beyond `debug.ping` answering |

Also set, at the top of the file: `APP_NAME` (a state-dir slug), `BUNDLE_ID` (must match what the
app reports at runtime — see step 1's bare-executable note), and `KIT_ROOT` (the kit root — your
plugin install root `${CLAUDE_PLUGIN_ROOT}` or a local checkout — from which the harness resolves
`node/drive.mjs` and `templates/harness-lib.sh`). `examples/DemoApp/harness.sh`
in this plugin is a complete, working reference implementation to copy patterns from.

## 4. Optional: register app-specific side-channel ops

For app state that isn't visible in the accessibility tree (a count, an id, a feature flag),
register it on `e2e.registry` — registrations made after `start()` are still visible, so this can
happen from anywhere in the app, not just at startup:

```swift
e2e.registry.register("todos.count") { _ in try JSONValue(encoding: store.todos.count) }
```

Full detail (the handler signature, the `E2EOpError` error contract, decoding typed args):
`${CLAUDE_PLUGIN_ROOT}/docs/integration.md` §3.

## 5. Verify the onboarding end-to-end

Do not consider onboarding done until every piece has actually been exercised:

1. `<target>/e2e/harness.sh up` — succeeds and its last line is `READY inst=<inst> SOCK=<sock>`.
2. `SOCK=<sock> node ${CLAUDE_PLUGIN_ROOT}/node/drive.mjs ping` — answers with `ok: true`.
3. `SOCK=<sock> node ${CLAUDE_PLUGIN_ROOT}/node/drive.mjs tree` — shows the app's own accessibility
   identifiers from step 2 (not empty, not just default AppKit chrome).
4. `node ${CLAUDE_PLUGIN_ROOT}/node/runner.mjs --dir <target>/tests/e2e --sock <sock>` — the
   scaffolded smoke test in `tests/e2e/smoke.e2e.mjs` passes.
5. `<target>/e2e/harness.sh down` — tears down cleanly.

If a step fails, `docs/integration.md` §7 (Troubleshooting) covers the common causes (empty AX
tree, socket connect refused with no response frame, `sun_path` length). `examples/DemoApp` in
this plugin is a complete working reference for every step above — compare against it when
something doesn't line up.

## Next

Onboarding done — use the `e2e-run` skill each session to drive the app through the scaffolded
harness and tests.
