#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/license-contract.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
CHECK="$ROOT/scripts/validate-plugin-license.sh"
PLUGIN_LICENSE="$ROOT/plugins/skills/automation/agent-work-policy/LICENSE"
FAIL=0

if bash "$CHECK" "$ROOT/LICENSE" "$PLUGIN_LICENSE"; then
  echo '  ok: plugin LICENSE is a regular copy of root LICENSE'
else
  echo '  NG: valid plugin LICENSE was rejected' >&2
  FAIL=1
fi

printf '%s\n' 'different license' > "$TMP/mismatch"
if bash "$CHECK" "$ROOT/LICENSE" "$TMP/mismatch"; then
  echo '  NG: mismatched plugin LICENSE was accepted' >&2
  FAIL=1
else
  echo '  ok: mismatched plugin LICENSE is rejected'
fi

ln -s "$ROOT/LICENSE" "$TMP/symlink"
if bash "$CHECK" "$ROOT/LICENSE" "$TMP/symlink"; then
  echo '  NG: symlink plugin LICENSE was accepted' >&2
  FAIL=1
else
  echo '  ok: symlink plugin LICENSE is rejected'
fi

ln -s "$ROOT/LICENSE" "$TMP/root-symlink"
if bash "$CHECK" "$TMP/root-symlink" "$PLUGIN_LICENSE"; then
  echo '  NG: symlink root LICENSE was accepted' >&2
  FAIL=1
else
  echo '  ok: symlink root LICENSE is rejected'
fi

exit "$FAIL"
