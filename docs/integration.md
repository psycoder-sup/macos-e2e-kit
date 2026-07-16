# Host App Integration Guide

How to wire the `E2EBridge` Swift package into your macOS app, plus the accessibility-identifier
conventions the AX driver (and the agents driving your app) depend on. For the wire protocol
itself (ops, error codes, envelope shapes), see [`protocol.md`](protocol.md) — this doc does not
duplicate it.

## 1. Add the package

Swift Package Manager, `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<you>/macos-e2e-kit", from: "0.1.0"),
    // or, while developing against a local checkout:
    // .package(path: "../macos-e2e-kit/swift"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "E2EBridge", package: "macos-e2e-kit"),
    ]),
]
```

The `E2EBridge` product exports both `E2EBridgeCore` (Foundation-only: IPC types, dispatcher,
socket server) and `E2EBridgeAX` (the AppKit driver) — one import gets you everything:

```swift
import E2EBridge
```

## 2. Start the bridge

The whole integration is ~3 lines, gated to debug builds:

```swift
#if DEBUG
let e2e = E2EBridgeServer(driver: AppKitDebugBridge())
try? e2e.start()
#endif
```

`E2EBridgeServer`'s real initializer (`swift/Sources/E2EBridgeCore/E2EBridgeServer.swift`):

```swift
public init(
    driver: (any DebugBridge)?,
    socketPath: String = E2ESocketPath.default(),
    verifier: any PeerVerifier = SecCodePeerVerifier(),
    registry: E2EOpRegistry = .init(),
    fallback: (@Sendable (IPCRequest) async -> IPCResponse?)? = nil
)
public func start() throws
public func stop()
```

Pass `AppKitDebugBridge()` as the driver for a normal AppKit/SwiftUI app; leave the rest at their
defaults unless you need one of the app-specific ops below.

