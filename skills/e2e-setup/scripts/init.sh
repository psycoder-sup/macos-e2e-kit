#!/usr/bin/env bash
# One-time onboarding scaffold for a consumer app repo: copies this kit's harness template and a
# starter test into the target repo, without ever overwriting a file that's already there.
#
# Usage: init.sh [target-dir]   (default: current directory)
set -uo pipefail

target="${1:-.}"

# Resolve this plugin's root regardless of how the script is invoked: as an installed plugin
# (Claude Code sets $CLAUDE_PLUGIN_ROOT) or run directly from a checkout — fall back to a path
# computed from this script's own location (scripts/ -> e2e-setup/ -> skills/ -> plugin root),
# so it works both installed and from a checkout.
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

if [ ! -d "$plugin_root/templates" ]; then
  echo "✗ no templates/ directory under plugin root ($plugin_root)." >&2
  echo "  set CLAUDE_PLUGIN_ROOT, or run this script from inside a macos-e2e-kit checkout/install." >&2
  exit 1
fi

target_abs="$(cd "$target" 2>/dev/null && pwd)" || {
  echo "✗ target dir '$target' does not exist." >&2
  exit 1
}

# Safety: this scaffolds into a real app repo, not a scratch directory — refuse anywhere that
# isn't inside a git work tree.
if ! git -C "$target_abs" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "✗ '$target_abs' is not inside a git work tree — refusing to scaffold." >&2
  echo "  run 'git init' first if this is intentionally a new repo, then re-run." >&2
  exit 1
fi

# Copy <src> to <dest> unless <dest> already exists (never overwrite a user's file).
copy_if_absent() {
  local src="$1" dest="$2"
  if [ -e "$dest" ]; then
    echo "· skip (already exists): $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "✓ wrote: $dest"
}

mkdir -p "$target_abs/e2e" "$target_abs/tests/e2e"

copy_if_absent "$plugin_root/templates/harness.template.sh" "$target_abs/e2e/harness.sh"
chmod +x "$target_abs/e2e/harness.sh"

copy_if_absent "$plugin_root/templates/example.e2e.mjs" "$target_abs/tests/e2e/smoke.e2e.mjs"

cat <<EOF

Next steps:
  1. Edit $target_abs/e2e/harness.sh — set APP_NAME, BUNDLE_ID, KIT_NODE_DIR, and fill in
     build_app, backend_up/backend_down (optional), launch_app, and app_ready_extra (optional).
  2. Edit $target_abs/tests/e2e/smoke.e2e.mjs with a real assertion once the app is wired up.
  3. Verify: $target_abs/e2e/harness.sh up
     — look for the last line: "READY inst=<inst> SOCK=<absolute socket path>"
  4. Drive it: SOCK=<that path> node ${plugin_root}/node/drive.mjs ping
EOF
