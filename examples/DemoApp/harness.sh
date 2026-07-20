#!/usr/bin/env bash
# E2E harness for examples/DemoApp — the kit's self-verification target.
#
# Implements the harness.template.sh contract with no backend (pure-client app):
#   harness.sh up [--force] [--open]
#                             # idempotent build+launch; last stdout line is
#                             #   "READY inst=<inst> SOCK=<absolute socket path>"
#                             # --open (or E2E_FOREGROUND=1) brings the app — running or freshly
#                             # launched — to the foreground (reverses background-driven mode)
#   harness.sh down           # tear down ONLY this instance (PID-scoped, no broad pkill)
#   harness.sh status         # exit 0 if healthy, non-zero otherwise; shows the built binary path
#
# Multi-session: each checkout gets its own instance token `inst`, so parallel `up`s don't collide.
# Override the token with E2E_INSTANCE=name. Teardown only ever touches this instance's recorded PID.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── app identity (must match Sources/DemoApp/main.swift's demoBundleID) ──
APP_NAME="demoapp"
BUNDLE_ID="dev.macos-e2e-kit.demo"

# This example lives two levels under the kit root (examples/DemoApp → repo root).
KIT_ROOT="$(cd "$here/../.." && pwd)"

# ── load the kit's harness invariant core (instance identity, socket derivation, the
# drive/wait/readiness helpers, and the generic up/down/status dispatch) ─────────────
# shellcheck source=/dev/null
source "$KIT_ROOT/templates/harness-lib.sh"

# Build the DemoApp SwiftPM executable (build log to the state dir).
build_app() {
  ( cd "$here" && swift build ) >"$state/build.log" 2>&1 || return 1
}

# Launch the built executable with E2E_INSTANCE exported so the app's E2ESocketPath derives the same
# suffixed socket dir this harness computed. labeled_launcher wraps the binary in a per-label symlink
# so the Dock tile + menu-bar name read "DemoApp (<label>)" instead of a bare "DemoApp" for every
# instance. Background it and record the PID for PID-scoped teardown.
launch_app() {
  local bin; bin="$(labeled_launcher "$here/.build/debug/DemoApp")"
  E2E_INSTANCE="$inst" nohup "$bin" >"$state/app.log" 2>&1 &
  echo $! >"$state/app.pid"
  disown 2>/dev/null || true
}

harness_main "$@"
