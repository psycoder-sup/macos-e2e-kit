#!/usr/bin/env bash
# E2E harness template — copy into your app repo as harness.sh and fill in the
# marked sections. Drives the app over its debug.* IPC socket via the kit's
# node/drive.mjs (see docs/protocol.md for the wire protocol).
#
#   harness.sh up [--force]   # idempotent build+launch; last stdout line is
#                              #   "READY inst=<inst> SOCK=<absolute socket path>"
#   harness.sh down           # tear down ONLY this instance (PID-scoped, no broad pkill)
#   harness.sh status         # exit 0 if healthy, non-zero otherwise
#
# Multi-session: every git worktree (or plain checkout) gets its own instance token
# `inst`, so two checkouts can run `up` at the same time without colliding — each gets
# its own state dir, socket, and app process. Override the token with E2E_INSTANCE=name.
# Teardown only ever touches PIDs this instance itself recorded — never a peer's app.
#
# Display name: separately, `label` (git branch by default, override with E2E_LABEL) names what you
# SEE — the app's window title, Dock tile, and menu-bar name — so parallel instances are told apart
# at a glance. It is independent of E2E_INSTANCE (which governs socket identity, not the visible name).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════════
# ── FILL IN: your app's identity ──────────────────────────────────────────────
APP_NAME="myapp"                # slug for state-dir naming — no spaces/slashes
BUNDLE_ID="com.example.myapp"   # must match the bundle id the app reports at runtime
# ══════════════════════════════════════════════════════════════════════════════

# ── FILL IN: where this checkout's copy of the macos-e2e-kit lives ───────────────
# - Plugin install: "${CLAUDE_PLUGIN_ROOT}"
# - Vendored into this repo: a path relative to $here, e.g. "$here/../macos-e2e-kit"
KIT_ROOT="${CLAUDE_PLUGIN_ROOT:-<fill in kit checkout path>}"

# ── load the kit's harness invariant core (instance identity, socket derivation, the
# drive/wait/readiness helpers, and the generic up/down/status dispatch) ─────────────
if [ ! -f "$KIT_ROOT/templates/harness-lib.sh" ]; then
  echo "✗ KIT_ROOT ('$KIT_ROOT') has no templates/harness-lib.sh — fill in KIT_ROOT at the top of this file" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$KIT_ROOT/templates/harness-lib.sh"

# ── optional: free-port picking + kill-by-port helpers ───────────────────────────
# Only needed if backend_up() below stands up a network service (e.g. a dev server).
# Delete this whole section for a pure-client app with no backend.
hashnum="$(printf %s "$inst" | cksum | cut -d' ' -f1)"
PORT_BASE=$(( 4001 + hashnum % 900 ))   # per-instance default; override via $E2E_PORT

# Probe upward from <base> for a free TCP port; an explicit <override> is used as-is.
pick_free_port() {
  local base="$1" override="$2"
  [ -n "$override" ] && { printf %s "$override"; return; }
  local p="$base" n=0
  while [ -n "$(lsof -ti tcp:"$p" 2>/dev/null)" ]; do p=$((p+1)); n=$((n+1)); [ "$n" -ge 500 ] && break; done
  printf %s "$p"
}

# Kill only processes whose command name matches <pattern> listening on <port> —
# never an unrelated process that happens to be reusing the port.
kill_port_process() {
  local p="$1" pattern="$2" pid
  for pid in $(lsof -ti tcp:"$p" 2>/dev/null); do
    case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
      *"$pattern"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
}

save_ports() { printf 'E2E_PORT=%s\n' "${E2E_PORT:-}" >"$state/ports.env"; }
[ -f "$state/ports.env" ] && . "$state/ports.env"

# ══════════════════════════════════════════════════════════════════════════════
# ── FILL IN: build the app for E2E testing ────────────────────────────────────
# Exit non-zero (or `return 1`) on failure — up() stops and surfaces it.
# Example (SwiftPM executable):
#   ( cd "$here" && swift build -c debug ) || return 1
build_app() {
  echo "  ✗ build_app() is not implemented — edit this file (see comment above)" >&2
  return 1
}

# ── FILL IN (optional): bring up any backend/services this app depends on ─────
# Default is a no-op — leave as-is for a pure-client app with no backend.
backend_up() {
  return 0
}

# ── FILL IN (optional): tear down what backend_up() started ───────────────────
backend_down() {
  return 0
}

# ── FILL IN: launch the built app for E2E testing ─────────────────────────────
# MUST:
#   1. export E2E_INSTANCE="$inst" before launching, so the app's E2ESocketPath
#      derives the same suffixed socket dir this harness computed above.
#   2. background the process and write its PID to "$state/app.pid" (used by
#      already_up/down/status to check liveness and to kill only this instance).
# SHOULD (bundleless GUI apps): launch via labeled_launcher so the Dock tile + menu-bar name read
#   "<AppName> (<label>)" per instance instead of a bare, identical "<AppName>". Drop it for a .app
#   bundle (set a per-instance CFBundleName instead) or a headless binary with no visible name.
# NOTE: with E2E_INSTANCE exported, the app launches background-driven (the bridge switches it to
#   the .accessory activation policy — no Dock icon, no focus stolen from the user). Export
#   E2E_FOREGROUND=1 here to opt out and watch the app being driven in the foreground.
# Example:
#   bin="$(labeled_launcher "$here/.build/debug/MyApp")"
#   E2E_INSTANCE="$inst" nohup "$bin" >"$state/app.log" 2>&1 &
#   echo $! >"$state/app.pid"; disown 2>/dev/null || true
launch_app() {
  echo "  ✗ launch_app() is not implemented — edit this file (see comment above)" >&2
  return 1
}

# ── FILL IN (optional): extra readiness checks beyond debug.ping answering ────
# Default is a no-op (debug.ping alone is treated as ready).
app_ready_extra() {
  return 0
}
# ══════════════════════════════════════════════════════════════════════════════

harness_main "$@"
