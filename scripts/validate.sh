#!/usr/bin/env bash
# git-work-policy の repository 検査。配置と manifest は harness-tools の validate-plugin-repository.py が判定する。
# ここで足すのは、LICENSE の写し、secret scanning の設定、shell の構文である。
# SKILL の規律が十分かは、読んで評価する。
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# 保守toolの実装元は兄弟checkoutの harness-tools。無ければ止まる（fixtureで代用しない）。
TOOLS="$ROOT/../harness-tools/tools"
[ -d "$TOOLS" ] || { echo "[error] 兄弟 checkout harness-tools が無い: $TOOLS" >&2; exit 2; }
passed=0 failed=0
pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; failed=$((failed + 1)); }

PACKAGE="$ROOT/plugins/git-work-policy"

python3 "$TOOLS/validate-plugin-repository.py" "$ROOT" && pass "package 構造（harness-tools）" || fail "package 構造（harness-tools）"

bash "$ROOT/scripts/validate-plugin-license.sh" "$ROOT/LICENSE" "$PACKAGE/LICENSE" && pass "package の LICENSE" || fail "package の LICENSE"

syntax_failed=0
while IFS= read -r script; do bash -n "$script" || syntax_failed=1; done < <(find "$ROOT/scripts" "$ROOT/tests" -name '*.sh' -type f | sort)
[ "$syntax_failed" -eq 0 ] && pass "shell 構文" || fail "shell 構文"

# repositoryの回帰検査（harness-tools）: CI workflowのSHA固定
python3 "$TOOLS/test-hardening.py" --repository "$ROOT" && pass "test-hardening --repository" || fail "test-hardening --repository"
bash "$ROOT/tests/license-contract.sh" && pass "LICENSE 契約" || fail "LICENSE 契約"
bash "$ROOT/tests/secret-scanning-contract.sh" && pass "secret scanning 契約" || fail "secret scanning 契約"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
