#!/usr/bin/env bash
# Kit-owned harness invariant core. Sourced by an app's harness.sh (generated from
# harness.template.sh, or a hand-written one like examples/DemoApp/harness.sh) — never run
# directly. Provides multi-instance identity, socket-path derivation, the drive/wait/readiness
# helpers, and the generic up/down/status dispatch that calls the sourcing script's FILL-IN
# functions (build_app, backend_up, backend_down, launch_app, app_ready_extra).
#
# Contract: before sourcing this file, the sourcing script MUST set:
#   here       — absolute dir of the sourcing script (dirname of "${BASH_SOURCE[0]}")
#   APP_NAME   — state-dir slug (no spaces/slashes)
#   BUNDLE_ID  — must match the bundle id the app reports at runtime
#   KIT_ROOT   — this kit's checkout/plugin root (node driver at "$KIT_ROOT/node",
#                this file itself at "$KIT_ROOT/templates/harness-lib.sh")
#
# After sourcing, define build_app() and launch_app() (required), and optionally
# backend_up()/backend_down()/app_ready_extra() — bash resolves function bodies by name at call
# time, so a definition made after this source line but before `harness_main "$@"` overrides the
# no-op defaults declared below.
set -uo pipefail

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "✗ harness-lib.sh is a library — source it from your app's harness.sh, don't run it directly." >&2
  exit 1
fi

: "${here:?harness-lib.sh: 'here' must be set before sourcing (dir of the sourcing script)}"
: "${APP_NAME:?harness-lib.sh: APP_NAME must be set before sourcing}"
: "${BUNDLE_ID:?harness-lib.sh: BUNDLE_ID must be set before sourcing}"
: "${KIT_ROOT:?harness-lib.sh: KIT_ROOT must be set before sourcing}"

# ── default no-ops for optional FILL-IN functions — the sourcing script may override any of
# these by redefining the same name after sourcing this file ──
backend_up() { return 0; }
backend_down() { return 0; }
app_ready_extra() { return 0; }

# ── instance identity: same checkout → same stack; different checkout → different stack ──
repo_root="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)"
id_source="${repo_root:-$here}"   # falls back to this dir's path when not in a git repo
inst="${E2E_INSTANCE:-$(printf %s "$id_source" | shasum | cut -c1-6)}"

# ── display label: human-readable name the app surfaces in its window title / Dock / menu bar ──
# Separate concern from `inst`: `inst` is the socket/state identity (must stay path-unique and
# AF_UNIX-safe); `label` only names what you see, so parallel branch checkouts are distinguishable.
# Defaults to the current git branch; override with E2E_LABEL; falls back to `inst` outside a repo.
branch="$(git -C "$here" symbolic-ref --quiet --short HEAD 2>/dev/null)"
# Outer `-` (not `:-`): E2E_LABEL unset → branch (or `inst` outside a repo); E2E_LABEL="" set empty
# → empty label, an explicit opt-out to the plain, unlabeled app name. Inner `:-`: empty branch → inst.
label="${E2E_LABEL-${branch:-$inst}}"
export E2E_LABEL="$label"   # exported so launch_app's backgrounded child inherits it for its title

# ── state dir: pid/log/env files for THIS instance only ──────────────────────────
state="${TMPDIR:-/tmp}/e2e-${APP_NAME}/${inst}"; mkdir -p "$state"

# ── socket path: MUST match the app-side E2ESocketPath derivation ────────────────
# A non-empty instance appends ".<inst>"; an empty instance (E2E_INSTANCE="" explicitly) uses the
# bare bundle id with no suffix — same rule the Swift side applies to an empty E2E_INSTANCE.
if [ -n "$inst" ]; then
  sock="$HOME/Library/Application Support/${BUNDLE_ID}.${inst}/e2e.sock"
else
  sock="$HOME/Library/Application Support/${BUNDLE_ID}/e2e.sock"
fi
# AF_UNIX sun_path is capped at 104 bytes — a long E2E_INSTANCE/BUNDLE_ID would make
# bind() fail deep inside the app with an opaque error. Fail early here instead.
if [ "${#sock}" -ge 104 ]; then
  echo "✗ socket path is ${#sock} bytes, exceeds the 104-byte AF_UNIX sun_path limit: $sock" >&2
  echo "  shorten E2E_INSTANCE (currently '$inst') or BUNDLE_ID and retry." >&2
  exit 1
fi

# ── labeled launcher: give each instance a distinct Dock tile + menu-bar app name ─────
# A bundleless GUI app takes its Dock/menu name from the process name (argv[0] basename), so every
# instance launched from the same binary looks identical. Echo a per-label symlink to <binary> whose
# basename encodes the label — launch THAT and the process reads "<AppName> (<label>)" everywhere.
# Slashes/spaces in the label are flattened so it is a valid filename (the window title, set in-app
# from E2E_LABEL, keeps the literal label). An empty label echoes <binary> unchanged (no symlink).
labeled_launcher() {
  local bin="$1" safe
  [ -z "$label" ] && { printf %s "$bin"; return; }
  safe="$(printf %s "$label" | tr '/ ' '--')"
  local link="$state/$(basename "$bin") ($safe)"
  ln -sf "$bin" "$link" && printf %s "$link"
}

# ── drive helper: always talks to THIS instance's socket ─────────────────────────
drive() {
  if [ ! -f "$KIT_ROOT/node/drive.mjs" ]; then
    echo "✗ KIT_ROOT ('$KIT_ROOT') has no node/drive.mjs — fill in KIT_ROOT at the top of this file" >&2
    return 1
  fi
  SOCK="$sock" node "$KIT_ROOT/node/drive.mjs" "$@"
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
  echo "READY inst=$inst label=$label SOCK=$sock"
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
  # save_ports (from the template's optional free-port block) may not exist if that block was
  # deleted or was never present (e.g. a pure-client app) — call it only if defined.
  type -t save_ports >/dev/null 2>&1 && save_ports

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

# Dispatch entry point — call `harness_main "$@"` as the last line of the sourcing script, once
# all FILL-IN functions have been (re)defined.
harness_main() {
  case "${1:-}" in
    up) up "${2:-}" ;;
    down) down ;;
    status) status ;;
    *) echo "usage: harness.sh {up [--force]|down|status}" >&2; exit 1 ;;
  esac
}
