#!/usr/bin/env bash
# 共通resolverが知らない agent-work-policy 固有のキーを検査する。
set -euo pipefail
file="$1"
jq -e '.contract.contract_id == "agent-work-policy/agent-work-policy" and .contract.contract_version == 1' "$file" >/dev/null \
  || { echo "[error] 契約IDと契約版はagent-work-policy/agent-work-policyのv1に固定する" >&2; exit 2; }
jq -e '.contract.actions | type=="array" and length>0 and all(.[]; type=="string" and test("^[a-z0-9]+(-[a-z0-9]+)*$"))' "$file" >/dev/null \
  || { echo "[error] contract.actionsは非空のkebab-case文字列配列にする" >&2; exit 2; }
jq -e '.contract.gate_states == ["allowed","waiting_for_human","denied"]' "$file" >/dev/null \
  || { echo "[error] gate状態はallowed / waiting_for_human / deniedに固定する" >&2; exit 2; }
jq -e '.contract.statuses == ["completed","waiting_for_human","failed"]' "$file" >/dev/null \
  || { echo "[error] 公開statusはcompleted / waiting_for_human / failedに固定する" >&2; exit 2; }
jq -e '(.steps|length) == 1 and .steps[0].skill == "apply-work-policy"' "$file" >/dev/null \
  || { echo "[error] 1呼び出し1action。工程はapply-work-policyの1件だけにする" >&2; exit 2; }
jq -e '.steps | all(.[]; .completion == "artifact-set" and .on_failure == "stop")' "$file" >/dev/null \
  || { echo "[error] 全工程はcompletion=artifact-set、on_failure=stopが必要" >&2; exit 2; }
jq -e '[.steps[0].provides[]] | index("action_result") != null and index("gate_state") != null and index("workspace") != null' "$file" >/dev/null \
  || { echo "[error] 公開出力に必要なaction_result / gate_state / workspaceをprovidesしていない" >&2; exit 2; }
