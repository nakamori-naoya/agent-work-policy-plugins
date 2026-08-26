#!/usr/bin/env bash
# Scenario: repositoryのplugin集合、manifest、marketplace、構文が一致する
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/plugin-repository-validation.XXXXXX") || exit 2
trap 'rm -rf "$TMP_ROOT"' EXIT
failed=0
jq -r '.plugins[].name' "$ROOT/vendor-lock.json" | sort > "$TMP_ROOT/expected"
find "$ROOT/plugins" -path '*/.codex-plugin/plugin.json' -type f -exec jq -r '.name' {} \; | sort > "$TMP_ROOT/actual"
diff -u "$TMP_ROOT/expected" "$TMP_ROOT/actual" >/dev/null || failed=1
for market in .agents/plugins/marketplace.json .claude-plugin/marketplace.json; do
  jq -r '.plugins[].name' "$ROOT/$market" | sort > "$TMP_ROOT/market"
  diff -u "$TMP_ROOT/expected" "$TMP_ROOT/market" >/dev/null || failed=1
done
while IFS='|' read -r name version rel; do
  jq -e --arg n "$name" --arg v "$version" '.name==$n and .version==$v' "$ROOT/$rel/.codex-plugin/plugin.json" "$ROOT/$rel/.claude-plugin/plugin.json" >/dev/null || failed=1
done < <(jq -r '.plugins[] | [.name,.version,.path] | join("|")' "$ROOT/vendor-lock.json")
while IFS= read -r pb; do
  yq -o=json -I=0 '.' "$pb" | jq -e '.version==2 and all(.requires[]; type=="object" and ((keys|sort)==["marketplace","plugin","version"]))' >/dev/null || failed=1
  root=$(dirname "$pb")
  cmp -s "$ROOT/shared/playbook/resolve.sh" "$root/scripts/resolve.sh" || failed=1
  cmp -s "$ROOT/shared/playbook/resolve-dependency.py" "$root/scripts/resolve-dependency.py" || failed=1
done < <(find "$ROOT/plugins/playbooks" -name playbook.yml -type f 2>/dev/null | sort)
while IFS= read -r script; do bash -n "$script" || failed=1; done < <(find "$ROOT" -type f -name '*.sh' | sort)
while IFS= read -r script; do PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$script" || failed=1; done < <(find "$ROOT" -type f -name '*.py' | sort)
if [ "$failed" -eq 0 ]; then echo 'Validation: passed'; else echo 'Validation: failed'; fi
[ "$failed" -eq 0 ]
