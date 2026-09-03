#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/marketplace-contract.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
CHECK="$ROOT/scripts/validate-marketplaces.sh"
FAIL=0

if bash "$CHECK" "$ROOT/.agents/plugins/marketplace.json" "$ROOT/.claude-plugin/marketplace.json"; then
  echo '  ok: marketplaces agree on name, version, and source'
else
  echo '  NG: valid marketplaces were rejected' >&2
  FAIL=1
fi

cp "$ROOT/.claude-plugin/marketplace.json" "$TMP/claude.json"
jq '.plugins[0].version = "9.9.9"' "$TMP/claude.json" > "$TMP/version.json"
if bash "$CHECK" "$ROOT/.agents/plugins/marketplace.json" "$TMP/version.json" >/dev/null 2>&1; then
  echo '  NG: Claude marketplace version mismatch was accepted' >&2
  FAIL=1
else
  echo '  ok: Claude marketplace version mismatch is rejected'
fi

jq '.plugins[0].source = "./plugins/evil"' "$TMP/claude.json" > "$TMP/source.json"
if bash "$CHECK" "$ROOT/.agents/plugins/marketplace.json" "$TMP/source.json" >/dev/null 2>&1; then
  echo '  NG: Claude marketplace source mismatch was accepted' >&2
  FAIL=1
else
  echo '  ok: Claude marketplace source mismatch is rejected'
fi

exit "$FAIL"
