# E2E Bridge Wire Protocol

The E2E bridge is a length-prefixed JSON request/response protocol spoken over a Unix domain
socket between a Node client (`node/drive.mjs`, `node/lib.mjs`) and an app embedding
`E2EBridgeServer` (Swift). It is process-local: the client and the app must run on the same
machine, as the same user.

## Framing

Each message (request or response) is one frame:

```
[4 bytes: big-endian uint32 length][UTF-8 JSON payload, `length` bytes]
```

- The length prefix counts only the JSON payload, not itself.
- Maximum payload size is **4 MiB** (4 * 1024 * 1024 bytes). A header declaring a larger length
  is a protocol violation — the reader must abort the connection rather than attempt to allocate it.
- One connection carries exactly **one request and one response**. The client opens a new
  connection per call, writes one request frame, reads one response frame, and the server closes
  the connection. There is no multiplexing and no keep-alive.

## Envelopes

Request:

```ts
type IPCRequest = {
  op: string;        // e.g. "debug.ping", "debug.ui_tree", or a host-registered op
  args?: unknown;     // op-specific JSON; omitted/null for ops that take no arguments
};
```

Response (success):

```ts
type IPCResponse = { ok: true; result: unknown };
```

Response (failure):

```ts
type IPCResponse = { ok: false; error: { code: string; message: string } };
```

`result` and `error` are mutually exclusive — exactly one is present, keyed off `ok`.

## Socket path

```
~/Library/Application Support/<bundleID>[.<E2E_INSTANCE>]/e2e.sock
```

- `<bundleID>` is the host app's bundle identifier.
- When the app is launched with the `E2E_INSTANCE` environment variable set, the socket directory
  is suffixed with `.<E2E_INSTANCE>` — this is what lets multiple instances of the same app (e.g.
  one per git worktree, or one per parallel test session) run side by side with fully isolated
  sockets. A plain (non-E2E) run of the app, with `E2E_INSTANCE` unset, uses the bare bundle id
  with no suffix.
- AF_UNIX's `sun_path` field is capped at **104 bytes**. A socket path at or beyond that limit
  fails to `bind()` inside the app with an opaque error — callers that construct this path
  (harness scripts, test runners) should check the length themselves and fail early with a clear
  message instead of letting the app's bind() failure surface as a mysterious startup crash.

## Peer verification

Before a connection is handed to the dispatcher, the server verifies the connecting peer:

1. **Code-signing team match** (default, for signed builds): the server reads its own code
   signature's team identifier. If present, it requires the peer process to satisfy
   `anchor apple generic and certificate leaf[subject.OU] = "<teamID>"` — i.e. signed by the same
   Developer ID team as the server itself.
2. **Same-EUID fallback** (unsigned/ad-hoc dev builds): if the server binary has no team
   identifier (unsigned or ad-hoc signed — the common case for local development), it instead
   requires the peer to share the server's effective UID (`getpeereid`). This is what lets an
   unsigned local dev build accept connections from the Node driver without any signing setup.

A peer that fails verification is disconnected immediately with **no response frame written** —
from the client's perspective the connection simply closes.

## Ops

All ops share the request/response envelope above. Ops under the `debug.*` prefix are always
available when a driver is installed (see below); anything else is dispatched to the host's op
registry (or a fallback handler), then `unknown_op` if nothing claims it.

| op | args | result | notes |
|---|---|---|---|
| `debug.ping` | *(none)* | `{ ok: true, pid: number, version: string }` | Liveness check. Unlike every other `debug.*` op, this one answers even when no driver has been installed yet (`E2EBridgeServer(driver: nil, ...)`) — use it to detect "process is up" independent of "AX driver is wired in". |
| `debug.screenshot` | *(none)* | `{ windows: ScreenshotShot[] }` | In-process render of every visible app window. No screen-recording (TCC) permission required. |
| `debug.ui_tree` | *(none)* | `{ windows: AXNode[] }` | Accessibility tree, one root per window. May require Accessibility (TCC) permission at runtime. |
| `debug.ui_perform` | `{ identifier: string }` | `AXActionResult` | AXPress the element with that accessibility identifier. |
| `debug.ui_set_value` | `{ identifier: string, value: string }` | `AXActionResult` | Sets the AX value attribute directly. **Does not update UI framework bindings** (e.g. SwiftUI `@State`/`@Binding`) — use `debug.type` when the app needs to observe the change (validation, `onSubmit`, etc). |
| `debug.type` | `{ text: string, identifier?: string }` | `AXActionResult` | Synthesizes real key-down/key-up events for each character, delivered window-direct (`NSWindow.sendEvent`) — updates bindings like a person typing would, and never activates the app or steals the user's system focus. If `identifier` is given, that element is focused first; otherwise types into whatever currently has focus. |
| `debug.key` | `{ key: string, modifiers?: string[] }` | `AXActionResult` | Sends one named key (+ optional modifiers) as a real key event, window-direct like `debug.type` — no app activation, no focus steal (the target window gets app-local key status only). Recognized `key` values: `return`, `escape`, `tab`, `delete`, `space`, plus single alphanumeric characters (e.g. `"n"` for ⌘N). Recognized `modifiers`: `command`, `shift`, `option`, `control`. |

Shapes referenced above:

```ts
type ScreenshotShot = {
  title: string;         // window title, or a generic label if untitled
  contentType: string;   // "image/png" or "image/jpeg" (size-overflow fallback)
  dataBase64: string;    // image bytes, base64-encoded
  width: number;          // logical width (points)
  height: number;         // logical height (points)
};

type AXNode = {
  role: string;             // accessibility role, e.g. "AXWindow", "AXButton"
  identifier: string | null; // stable selector, when the view declares one
  label: string | null;      // title/description, when present
  value: string | null;      // current value (text field contents, etc), when present
  enabled: boolean;
  focused: boolean;
  frame: { x: number; y: number; width: number; height: number };
  children: AXNode[];
};

type AXActionResult = {
  identifier: string;       // the identifier the op acted on (or a synthesized label for debug.key)
  role: string;              // accessibility role of the acted-on element
  label: string | null;
  value: string | null;      // debug.ui_set_value/debug.type: the value now set; debug.ui_perform: current value after the press, if readable
};
```

## Error codes

| code | meaning |
|---|---|
| `invalid_args` | The request's `args` didn't decode into what the op expects. |
| `not_found` | No element matches the given `identifier`. |
| `action_unavailable` | The matched element doesn't support the requested action (e.g. `debug.ui_perform` on an element with no AXPress). |
| `perform_failed` | The action was attempted but the underlying accessibility call didn't report success (includes attempting to press a disabled element). |
| `set_failed` | `debug.ui_set_value` couldn't set the value (attribute not settable, or the underlying call failed). |
| `unsupported` | A `debug.*` op was called but no driver is installed (`driver: nil`) — the one exception is `debug.ping`, which always answers. |
| `unknown_op` | The op name isn't a recognized `debug.*` op, a registered op, and wasn't claimed by the fallback handler. |
| `internal` | An unexpected error occurred handling an otherwise-valid request. |

## Host-registered ops

Apps can expose additional, app-specific ops through `E2EBridgeServer.registry` — these share the
exact same request/response envelope as `debug.*` ops (same framing, same `{ok, result}` /
`{ok:false, error}` shape). Dispatch order is: `debug.*` prefix first (driver or `unsupported`,
except `debug.ping`) → registry lookup by exact op name → an optional fallback handler → finally
`unknown_op` if nothing claimed the request. This lets a host app layer its own side-channel
ops (e.g. `todos.count`) on top of the generic E2E surface without the kit needing to know
anything about them.
