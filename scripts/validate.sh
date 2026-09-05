#!/usr/bin/env bash
# Scenario: repositoryのplugin集合、manifest、marketplace、構文が一致する
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$ROOT/scripts/test-hardening.py" || exit 1
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/plugin-repository-validation.XXXXXX") || exit 2
export TMPDIR="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
failed=0
jq -r '.plugins[].name' "$ROOT/.agents/plugins/marketplace.json" | sort > "$TMP_ROOT/expected"
find "$ROOT/plugins" -path '*/.codex-plugin/plugin.json' -type f -exec jq -r '.name' {} \; | sort > "$TMP_ROOT/actual"
diff -u "$TMP_ROOT/expected" "$TMP_ROOT/actual" >/dev/null || failed=1
for market in .agents/plugins/marketplace.json .claude-plugin/marketplace.json; do
  jq -r '.plugins[].name' "$ROOT/$market" | sort > "$TMP_ROOT/market"
  diff -u "$TMP_ROOT/expected" "$TMP_ROOT/market" >/dev/null || failed=1
done
bash "$ROOT/scripts/validate-marketplaces.sh" "$ROOT/.agents/plugins/marketplace.json" "$ROOT/.claude-plugin/marketplace.json" || failed=1
while IFS='|' read -r name version rel; do
  jq -e --arg n "$name" --arg v "$version" '.name==$n and .version==$v' "$ROOT/$rel/.codex-plugin/plugin.json" "$ROOT/$rel/.claude-plugin/plugin.json" >/dev/null || failed=1
  bash "$ROOT/scripts/validate-plugin-license.sh" "$ROOT/LICENSE" "$ROOT/$rel/LICENSE" || failed=1
done < <(jq -r '.plugins[] | [.name,.version,(.source.path | ltrimstr("./"))] | join("|")' "$ROOT/.agents/plugins/marketplace.json")
while IFS= read -r pb; do
  yq -o=json -I=0 '.' "$pb" | jq -e '.version==2 and all(.requires[]; type=="object" and ((keys|sort)==["marketplace","plugin","version"]))' >/dev/null || failed=1
  root=$(dirname "$pb")
  cmp -s "$ROOT/shared/playbook/resolve.sh" "$root/scripts/resolve.sh" || failed=1
  cmp -s "$ROOT/shared/playbook/resolve-dependency.py" "$root/scripts/resolve-dependency.py" || failed=1
done < <(find "$ROOT/plugins/playbooks" -name playbook.yml -type f 2>/dev/null | sort)
cmp -s "$ROOT/shared/prepare.sh" "$ROOT/plugins/skills/automation/agent-work-policy/scripts/prepare.sh" || failed=1
cmp -s "$ROOT/shared/skill/resolve.sh" "$ROOT/plugins/skills/automation/agent-work-policy/scripts/resolve.sh" || failed=1
while IFS= read -r script; do bash -n "$script" || failed=1; done < <(find "$ROOT" -type f -name '*.sh' | sort)
while IFS= read -r script; do PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$script" || failed=1; done < <(find "$ROOT" -type f -name '*.py' | sort)
bash "$ROOT/tests/publication-authority-contract.sh" || failed=1
bash "$ROOT/tests/marketplace-contract.sh" || failed=1
bash "$ROOT/tests/license-contract.sh" || failed=1
bash "$ROOT/tests/secret-scanning-contract.sh" || failed=1
if [ "$failed" -eq 0 ]; then echo 'Validation: passed'; else echo 'Validation: failed'; fi
[ "$failed" -eq 0 ]
