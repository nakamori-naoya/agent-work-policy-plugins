#!/usr/bin/env bash
# agent-work-policy の repository 検査。判定するのは、配置と manifest の一致、SKILL の name、
# LICENSE の写し、secret scanning の設定、shell の構文、symlink の有無だけである。
# SKILL の規律が十分かは、読んで評価する。
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# 保守toolの実装元は兄弟checkoutの harness-tools。無ければ止まる（fixtureで代用しない）。
TOOLS="$ROOT/../harness-tools/tools"
[ -d "$TOOLS" ] || { echo "[error] 兄弟 checkout harness-tools が無い: $TOOLS" >&2; exit 2; }
passed=0 failed=0
pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; failed=$((failed + 1)); }
skill_frontmatter_name() {
  awk 'NR==1 { if ($0 != "---") exit 2; next } $0=="---" { found=1; exit } { print } END { if (!found) exit 2 }' "$1" \
    | yq -er '.name | select(tag == "!!str" and length > 0)' -
}

PACKAGE="$ROOT/plugins/agent-work-policy"
ENTRY="$PACKAGE/skills/agent-work-policy"

python3 "$TOOLS/validate-plugin-repository.py" "$ROOT" && pass "package 構造（harness-tools）" || fail "package 構造（harness-tools）"

for market in .agents/plugins/marketplace.json .claude-plugin/marketplace.json; do
  [ "$(jq -r '[.plugins[].name] | join(",")' "$ROOT/$market")" = "agent-work-policy" ] \
    && pass "$market の公開 package は agent-work-policy だけ" || fail "$market の公開 package"
done

skill_files=$(find "$ROOT/plugins" -name SKILL.md -type f | sed "s#^$ROOT/##" | tr '\n' ' ')
[ "$skill_files" = "plugins/agent-work-policy/skills/agent-work-policy/SKILL.md " ] \
  && pass "SKILL.md は公開入口の1本だけ" || fail "SKILL.md の配置: $skill_files"
[ "$(skill_frontmatter_name "$ENTRY/SKILL.md")" = "agent-work-policy" ] \
  && pass "SKILL の name は agent-work-policy" || fail "SKILL の name"

bash "$ROOT/scripts/validate-plugin-license.sh" "$ROOT/LICENSE" "$PACKAGE/LICENSE" && pass "package の LICENSE" || fail "package の LICENSE"

syntax_failed=0
while IFS= read -r script; do bash -n "$script" || syntax_failed=1; done < <(find "$ROOT/scripts" "$ROOT/tests" -name '*.sh' -type f | sort)
[ "$syntax_failed" -eq 0 ] && pass "shell 構文" || fail "shell 構文"

# repositoryの回帰検査（harness-tools）: CI workflowのSHA固定、公開入口の一意性、doctorの読み取り専用性
python3 "$TOOLS/test-hardening.py" --repository "$ROOT" && pass "test-hardening --repository" || fail "test-hardening --repository"
bash "$ROOT/tests/license-contract.sh" && pass "LICENSE 契約" || fail "LICENSE 契約"
bash "$ROOT/tests/secret-scanning-contract.sh" && pass "secret scanning 契約" || fail "secret scanning 契約"

symlink_count=$(find "$ROOT/plugins" -type l | wc -l | tr -d ' ')
[ "$symlink_count" -eq 0 ] && pass "配布物に symlink なし" || fail "配布物に symlink がある"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
