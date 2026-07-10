#!/usr/bin/env bash
# E2E harness for examples/DemoApp — the kit's self-verification target.
#
# Implements the harness.template.sh contract with no backend (pure-client app):
#   harness.sh up [--force]   # idempotent build+launch; last stdout line is
#                              #   "READY inst=<inst> SOCK=<absolute socket path>"
#   harness.sh down           # tear down ONLY this instance (PID-scoped, no broad pkill)
#   harness.sh status         # exit 0 if healthy, non-zero otherwise
#
# Multi-session: each checkout gets its own instance token `inst`, so parallel `up`s don't collide.
# Override the token with E2E_INSTANCE=name. Teardown only ever touches this instance's recorded PID.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── app identity (must match Sources/DemoApp/main.swift's demoBundleID) ──
APP_NAME="demoapp"
BUNDLE_ID="dev.macos-e2e-kit.demo"

# This example vendors the kit's node/ dir two levels up (examples/DemoApp → repo root).
KIT_NODE_DIR="$here/../../node"

# ── instance identity: same checkout → same stack; different checkout → different stack ──
repo_root="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)"
id_source="${repo_root:-$here}"   # falls back to this dir's path when not in a git repo
inst="${E2E_INSTANCE:-$(printf %s "$id_source" | shasum | cut -c1-6)}"

# ── state dir: pid/log files for THIS instance only ──
state="${TMPDIR:-/tmp}/e2e-${APP_NAME}/${inst}"; mkdir -p "$state"

# ── socket path: MUST mirror E2ESocketPath.default() exactly ──
# A non-empty instance appends ".<inst>"; an empty instance uses the bare bundle id (no suffix) —
# same rule the Swift side applies to an empty E2E_INSTANCE.
if [ -n "$inst" ]; then
  sock="$HOME/Library/Application Support/${BUNDLE_ID}.${inst}/e2e.sock"
else
  sock="$HOME/Library/Application Support/${BUNDLE_ID}/e2e.sock"
fi
# AF_UNIX sun_path is capped at 104 bytes — fail early with a clear message instead of letting the
# app's bind() fail deep inside with an opaque error.
if [ "${#sock}" -ge 104 ]; then
  echo "✗ socket path is ${#sock} bytes, exceeds the 104-byte AF_UNIX sun_path limit: $sock" >&2
  echo "  shorten E2E_INSTANCE (currently '$inst') or BUNDLE_ID and retry." >&2
  exit 1
fi

# ── drive helper: always talks to THIS instance's socket ──
drive() {
  if [ ! -f "$KIT_NODE_DIR/drive.mjs" ]; then
    echo "✗ KIT_NODE_DIR ('$KIT_NODE_DIR') has no drive.mjs" >&2
    return 1
  fi
  SOCK="$sock" node "$KIT_NODE_DIR/drive.mjs" "$@"
}

# Poll debug.ping (via the drive CLI) until the app answers, or give up after <tries> seconds.
wait_for_ping() {
  local tries="${1:-30}" n=0
  while [ "$n" -lt "$tries" ]; do
    drive ping >/dev/null 2>&1 && return 0
    n=$((n+1)); sleep 1
  done
  return 1
}

# Build the DemoApp SwiftPM executable (build log to the state dir).
build_app() {
  ( cd "$here" && swift build ) >"$state/build.log" 2>&1 || return 1
}

# Launch the built executable with E2E_INSTANCE exported so the app's E2ESocketPath derives the same
# suffixed socket dir this harness computed. Background it and record the PID for PID-scoped teardown.
launch_app() {
  E2E_INSTANCE="$inst" nohup "$here/.build/debug/DemoApp" >"$state/app.log" 2>&1 &
  echo $! >"$state/app.pid"
  disown 2>/dev/null || true
}

# true iff THIS instance's app is already running and answering debug.ping — lets `up` skip a
# rebuild+relaunch when called again with nothing to change.
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
  build_app || { echo "  ✗ build failed — see $state/build.log"; exit 1; }
  echo "  ✓ built"

  echo "▶ launch app [inst=$inst] (E2E_INSTANCE=$inst)…"
  [ -f "$state/app.pid" ] && kill "$(cat "$state/app.pid")" 2>/dev/null || true
  rm -f "$sock"
  launch_app
  [ -f "$state/app.pid" ] || { echo "  ✗ launch_app did not record \$state/app.pid"; exit 1; }

  echo "▶ waiting for readiness…"
  wait_for_ping 30 || { echo "  ✗ app did not answer debug.ping — see $state/app.log"; exit 1; }
  echo "  ✓ ready"

  print_ready
}

down() {
  echo "▶ teardown [inst=$inst]…"
  # PID-scoped ONLY — no broad pkill, so peer instances' apps are never touched.
  [ -f "$state/app.pid" ] && kill "$(cat "$state/app.pid")" 2>/dev/null || true
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
