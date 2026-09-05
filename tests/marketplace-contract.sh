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

mkdir -p "$TMP/repo/.agents/plugins" "$TMP/repo/.claude-plugin" "$TMP/repo/plugins/skills/automation"
cp -R "$ROOT/plugins/skills/automation/agent-work-policy" "$TMP/repo/plugins/skills/automation/agent-work-policy"
cp "$ROOT/.agents/plugins/marketplace.json" "$TMP/repo/.agents/plugins/marketplace.json"
cp "$ROOT/.claude-plugin/marketplace.json" "$TMP/repo/.claude-plugin/marketplace.json"
jq '.plugins[0].source.path = "./plugins/skills/automation/missing"' "$TMP/repo/.agents/plugins/marketplace.json" > "$TMP/missing-path.json"
jq '.plugins[0].source = "./plugins/skills/automation/missing"' "$TMP/repo/.claude-plugin/marketplace.json" > "$TMP/missing-path-claude.json"
cp "$TMP/missing-path.json" "$TMP/repo/.agents/plugins/missing-path.json"
cp "$TMP/missing-path-claude.json" "$TMP/repo/.claude-plugin/missing-path.json"
if bash "$CHECK" "$TMP/repo/.agents/plugins/missing-path.json" "$TMP/repo/.claude-plugin/missing-path.json" >/dev/null 2>&1; then echo '  NG: missing skill plugin path was accepted' >&2; FAIL=1; else echo '  ok: missing skill plugin path is rejected'; fi

rm "$TMP/repo/plugins/skills/automation/agent-work-policy/skills/work-with-policy/SKILL.md"
if bash "$CHECK" "$TMP/repo/.agents/plugins/marketplace.json" "$TMP/repo/.claude-plugin/marketplace.json" >/dev/null 2>&1; then echo '  NG: plugin without root SKILL.md was accepted' >&2; FAIL=1; else echo '  ok: plugin without root SKILL.md is rejected'; fi

cp "$ROOT/plugins/skills/automation/agent-work-policy/skills/work-with-policy/SKILL.md" "$TMP/repo/plugins/skills/automation/agent-work-policy/skills/work-with-policy/SKILL.md"
jq 'del(.interface.capabilities)' "$TMP/repo/plugins/skills/automation/agent-work-policy/.codex-plugin/plugin.json" > "$TMP/no-capabilities.json"
mv "$TMP/no-capabilities.json" "$TMP/repo/plugins/skills/automation/agent-work-policy/.codex-plugin/plugin.json"
if bash "$CHECK" "$TMP/repo/.agents/plugins/marketplace.json" "$TMP/repo/.claude-plugin/marketplace.json" >/dev/null 2>&1; then echo '  NG: plugin without Skills capability was accepted' >&2; FAIL=1; else echo '  ok: plugin without Skills capability is rejected'; fi

mkdir -p "$TMP/symlink-repo/.agents/plugins" "$TMP/symlink-repo/.claude-plugin" "$TMP/symlink-repo/plugins"
ln -s "$ROOT/plugins/skills" "$TMP/symlink-repo/plugins/skills"
cp "$ROOT/.agents/plugins/marketplace.json" "$TMP/symlink-repo/.agents/plugins/marketplace.json"
cp "$ROOT/.claude-plugin/marketplace.json" "$TMP/symlink-repo/.claude-plugin/marketplace.json"
if bash "$CHECK" "$TMP/symlink-repo/.agents/plugins/marketplace.json" "$TMP/symlink-repo/.claude-plugin/marketplace.json" >/dev/null 2>&1; then echo '  NG: intermediate source symlink was accepted' >&2; FAIL=1; else echo '  ok: intermediate source symlink is rejected'; fi

exit "$FAIL"
