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
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════════
# ── FILL IN: your app's identity ──────────────────────────────────────────────
APP_NAME="myapp"                # slug for state-dir naming — no spaces/slashes
BUNDLE_ID="com.example.myapp"   # must match the bundle id the app reports at runtime
# ══════════════════════════════════════════════════════════════════════════════

# ── FILL IN: where this checkout's copy of the macos-e2e-kit "node/" dir lives ──
# - Plugin install: "${CLAUDE_PLUGIN_ROOT}/node"
# - Vendored into this repo: a path relative to $here, e.g. "$here/../macos-e2e-kit/node"
KIT_NODE_DIR="${CLAUDE_PLUGIN_ROOT:-}/node"

# ── instance identity: same checkout → same stack; different checkout → different stack ──
repo_root="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)"
id_source="${repo_root:-$here}"   # falls back to this dir's path when not in a git repo
inst="${E2E_INSTANCE:-$(printf %s "$id_source" | shasum | cut -c1-6)}"

# ── state dir: pid/log/env files for THIS instance only ──────────────────────────
state="${TMPDIR:-/tmp}/e2e-${APP_NAME}/${inst}"; mkdir -p "$state"

# ── socket path: MUST match the app-side E2ESocketPath derivation ────────────────
# <bundleID>.<inst> keeps this instance's socket isolated from peers' and from a
# normal (non-E2E) run of the app, which uses the bare bundle id with no suffix.
sock="$HOME/Library/Application Support/${BUNDLE_ID}.${inst}/e2e.sock"
# AF_UNIX sun_path is capped at 104 bytes — a long E2E_INSTANCE/BUNDLE_ID would make
# bind() fail deep inside the app with an opaque error. Fail early here instead.
if [ "${#sock}" -ge 104 ]; then
  echo "✗ socket path is ${#sock} bytes, exceeds the 104-byte AF_UNIX sun_path limit: $sock" >&2
  echo "  shorten E2E_INSTANCE (currently '$inst') or BUNDLE_ID and retry." >&2
  exit 1
fi

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

# ── drive helper: always talks to THIS instance's socket ─────────────────────────
drive() {
  if [ ! -f "$KIT_NODE_DIR/drive.mjs" ]; then
    echo "✗ KIT_NODE_DIR ('$KIT_NODE_DIR') has no drive.mjs — fill in KIT_NODE_DIR at the top of this file" >&2
    return 1
  fi
  SOCK="$sock" node "$KIT_NODE_DIR/drive.mjs" "$@"
}

# Poll debug.ping (via the drive CLI) until the app answers, or give up after <tries>.
wait_for_ping() {
  local tries="${1:-30}" n=0
  while [ "$n" -lt "$tries" ]; do
    drive ping >/dev/null 2>&1 && return 0
    n=$((n+1)); sleep 1
  done
  return 1
}

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
# Example:
#   E2E_INSTANCE="$inst" nohup "$here/.build/debug/MyApp" >"$state/app.log" 2>&1 &
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

# true iff THIS instance's app is already running and answering debug.ping —
# lets `up` skip a rebuild+relaunch when called again with nothing to change.
already_up() {
  local apid; apid="$([ -f "$state/app.pid" ] && cat "$state/app.pid" 2>/dev/null)"
  [ -n "$apid" ] && kill -0 "$apid" 2>/dev/null || return 1
  drive ping >/dev/null 2>&1 || return 1
  return 0
}

# The one machine-parseable line every successful `up` must end with.
print_ready() {
  echo "READY inst=$inst SOCK=$sock"
}

up() {
  if [ "${1:-}" != "--force" ] && already_up; then
    echo "✓ already up [inst=$inst] — app alive + debug.ping ok, skipping rebuild."
    echo "  (run 'harness.sh up --force' to rebuild, or 'harness.sh down' first)"
    print_ready
    return 0
  fi

  echo "▶ build [inst=$inst]…"
  build_app || { echo "  ✗ build_app failed"; exit 1; }
  echo "  ✓ built"

  echo "▶ backend_up (optional)…"
  backend_up || { echo "  ✗ backend_up failed"; exit 1; }
  save_ports

  echo "▶ launch app [inst=$inst] (E2E_INSTANCE=$inst)…"
  [ -f "$state/app.pid" ] && kill "$(cat "$state/app.pid")" 2>/dev/null || true
  rm -f "$sock"
  launch_app || { echo "  ✗ launch_app failed"; exit 1; }
  [ -f "$state/app.pid" ] || { echo "  ✗ launch_app() did not record \$state/app.pid"; exit 1; }

  echo "▶ waiting for readiness…"
  wait_for_ping 30 || { echo "  ✗ app did not answer debug.ping — see $state/app.log"; exit 1; }
  app_ready_extra || { echo "  ✗ app_ready_extra failed"; exit 1; }
  echo "  ✓ ready"

  print_ready
}

down() {
  echo "▶ teardown [inst=$inst]…"
  # PID-scoped ONLY — no broad pkill, so peer instances' apps are never touched.
  [ -f "$state/app.pid" ] && kill "$(cat "$state/app.pid")" 2>/dev/null || true
  backend_down
  rm -f "$state"/*.pid
  rm -f "$sock"
  rmdir "$(dirname "$sock")" 2>/dev/null || true   # only removes if now-empty
  echo "  ✓ removed [inst=$inst] (other instances untouched)"
}

status() {
  local apid ok=0
  apid="$([ -f "$state/app.pid" ] && cat "$state/app.pid" 2>/dev/null)"
  echo "inst:   $inst   (state $state)"
  echo "sock:   $sock"
  if [ -n "$apid" ] && kill -0 "$apid" 2>/dev/null; then
    echo "app:    running (pid $apid)"
  else
    echo "app:    stopped"; ok=1
  fi
  if drive ping >/dev/null 2>&1; then
    echo "ping:   ok"
  else
    echo "ping:   fail"; ok=1
  fi
  echo "socket: $([ -S "$sock" ] && echo present || echo missing)"
  return $ok
}

case "${1:-}" in
  up) up "${2:-}" ;;
  down) down ;;
  status) status ;;
  *) echo "usage: harness.sh {up [--force]|down|status}" >&2; exit 1 ;;
esac