**Where to start it:** app launch (`applicationDidFinishLaunching` / your `App`'s `init`) is fine —
the driver tolerates the app having no windows yet (`debug.ping` always answers, and `uiTree()`
just returns an empty windows array until one exists). You don't need to wait for login or any
other app-specific readiness; the E2E driver (`node/drive.mjs`'s `ping`/harness `wait_for_ping`)
polls until the process answers.

**Keep a strong reference.** `e2e` (or wherever you store the `E2EBridgeServer`) must outlive the
scope it's created in — store it as a property on your `AppDelegate`/`App` struct, not a local
that gets deallocated. If it's released, `stop()` runs implicitly and the socket disappears.

**Instance isolation.** Multiple copies of your app (one per git worktree, one per parallel test
run) must not fight over the same socket. Set the `E2E_INSTANCE` environment variable before
launching each copy — `E2ESocketPath.default()` (used as `socketPath`'s default) reads it and
appends a `.<instance>` suffix to the Application Support directory, so each instance binds its
own `e2e.sock` (`swift/Sources/E2EBridgeCore/E2ESocketPath.swift`). A plain run with
`E2E_INSTANCE` unset uses the bare bundle id — this is also how your harness's `launch_app()`
should invoke the app (see §6).

**Display name.** Isolation keeps instances apart on disk; the *display name* keeps them apart on
screen. `harness-lib.sh` derives a `label` (the current git branch by default, override with
`E2E_LABEL`) and exports it. A bundleless GUI app has no CFBundleName, so its Dock tile and menu-bar
name come from the process name — identical for every instance. The `labeled_launcher` helper works
around that: it launches the binary through a per-label symlink whose basename is `<AppName>
(<label>)`, so the process name — and thus the Dock/menu name — is unique per instance. The window
title is set in-app from `E2E_LABEL` directly. `label` is purely cosmetic and independent of
`E2E_INSTANCE`: branch names carry slashes (flattened to `-` for the Dock/menu filename; the window
title keeps the literal branch) and can collide across same-branch worktrees, which is fine for a
name but would break socket identity — so the two never share a variable.

## 3. Register app-specific side-channel ops

Beyond the generic `debug.*` surface, your tests will often need app state that isn't visible in
the accessibility tree (a count, an ID, a feature flag). Register it on `e2e.registry`:

```swift
e2e.registry.register("todos.count") { _ in
    try JSONValue(encoding: store.todos.count)
}

e2e.registry.register("todos.get") { args in
    guard let id = args?["id"]?.stringValue, let todo = store.find(id) else {
        throw E2EOpError(code: "not_found", message: "no todo with id \(id ?? "<nil>")")
    }
    return try JSONValue(encoding: todo)
}
```

`register`'s handler is `@Sendable (_ args: JSONValue?) async throws -> JSONValue`
(`swift/Sources/E2EBridgeCore/E2EOpRegistry.swift`). `args` is `nil` when the caller sent no
`args`; otherwise use `JSONValue`'s subscript/`stringValue`/`intValue`/etc. accessors, or decode a
typed model with `args.decoded(as: MyArgs.self)`. Return any `Encodable` value via
`JSONValue(encoding:)` — that's how you bridge a Swift model onto the untyped wire result.

Registrations made *after* `start()` are still visible — the registry is a shared reference type
the dispatcher reads live, so you can register ops as different subsystems initialize, not just at
startup.

**Error contract.** Throw `E2EOpError(code:message:)` to control the response envelope precisely —
the dispatcher maps it straight to `IPCResponse.failure(code:message:)`, so pick a code your tests
can branch on (`"not_found"`, `"invalid_state"`, etc.). Any other thrown error becomes a generic
`"internal"` envelope.

**The `fallback` escape hatch.** If your app already has an internal op dispatcher/switch you
don't want to port to `registry.register` calls one by one, pass `fallback` to the initializer
instead:

```swift
let e2e = E2EBridgeServer(driver: AppKitDebugBridge(), fallback: { request in
    await myExistingDispatcher.handle(request)  // return nil to fall through to unknown_op
})
```

Dispatch order is `debug.*` → registry lookup → `fallback` → `unknown_op` — the fallback only runs
after a registry miss, so per-op `registry.register` calls (if you have any) always win.

## 4. Debug-gating strategy

SwiftPM cannot strip code per build configuration the way an Xcode target's file membership can —
whatever you link, ships in every configuration. The bridge is still safe to leave linked in a
release build, in layers:

1. **Recommended: call `start()` only under `#if DEBUG`.** The socket is opened solely inside
   `start()` — construct the server if you like, but as long as `start()` never runs, no socket
   exists and there is nothing to connect to. This is the `#if DEBUG` guard in §2.
2. **Defense in depth: `PeerVerifier` gates every connection regardless.** Even if `start()` did
   run in a release build, `SecCodePeerVerifier` (`swift/Sources/E2EBridgeCore/PeerVerifier.swift`)
   requires the connecting peer to match: for a team-signed binary, the peer must carry the same
   Developer ID team (`anchor apple generic and certificate leaf[subject.OU] = "<teamID>"`); for an
   unsigned/ad-hoc dev build, it falls back to requiring the same effective UID (`getpeereid`). A
   peer that fails either check is disconnected with no response frame — see protocol.md's "Peer
   verification" section.
3. **For strict hosts that want the integration compiled out entirely** (e.g. you don't want the
   `E2EBridge` import present at all in a release binary), gate the import and the whole block
   behind a custom compilation condition instead of relying on `#if DEBUG` alone:

   ```swift
   // Package.swift, your app target:
   .target(name: "YourApp", dependencies: [...], swiftSettings: [
       .define("E2E_BRIDGE_ENABLED", .when(configuration: .debug)),
   ])
   ```

   ```swift
   #if E2E_BRIDGE_ENABLED
   import E2EBridge
   let e2e = E2EBridgeServer(driver: AppKitDebugBridge())
   try? e2e.start()
   #endif
   ```

   This is stricter than needed for most apps (the runtime gates above are already sufficient) —
   reach for it only if your release process requires provably absent code, not just inert code.

## 5. Accessibility identifier conventions

The AX driver (`AppKitDebugBridge` → `AXTreeCapture`/`AXPerform`) walks your view hierarchy's
accessibility tree, and the Node driver/tests select elements by `identifier`. These conventions
are hard-won from porting a production app's E2E suite — follow them or your elements will be
invisible or unaddressable to `debug.ui_tree`/`debug.ui_perform`:

- **Every interactive control gets an explicit identifier**, namespaced `area.thing.action`:
  ```swift
  Button("Add") { addItem() }
      .accessibilityIdentifier("todos.addButton.tap")
  ```
- **Wrap clickable custom rows/cards in `Button`.** A plain `.onTapGesture` or a custom row/mouse
  handler view exposes no AXPress action — `debug.ui_perform` has nothing to press. Wrap the
  tappable surface in a real `Button` (styled to look like a row if needed) so it gets AXPress:
  ```swift
  Button(action: { select(item) }) {
      RowContent(item: item)
  }
  .buttonStyle(.plain)
  .accessibilityIdentifier("todos.row.\(item.id)")
  ```
- **Set explicit identifiers on SF Symbol / image buttons.** Without one, the symbol's own name
  leaks into the AX tree as the identifier — two different buttons that happen to use the same SF
  Symbol (e.g. two `"trash"` icons in different rows) collide under one id and become
  indistinguishable to a selector:
  ```swift
  Button(action: delete) { Image(systemName: "trash") }
      .accessibilityIdentifier("todos.row.\(item.id).delete")
  ```
- **Shared/reusable helper views take an `id:` parameter.** If a helper view is instantiated
  multiple times (a row template, a reusable menu trigger), thread an `id` through so each instance
  gets its own identifier instead of every instance emitting the same one:
  ```swift
  struct ProjectMenuButton: View {
      let id: String
      var body: some View {
          Menu { /* ... */ } label: { Image(systemName: "ellipsis") }
              .accessibilityIdentifier("project.menu.\(id)")
      }
  }
  ```
- **`contextMenu` items are not AXPress-able.** A right-click/context menu's items don't appear as
  presseable AX elements the driver can target. Where an E2E test needs the same action, expose an
  identifier'd alternative (a visible button, a `Menu`, or a keyboard shortcut driven via
  `debug.key`) rather than relying on the context menu.

## 6. Harness

`templates/harness.template.sh` is the contract every E2E-testable app repo implements — copy it
into your repo as `harness.sh` and fill in the marked sections:

```
harness.sh up [--force]   # idempotent build+launch; last stdout line is machine-parseable:
                           #   READY inst=<inst> label=<label> SOCK=<absolute socket path>
harness.sh down           # tear down ONLY this instance (PID-scoped — never a peer's app)
harness.sh status          # exit 0 if healthy, non-zero otherwise
```

Functions you must (or may) fill in, top to bottom in the template:

| function | required | purpose |
|---|---|---|
| `build_app` | yes | build your app for E2E testing; non-zero exit fails `up` |
| `backend_up` / `backend_down` | no (no-op default) | start/stop any dependent services (DB, mock server) |
| `launch_app` | yes | launch the built binary — **must** `export E2E_INSTANCE="$inst"` before launching (so `E2ESocketPath.default()` derives the matching suffixed socket) and record the PID to `"$state/app.pid"`; for a bundleless GUI app, wrap the binary in `labeled_launcher` so the Dock/menu name is per-instance |
| `app_ready_extra` | no (no-op default) | extra readiness checks beyond `debug.ping` answering |

The template already computes the per-checkout instance token (`inst`, from a hash of the repo's
`git rev-parse --show-toplevel`, overridable via `E2E_INSTANCE`), the display `label` (git branch by
default, overridable via `E2E_LABEL`) plus its `labeled_launcher` helper, the matching socket path
(`~/Library/Application Support/<BUNDLE_ID>.<inst>/e2e.sock` — must match your app's
`E2ESocketPath` derivation), the 104-byte `sun_path` guard, and a `drive()` helper that shells out
to `node "$KIT_ROOT/node/drive.mjs"` against that socket. Point `KIT_ROOT` at the kit root —
your plugin install root `${CLAUDE_PLUGIN_ROOT}` or a local checkout — from which the harness
resolves `node/drive.mjs` and `templates/harness-lib.sh`.

`node/drive.mjs` is the CLI a harness (or you, by hand) uses to poke the running app:

```
node drive.mjs ping                      # debug.ping — liveness check
node drive.mjs tree                      # accessibility tree (identifiers/roles/values)
node drive.mjs shot <prefix>             # debug.screenshot -> saves PNG/JPG per window
node drive.mjs perform <id>              # AXPress the element with that identifier
node drive.mjs setval <id> <value>       # set AX value directly
node drive.mjs type <text> [id]          # real key events -> updates SwiftUI bindings
node drive.mjs key <name> [mods]         # named key + comma-separated modifiers
node drive.mjs call <op> [argsJSON]      # raw op passthrough (e.g. your registered ops)
```

It reads the socket path from `SOCK`/`E2E_SOCK` (or an explicit `{ sock }` in code) — exactly the
`sock` the harness template computed, which is why `up`'s last line prints it.

**`setval` does not update SwiftUI bindings.** `debug.ui_set_value` (the `setval` command) only
mutates the AX `value` attribute directly — `@State`/`@Binding` and anything driven off them
(validation, `onSubmit`, a computed "can I submit" flag) will not react. Use `type` instead
whenever a test needs the app to actually observe the input, exactly as protocol.md's `debug.type`
entry documents.

## 7. Troubleshooting

- **Empty accessibility tree (`debug.ui_tree` returns `{ windows: [] }`).** The app has no visible
  window yet, or is not the active/frontmost app. `uiTree()` only walks *visible* windows — if
  you're driving the app right after launch, poll (the harness's `wait_for_ping` already does this
  for liveness; add your own short retry around `tree` if a window takes longer to appear than the
  process itself does).
- **Socket connect refused / connection immediately closes with no response.** Two likely causes:
  (1) the debug-gated `start()` never ran — check you're running a `#if DEBUG` build (or your
  custom compilation condition is defined) and that `e2e.start()`'s `try?` didn't silently swallow
  a bind failure (check for a stale socket file — remove it and retry, as the harness template's
  `up` does with `rm -f "$sock"`); (2) `PeerVerifier` rejected the connection — this closes the
  connection with **no response frame**, which looks identical to "nothing is listening" from the
  client. Confirm the driver process and the app share the same effective UID (unsigned/dev case)
  or the same code-signing team (signed case) — see §4 and protocol.md's "Peer verification".
- **`sun_path` 104-byte limit.** `~/Library/Application Support/<bundleID>.<E2E_INSTANCE>/e2e.sock`
  can exceed AF_UNIX's 104-byte cap with a long bundle id plus a long instance token, and the
  failure surfaces as an opaque `bind()` error deep inside the app rather than a clear message. The
  harness template checks this itself before launching (`${#sock} -ge 104`) and fails fast with the
  offending path — if you hit this, shorten `E2E_INSTANCE` (the template hashes the repo path to 6
  hex chars by default, but an explicit override can be longer) or `BUNDLE_ID`.
