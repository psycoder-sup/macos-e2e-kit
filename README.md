# macos-e2e-kit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

E2E-test any macOS app with an agent. An embeddable debug IPC bridge (Swift package) lets your
app observe and act on itself — no Accessibility (TCC) permission needed for self-inspection —
over a local Unix socket. A zero-dependency Node driver speaks that protocol, and a small runner
turns JS test files into pass/fail results with failure artifacts, so an agent (or you) can drive
observe → act → verify loops against a real, running app.

## Quickstart

**1. Install the plugin**

Once published, add this repo as a marketplace and install it:

```
/plugin marketplace add <owner>/macos-e2e-kit
/plugin install macos-e2e-kit
```

While developing locally, add it as a directory-type marketplace instead:

```
/plugin marketplace add /path/to/macos-e2e-kit
```

**2. Onboard your app**

```
/macos-e2e-kit:e2e-setup
```

Adds the `E2EBridge` Swift package as a dependency, wires the ~3-line `#if DEBUG` bridge startup
into your app, and scaffolds a `harness.sh` from `templates/harness.template.sh` for your repo to
fill in (build/launch functions only — the up/down/status contract is already implemented).

**3. Run E2E tests**

```
ready="$(./harness.sh up)"           # last line: "READY inst=... label=... SOCK=<path>"
export SOCK="${ready##*SOCK=}"
node "${CLAUDE_PLUGIN_ROOT}/node/runner.mjs" --dir tests/e2e
./harness.sh down
```

(`${CLAUDE_PLUGIN_ROOT}` is set by Claude Code when this kit is installed as a plugin and resolves
to this repo's root; point at a local checkout's `node/` directly if you're not running through the
plugin.)

Or drive the app interactively while writing a test — see `/macos-e2e-kit:e2e-run` and
`node/drive.mjs` (`ping`, `tree`, `shot`, `perform`, `setval`, `type`, `key`, `call`).

## Architecture

| Path | What's there |
|---|---|
| `swift/` | SPM package `E2EBridge` (macOS 14+, Swift 6 tools): `E2EBridgeCore` (Foundation-only IPC types, dispatcher, socket server — headless-testable) and `E2EBridgeAX` (the AppKit driver — accessibility tree, event synthesis, window capture). |
| `node/` | Zero-npm-dependency Node ≥18: `lib.mjs` (socket client + `expect()` assertions), `drive.mjs` (CLI for one-off calls), `runner.mjs` (discovers and runs `tests/e2e/*.e2e.mjs`, reports PASS/FAIL + artifacts). |
| `templates/` | `harness.template.sh` — the up/down/status contract every onboarded app repo implements; `example.e2e.mjs` — a test file skeleton. |
| `skills/` | `e2e-setup` (one-time app onboarding: bridge integration + accessibility-identifier conventions + harness scaffold) and `e2e-run` (the observe → act → verify loop + runner usage, for every session). |
| `examples/DemoApp/` | The kit's self-verification target — a plain SPM executable with a programmatic `NSApplication`, its own `harness.sh`, and two example tests. No Xcode project required. |
| `docs/protocol.md` | The wire protocol: framing, envelopes, socket path derivation, peer verification, every `debug.*` op and error code. |
| `docs/integration.md` | The host-app integration guide: adding the package, starting the bridge, registering app-specific ops, debug-gating strategy, accessibility-identifier conventions, and the harness contract. |

## Try it without an app

`examples/DemoApp` is a minimal SwiftUI-over-AppKit app that exercises the whole stack end to end,
with no host app of your own required:

```bash
cd examples/DemoApp
ready="$(./harness.sh up)"                        # builds + launches, last line: "READY inst=... label=... SOCK=..."
export SOCK="${ready##*SOCK=}"                    # runner.mjs/drive.mjs read the socket from SOCK/E2E_SOCK
node ../../node/runner.mjs --dir tests/e2e        # runs add-item.e2e.mjs and keyboard.e2e.mjs
./harness.sh down                                 # tears down this instance only
```

A failing test captures a screenshot and the accessibility tree to `.e2e-artifacts/` before the
runner reports it.

## Requirements

- macOS 14+
- Swift 6 toolchain
- Node ≥ 18 (no npm dependencies)

## License

[MIT](LICENSE) © 2026 SangUk Park
