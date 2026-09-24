#!/usr/bin/env bash
# Scenario: agent-work-policy marketplaceがpackage 1件・公開入口1件で自己完結し、公開契約どおりに動く
# 機械検査は宣言と実体の対応、公開入口の入出力schema、操作前停止だけを判定する。
# policyの妥当性、承認対象の十分性、SKILL本文の判断基準の十分性は意味評価として残す。
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# 保守toolの実装元は兄弟checkoutの harness-tools。無ければ止まる（fixtureで代用しない）。
TOOLS="$ROOT/../harness-tools/tools"
[ -d "$TOOLS" ] || { echo "[error] 兄弟 checkout harness-tools が無い: $TOOLS" >&2; exit 2; }
# **一時領域を正規形へ直さない。** macOS 既定の TMPDIR は /var/folders/... という
# symlink 越しの path であり、契約入口はそれをそのまま受けなければならない（realpath正規化）。
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-work-policy-validation.XXXXXX") || exit 2
export TMPDIR="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
passed=0 failed=0
pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; failed=$((failed + 1)); }
skill_frontmatter_name() {
  awk 'NR==1 { if ($0 != "---") exit 2; next } $0=="---" { found=1; exit } { print } END { if (!found) exit 2 }' "$1" \
    | yq -er '.name | select(tag == "!!str" and length > 0)' -
}

PACKAGE="$ROOT/plugins/agent-work-policy"
ENTRY="$PACKAGE/skills/agent-work-policy"
POLICY_EXAMPLE="$ENTRY/assets/policy.example.yml"

# ── 1. 公開インストール対象はpackage 1件、公開入口は skills/agent-work-policy 1件 ──────
jq -r '.plugins[].name' "$ROOT/.agents/plugins/marketplace.json" | sort > "$TMP_ROOT/expected"
jq -r '.name' "$PACKAGE/.codex-plugin/plugin.json" | sort > "$TMP_ROOT/actual"
diff -u "$TMP_ROOT/expected" "$TMP_ROOT/actual" >/dev/null && pass "公開インストール対象はagent-work-policy packageだけ" || fail "plugin集合"
for market in .agents/plugins/marketplace.json .claude-plugin/marketplace.json; do
  jq -r '.plugins[].name' "$ROOT/$market" | sort > "$TMP_ROOT/market"
  diff -u "$TMP_ROOT/expected" "$TMP_ROOT/market" >/dev/null && pass "$market plugin集合" || fail "$market plugin集合"
done
if jq -e '.plugins[0].source=="./plugins/agent-work-policy"' "$ROOT/.claude-plugin/marketplace.json" >/dev/null \
  && jq -e '.plugins[0].source=={"source":"local","path":"./plugins/agent-work-policy"}' "$ROOT/.agents/plugins/marketplace.json" >/dev/null; then
  pass "marketplace sourceは./plugins/agent-work-policy"
else
  fail "marketplace source"
fi
while IFS='|' read -r name version rel; do
  if jq -e --arg n "$name" --arg v "$version" '.name==$n and .version==$v' "$ROOT/$rel/.codex-plugin/plugin.json" >/dev/null \
    && jq -e --arg n "$name" --arg v "$version" '.name==$n and .version==$v' "$ROOT/$rel/.claude-plugin/plugin.json" >/dev/null; then
    pass "$name manifest identity"
  else
    fail "$name manifest identity"
  fi
  bash "$ROOT/scripts/validate-plugin-license.sh" "$ROOT/LICENSE" "$ROOT/$rel/LICENSE" && pass "$name LICENSE" || fail "$name LICENSE"
done < <(jq -r '.plugins[] | [.name,.version,(.source.path | ltrimstr("./"))] | join("|")' "$ROOT/.agents/plugins/marketplace.json")

manifest_dirs=$(find "$ROOT/plugins" -type d \( -name '.claude-plugin' -o -name '.codex-plugin' \) | sed "s#^$ROOT/##" | sort | tr '\n' ' ')
[ "$manifest_dirs" = "plugins/agent-work-policy/.claude-plugin plugins/agent-work-policy/.codex-plugin " ] \
  && pass "runtime manifest directoryはpackage rootの2つだけ" || fail "runtime manifest directoryが余分または欠落: $manifest_dirs"
skill_files=$(find "$ROOT/plugins" -name SKILL.md -type f | sed "s#^$ROOT/##" | tr '\n' ' ')
[ "$skill_files" = "plugins/agent-work-policy/skills/agent-work-policy/SKILL.md " ] \
  && pass "SKILL.mdは公開入口の1本だけ（内部skillなし）" || fail "SKILL.mdの配置: $skill_files"

# ── 2. manifestが公開契約を自己宣言している ─────────────────────────────
manifest_ok=1
for runtime in claude codex; do
  jq -e '
    .skills==["./skills/agent-work-policy"]
    and (.metadata.harness as $h
    | $h.marketplace=="agent-work-policy"
      and $h.contractVersion==1
      and ($h|has("installationSurface")|not) and ($h|has("entryRoot")|not) and ($h|has("internalPlugins")|not)
      and $h.playbooks=={"agent-work-policy":"./skills/agent-work-policy"}
      and ($h.implements|type=="array" and length==1)
      and ($h.implements[0]
           | .id=="agent-work-policy/agent-work-policy" and .version==1 and .kind=="playbook"
             and .playbook=="agent-work-policy"
             and (.actions|type=="array" and length>0
                  and all(.[]; type=="string" and test("^[a-z0-9]+(-[a-z0-9]+)*$")))
             and ((keys|sort)==["actions","id","kind","playbook","version"])))
  ' "$PACKAGE/.$runtime-plugin/plugin.json" >/dev/null || manifest_ok=0
done
jq -S '{name,version,skills,harness:.metadata.harness}' "$PACKAGE/.claude-plugin/plugin.json" > "$TMP_ROOT/harness-claude.json"
jq -S '{name,version,skills,harness:.metadata.harness}' "$PACKAGE/.codex-plugin/plugin.json" > "$TMP_ROOT/harness-codex.json"
diff -u "$TMP_ROOT/harness-claude.json" "$TMP_ROOT/harness-codex.json" >/dev/null || manifest_ok=0
[ "$manifest_ok" -eq 1 ] && pass "両runtime一致のmarketplace / playbooks / implements宣言" || fail "manifestの公開契約宣言"
if diff -u \
  <(jq -r '.metadata.harness.implements[0].actions[]' "$PACKAGE/.claude-plugin/plugin.json" | sort) \
  <(yq -o=json -I=0 '.' "$ENTRY/playbook.yml" | jq -r '.contract.actions[]' | sort) >/dev/null; then
  pass "manifestのactionsとplaybookのcontract.actionsが一致"
else
  fail "actions宣言の不一致"
fi

# ── 3. 公開入口: SKILL / playbook.yml / CONTRACT.md / scripts ─────────────
entry_ok=1
for required in playbook.yml SKILL.md CONTRACT.md scripts/invoke.py scripts/control.py scripts/config.py references/settings.md references/operation-contract.md references/activation.md references/parallel-work.md assets/policy.example.yml; do
  [ -f "$ENTRY/$required" ] || entry_ok=0
done
[ "$(skill_frontmatter_name "$ENTRY/SKILL.md")" = "agent-work-policy" ] || entry_ok=0
[ "$entry_ok" -eq 1 ] && pass "公開入口の構成とSKILL名（agent-work-policy）" || fail "公開入口の構成"

printf '%s\n' '---' "name: 'agent-work-policy' # comment" '---' 'name: body-only' > "$TMP_ROOT/frontmatter-valid.md"
printf '%s\n' '---' 'description: no name' '---' 'name: agent-work-policy' > "$TMP_ROOT/frontmatter-invalid.md"
if [ "$(skill_frontmatter_name "$TMP_ROOT/frontmatter-valid.md")" = "agent-work-policy" ] \
  && ! skill_frontmatter_name "$TMP_ROOT/frontmatter-invalid.md" >/dev/null 2>&1; then
  pass "公開入口frontmatter YAML identity境界"
else
  fail "公開入口frontmatter YAML identity境界"
fi

playbook_json=$(yq -o=json -I=0 '.' "$ENTRY/playbook.yml")
if jq -e '
  .version==2 and .name=="agent-work-policy" and .requires==[]
  and .contract.contract_id=="agent-work-policy/agent-work-policy" and .contract.contract_version==1
  and .contract.invocation=={"input":"object","output":"object","entry":"scripts/invoke.py"}
  and .contract.gate_states==["allowed","waiting_for_human","denied"]
  and .contract.statuses==["completed","waiting_for_human","failed"]
  and (.steps|map(.id))==["build-input","config","invoke","report"]
  and .steps[1].script=="scripts/config.py"
  and (.steps[1].provides|sort)==(["config_path","config_values"]|sort)
  and .steps[2].script=="scripts/invoke.py"
  and (.steps[2].provides|sort)==(["approval_target","gate_state","operation_result","reason","status","workspace"]|sort)
' <<<"$playbook_json" >/dev/null && [ -f "$ENTRY/$(jq -r '.steps[1].script' <<<"$playbook_json")" ] && [ -f "$ENTRY/$(jq -r '.steps[2].script' <<<"$playbook_json")" ]; then
  pass "playbook.ymlの契約宣言と工程がentryへ接続"
else
  fail "playbook.ymlの契約宣言"
fi

contract_ok=1
for heading in '^## 1\. 入口' '^## 2\. 入力' '^## 3\. 出力' '^## 4\. 保証' '^## 5\. 利用者設定' '^### 5\.1 schema' '^## 6\. 非契約'; do
  rg -N "$heading" "$ENTRY/CONTRACT.md" >/dev/null || contract_ok=0
done
[ "$contract_ok" -eq 1 ] && pass "CONTRACT.mdが入口・入力・出力・保証・利用者設定・非契約の節を持つ" || fail "CONTRACT.mdの節"

# 基準資料: playbook.yml の contract（contract_id、actions）と invoke.py の PUBLIC_REASONS。
# 入力: CONTRACT.md の §2 の action 表、§3.2 の operation_result 表、§3.4 の reason 表の先頭列。
# 合格述語: 契約IDが本文に現れ、三つの表の先頭列の集合がそれぞれ基準資料の集合と一致する。
if python3 - "$ENTRY/CONTRACT.md" "$ENTRY/playbook.yml" "$ENTRY/scripts/invoke.py" <<'PY'
import importlib.util, json, re, subprocess, sys
contract, playbook, invoke = sys.argv[1:4]
text = open(contract, encoding="utf-8").read()
declared = json.loads(subprocess.run(["yq", "-o=json", "-I=0", ".contract", playbook], capture_output=True, text=True, check=True).stdout)
spec = importlib.util.spec_from_file_location("invoke", invoke); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
def section(start, end):
    a = text.index(start); b = text.index(end, a + len(start))
    return text[a:b]
def first_column(block):
    # 表の本体の行（見出し行と区切り行を除く）の先頭列にある backtick の値だけを集める。
    lines = block.splitlines()
    values = set()
    for index, line in enumerate(lines):
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if following.startswith("|---"):
            continue
        match = re.match(r"^\| `([^`]+)` \|", line)
        if match:
            values.add(match.group(1))
    return values
problems = []
if declared["contract_id"] not in text:
    problems.append("contract_id")
actions = set(declared["actions"])
if first_column(section("## 2. 入力", "### 2.2")) != actions:
    problems.append("§2 action表")
if first_column(section("### 3.2", "### 3.3")) != actions:
    problems.append("§3.2 operation_result表")
if first_column(section("### 3.4", "## 4. 保証")) != set(module.PUBLIC_REASONS):
    problems.append("§3.4 reason表")
if problems:
    print("不一致: " + ", ".join(problems), file=sys.stderr)
    sys.exit(1)
PY
then
  pass "CONTRACT.mdの契約ID・action表・operation_result表・reason表が、playbook.ymlとinvoke.pyの宣言と一致"
else
  fail "CONTRACT.mdの表が宣言と一致しない"
fi

public_input_ok=1
jq -e '.. | objects | has("output_to") | not' <<<"$playbook_json" >/dev/null || public_input_ok=0
sed -n '/^```yaml$/,/^```$/p' "$ENTRY/CONTRACT.md" | rg -N '^output_to:|^gate_context:' >/dev/null && public_input_ok=0
[ "$public_input_ok" -eq 1 ] && pass "公開objectにcaller用設定path・旧出力先を要求しない" || fail "公開objectに旧caller契約が残っている"

# ── 3.1 利用者設定は公開契約である ─────────────────────────────────────
# CONTRACT.md §5.1 の表と記入例 policy.example.yml のキー集合、control.py の POLICY_SCHEMA が一致する。
yq -o=json -I=0 '.' "$POLICY_EXAMPLE" \
  | jq -r '[paths as $p | select(($p | map(type=="number") | any) | not)
            | select((getpath($p)|type) != "object") | $p | join(".")] | unique | .[]' \
  | sort > "$TMP_ROOT/example-keys"
sed -n '/^### 5\.1 schema/,/^## 6\./p' "$ENTRY/CONTRACT.md" \
  | rg -N -o '^\| `([^`]+)` \|' -r '$1' | sort -u > "$TMP_ROOT/contract-keys"
python3 - "$ENTRY/scripts/control.py" <<'PY' | sort > "$TMP_ROOT/schema-keys"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("control", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("\n".join(m.POLICY_SCHEMA))
PY
if diff -u "$TMP_ROOT/example-keys" "$TMP_ROOT/contract-keys" > "$TMP_ROOT/keys.diff" && diff -u "$TMP_ROOT/contract-keys" "$TMP_ROOT/schema-keys" >> "$TMP_ROOT/keys.diff"; then
  pass "CONTRACT.md §5.1 のschema、記入例、control.py POLICY_SCHEMA のキー集合が一致"
else
  fail "CONTRACT.md §5.1 / policy.example.yml / POLICY_SCHEMA のキー集合が違う: $(rg -N '^[+-][^+-]' "$TMP_ROOT/keys.diff" | tr '\n' ' ')"
fi
if rg -NF '`<repo>/.harness-plugins/agent-work-policy.config.yml`' "$ENTRY/CONTRACT.md" >/dev/null \
  && ! rg -NF 'work-policy-control.config.yml' "$ENTRY/CONTRACT.md" "$ENTRY/SKILL.md" "$ENTRY/references" >/dev/null \
  && ! rg -NF '~/.config/harness-plugins' "$ENTRY/CONTRACT.md" "$ENTRY/SKILL.md" "$ENTRY/references" >/dev/null; then
  pass "利用者設定は repository 1層のファイル名だけを公開"
else
  fail "利用者設定のファイル名・層の公開"
fi

# ── 3.2 Zero-Plumbing: 配布指示に禁止参照形と旧runtime呼び出しが無い ──────────
if rg -n --fixed-strings -e '${.' -e '<!-- BEGIN shared:' -e 'CLAUDE_PLUGIN_ROOT' -e 'BUNDLE_ROOT' "$ENTRY/SKILL.md" "$ENTRY/CONTRACT.md" "$ENTRY/playbook.yml" "$ENTRY/references" >/dev/null; then
  fail "配布指示に禁止参照形が残っている"
else
  pass "配布指示に禁止参照形が無い"
fi
if rg -n 'prepare\.sh|resolve\.sh|run-config\.py|state\.py|apply-work-policy|work-policy-control|work-with-policy' "$ENTRY/SKILL.md" "$ENTRY/CONTRACT.md" "$ENTRY/playbook.yml" "$ENTRY/references" >/dev/null; then
  fail "旧runtime・旧内部名への参照が残っている"
else
  pass "旧runtime・旧内部名への参照が無い"
fi
scripts_found=$(find "$ENTRY/scripts" -type f -not -path "*/__pycache__/*" | sed "s#^$ENTRY/scripts/##" | sort | tr '\n' ' ')
[ "$scripts_found" = "config.py control.py invoke.py " ] && pass "入口scriptsはconfig.py・control.py・invoke.pyだけ" || fail "入口scriptsに余分なfile: $scripts_found"

# ── 3.3 設定読み取りtool config.py check|read（D7の共通契約） ─────────────────
# 基準資料: control.py の POLICY_FILE / POLICY_SCHEMA / validate_policy と共通契約（stdin不要、pathはtoolが固定、stdoutにJSON 1文書、失敗はexit 2と reason）。
# 入力: `config.py check|read --repo <path>`。正規化: git rev-parse --show-toplevel で git root を解決し、<root>/.harness-plugins/agent-work-policy.config.yml を yq でJSON化する。
# 合格述語: check は exit 0 と {"status":"ok","config":<絶対path>}、read は exit 0 と {"config","values"}（values は top-level key をそのまま）。
#   失敗は exit 2 と {"error","config","reason"} で reason は policy_missing / schema_violation / not_a_git_repository のどれか。not_a_git_repository では config は null。
# 正例: 記入例を置いた git repository（sub directory からでも可）。反例: file不在、key欠落、許容外の merge.method、yq で読めない file、git repository でない --repo。
# 意味評価: policy の値が repository の運用に合うかは本文を読む。
CONFIG_TOOL="$ENTRY/scripts/config.py"
CONFIG_REPO="$TMP_ROOT/config-repo"
mkdir -p "$CONFIG_REPO/.harness-plugins" "$CONFIG_REPO/sub" "$TMP_ROOT/config-nongit"
git -C "$CONFIG_REPO" init -q
cp "$POLICY_EXAMPLE" "$CONFIG_REPO/.harness-plugins/agent-work-policy.config.yml"
config_ok=1
out=$(python3 "$CONFIG_TOOL" check --repo "$CONFIG_REPO/sub") && jq -e --arg c "$(cd "$CONFIG_REPO" && pwd -P)/.harness-plugins/agent-work-policy.config.yml" '.=={"status":"ok","config":$c}' <<<"$out" >/dev/null || config_ok=0
out=$(python3 "$CONFIG_TOOL" read --repo "$CONFIG_REPO") && jq -e '(keys|sort)==["config","values"] and .values.version==1' <<<"$out" >/dev/null || config_ok=0
jq -e '(.values|keys|sort)==($ex|keys|sort)' --argjson ex "$(yq -o=json -I=0 '.' "$POLICY_EXAMPLE")" <<<"$out" >/dev/null || config_ok=0
out=$(python3 "$CONFIG_TOOL" check --repo "$TMP_ROOT/config-nongit"); [ "$?" -eq 2 ] && jq -e '.reason=="not_a_git_repository" and .config==null' <<<"$out" >/dev/null || config_ok=0
yq -i '.merge.method = "squash-and-pray"' "$CONFIG_REPO/.harness-plugins/agent-work-policy.config.yml"
out=$(python3 "$CONFIG_TOOL" check --repo "$CONFIG_REPO"); [ "$?" -eq 2 ] && jq -e '.reason=="schema_violation" and (.error|test("merge.method"))' <<<"$out" >/dev/null || config_ok=0
cp "$POLICY_EXAMPLE" "$CONFIG_REPO/.harness-plugins/agent-work-policy.config.yml"
yq -i 'del(.merge.method)' "$CONFIG_REPO/.harness-plugins/agent-work-policy.config.yml"
out=$(python3 "$CONFIG_TOOL" read --repo "$CONFIG_REPO"); [ "$?" -eq 2 ] && jq -e '.reason=="schema_violation" and (.error|test("merge.method"))' <<<"$out" >/dev/null || config_ok=0
printf 'a: [\n' > "$CONFIG_REPO/.harness-plugins/agent-work-policy.config.yml"
out=$(python3 "$CONFIG_TOOL" check --repo "$CONFIG_REPO"); [ "$?" -eq 2 ] && jq -e '.reason=="schema_violation"' <<<"$out" >/dev/null || config_ok=0
rm "$CONFIG_REPO/.harness-plugins/agent-work-policy.config.yml"
out=$(python3 "$CONFIG_TOOL" check --repo "$CONFIG_REPO"); [ "$?" -eq 2 ] && jq -e '.reason=="policy_missing" and (.config|endswith("/.harness-plugins/agent-work-policy.config.yml"))' <<<"$out" >/dev/null || config_ok=0
python3 "$CONFIG_TOOL" check >/dev/null 2>&1; [ "$?" -eq 2 ] || config_ok=0
[ "$config_ok" -eq 1 ] && pass "config.py check|read の契約（正例・policy_missing・schema_violation・not_a_git_repository）" || fail "config.py check|read の契約"

# ── 4. 公開object入口のwalkthrough ───────────────────────────────────────
PUBLIC_ENTRY="$ENTRY/scripts/invoke.py"
DIRECT_REPO="$TMP_ROOT/direct-repo"
mkdir -p "$DIRECT_REPO"
git -C "$DIRECT_REPO" init -q -b main
git -C "$DIRECT_REPO" config user.name test
git -C "$DIRECT_REPO" config user.email test@example.invalid
printf 'base\n' > "$DIRECT_REPO/tracked.txt"
git -C "$DIRECT_REPO" add tracked.txt
git -C "$DIRECT_REPO" commit -qm base
git -C "$DIRECT_REPO" checkout -qb agent/direct-contract

# policy不在: 操作前に policy_missing で止まり、repositoryを変えない。
printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"inspect","repo":"%s"}\n' "$DIRECT_REPO" \
  | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-missing.json" 2>/dev/null; missing_code=$?
if [ "$missing_code" -eq 3 ] && jq -e '.status=="failed" and .reason=="policy_missing" and (.workspace|keys|length)==5 and (has("approval_target")|not)' "$TMP_ROOT/direct-missing.json" >/dev/null; then
  pass "policy設定fileが無ければ操作前に policy_missing で止まる"
else
  fail "policy不在の停止: $(cat "$TMP_ROOT/direct-missing.json")"
fi

mkdir -p "$DIRECT_REPO/.harness-plugins"
cp "$POLICY_EXAMPLE" "$DIRECT_REPO/.harness-plugins/agent-work-policy.config.yml"
printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"inspect","repo":"%s"}\n' "$DIRECT_REPO" \
  | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-inspect.json"
if jq -e '
    .contract=="agent-work-policy/agent-work-policy" and .version==1 and .action=="inspect"
    and .status=="completed" and .gate_state=="allowed" and (.operation_result|type)=="object"
    and (.workspace|keys|sort)==["base_branch","branch","draft","remote","worktree"]
    and .workspace.base_branch=="main" and .workspace.remote=="origin" and .workspace.draft==true
    and .reason=="" and (has("approval_target")|not)
    and ([paths(scalars) as $p | $p[-1]] | index("exit_code") | not)
  ' "$TMP_ROOT/direct-inspect.json" >/dev/null; then
  pass "公開entryが直接入力objectから直接結果objectを返し、workspaceをpolicyから埋める"
else
  fail "公開entryの直接inspect結果schema"
fi

# 旧callerキーと未知actionは policy 読み取り前に拒否し、repositoryを変えない。
direct_before=$(git -C "$DIRECT_REPO" status --porcelain=v1)
if printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"inspect","repo":"%s","output_to":"/tmp/out.yml"}\n' "$DIRECT_REPO" \
    | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-invalid.json" 2>/dev/null; then
  fail "公開entryが旧output_toを受理している"
elif jq -e '.status=="failed" and .reason=="invalid_input" and (.workspace|keys|length)==5' "$TMP_ROOT/direct-invalid.json" >/dev/null \
    && [ "$(git -C "$DIRECT_REPO" status --porcelain=v1)" = "$direct_before" ]; then
  pass "公開entryが旧output_toを操作前に拒否しworkspace schemaを維持"
else
  fail "公開entryの旧output_to拒否結果"
fi
for bad in '"action":"verify"' '"action":"commit","paths":["tracked.txt"],"message":"m","approved":true' '"action":"inspect","approval":{"actions":["merge"],"pull_requests":[1],"until":"2999-01-01T00:00:00+00:00","quote":["q"]}' '"action":"push","title":"t"' '"contract":"grill/grill","action":"inspect"'; do
  if printf '{"contract":"agent-work-policy/agent-work-policy","version":1,%s,"repo":"%s"}\n' "$bad" "$DIRECT_REPO" \
      | sed 's/"contract":"agent-work-policy\/agent-work-policy","version":1,"contract"/"version":1,"contract"/' \
      | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-bad.json" 2>/dev/null; then
    fail "契約違反の入力を受理している: $bad"
  elif jq -e '.status=="failed" and .reason=="invalid_input"' "$TMP_ROOT/direct-bad.json" >/dev/null; then
    pass "契約違反の入力を操作前に拒否する: $bad"
  else
    fail "契約違反の入力の拒否理由が invalid_input でない: $bad"
  fi
done

# gateは操作前に止まり、内部contextを承認対象objectとして直接返す。
printf 'change\n' >> "$DIRECT_REPO/tracked.txt"
printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"commit","repo":"%s","paths":["tracked.txt"],"message":"test"}\n' "$DIRECT_REPO" \
  | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-gate.json" 2>/dev/null || direct_gate_code=$?
if [ "${direct_gate_code:-0}" -eq 3 ] \
  && jq -e '.status=="waiting_for_human" and .gate_state=="waiting_for_human"
      and .approval_target.gate=="before_commit" and .approval_target.paths==["tracked.txt"]
      and (.operation_result|type)=="object" and .reason==""' "$TMP_ROOT/direct-gate.json" >/dev/null \
  && git -C "$DIRECT_REPO" diff --cached --quiet; then
  pass "公開entryがgate前に停止しapproval_targetを直接返す"
else
  fail "公開entryのgate停止と承認対象"
fi

# 承認範囲の外なら同じくgateで止まり、外れた要素を approval_target に添える。
printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"commit","repo":"%s","paths":["tracked.txt"],"message":"test","approval":{"actions":["commit"],"branches":["agent/other"],"until":"2999-01-01T00:00:00+00:00","quote":["agent/otherのcommitは許可"]}}\n' "$DIRECT_REPO" \
  | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-outside.json" 2>/dev/null
if jq -e '.status=="waiting_for_human" and .approval_target.outside_approval==["branch"]' "$TMP_ROOT/direct-outside.json" >/dev/null \
  && git -C "$DIRECT_REPO" diff --cached --quiet; then
  pass "承認範囲の外の実行はgateで止まり、外れた要素を返す"
else
  fail "承認範囲の外の実行: $(cat "$TMP_ROOT/direct-outside.json")"
fi
printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"commit","repo":"%s","paths":["tracked.txt"],"message":"test","approval":{"actions":["commit"],"branches":["agent/"],"until":"2999-01-01T00:00:00+00:00","quote":["agent/のcommitは許可"]}}\n' "$DIRECT_REPO" \
  | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-approved.json" 2>/dev/null
if jq -e '.status=="completed" and .operation_result.branch=="agent/direct-contract"' "$TMP_ROOT/direct-approved.json" >/dev/null; then
  pass "承認範囲に入る実行はgateを通る"
else
  fail "承認範囲に入る実行: $(cat "$TMP_ROOT/direct-approved.json")"
fi

# permission拒否は承認待ちへ変えず、外部CLIへ進まない。
printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"merge","repo":"%s","pr":1}\n' "$DIRECT_REPO" \
  | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-denied.json" 2>/dev/null || direct_denied_code=$?
if [ "${direct_denied_code:-0}" -eq 3 ] \
  && jq -e '.status=="failed" and .gate_state=="denied" and .reason=="permission_denied"
      and (has("approval_target")|not)' "$TMP_ROOT/direct-denied.json" >/dev/null; then
  pass "公開entryがpermission拒否を承認質問へ変えない"
else
  fail "公開entryのpermission拒否"
fi

# policy schema違反（未知key / 欠落key / 型違い / fast-forward制約）は操作前に error と診断で止まる。
for edit in '.extra = 1' 'del(.git.remote)' '.permissions.commit = "yes"' '.merge.method = "fast-forward"' '.instructions.execution.directive = "x"'; do
  cp "$POLICY_EXAMPLE" "$DIRECT_REPO/.harness-plugins/agent-work-policy.config.yml"
  yq -i "$edit" "$DIRECT_REPO/.harness-plugins/agent-work-policy.config.yml"
  if printf '{"contract":"agent-work-policy/agent-work-policy","version":1,"action":"inspect","repo":"%s"}\n' "$DIRECT_REPO" \
      | python3 "$PUBLIC_ENTRY" > "$TMP_ROOT/direct-schema.json" 2>/dev/null; then
    fail "schema違反のpolicyを受理している: $edit"
  elif jq -e '.status=="failed" and .reason=="error" and (.detail.error|type)=="string"' "$TMP_ROOT/direct-schema.json" >/dev/null; then
    pass "schema違反のpolicyを操作前に診断付きで拒否する: $edit"
  else
    fail "schema違反のpolicyの拒否結果: $edit $(cat "$TMP_ROOT/direct-schema.json")"
  fi
done
cp "$POLICY_EXAMPLE" "$DIRECT_REPO/.harness-plugins/agent-work-policy.config.yml"

# 別repositoryのpolicyを流用できない（束縛）。
OTHER_REPO="$TMP_ROOT/other-repo"
mkdir -p "$OTHER_REPO"; git -C "$OTHER_REPO" init -q -b main
if python3 "$ENTRY/scripts/control.py" inspect --config "$DIRECT_REPO/.harness-plugins/agent-work-policy.config.yml" --repo "$OTHER_REPO" > "$TMP_ROOT/bound.json" 2>/dev/null; then
  fail "別repositoryのpolicyで操作できてしまう"
elif jq -e '.error=="設定と対象repositoryが一致しない"' "$TMP_ROOT/bound.json" >/dev/null; then
  pass "policyは置かれたrepositoryへ束縛される"
else
  fail "policy束縛の診断: $(cat "$TMP_ROOT/bound.json")"
fi

if python3 - "$PUBLIC_ENTRY" "$ENTRY/scripts/control.py" <<'PY'
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("public_invoke", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
control_spec = importlib.util.spec_from_file_location("work_policy_control", sys.argv[2])
control = importlib.util.module_from_spec(control_spec)
control_spec.loader.exec_module(control)
cfg = {"pull_request": {"draft": True}}

assert module.map_completed_operation("pull-request", {
    "status": "created", "url": "https://github.com/acme/app/pull/42",
}, cfg) == {"pull_request": 42, "url": "https://github.com/acme/app/pull/42", "draft": True}
assert module.map_completed_operation("merge-readiness", {
    "status": "not_ready", "pr": 42, "reasons": ["checks", "approvals"],
}, cfg) == {"pull_request": 42, "ready": False, "unmet": ["checks", "approvals"]}
assert module.is_completed_result("merge-readiness", "not_ready", 3)
assert not module.is_completed_result("merge-readiness", "not_ready", 9)
assert module.is_completed_result("merge-readiness", "ready", 0)
assert not module.is_completed_result("merge-readiness", "ready", 9)
assert not module.is_completed_result("inspect", [], 0)
assert not module.is_completed_result("inspect", {}, 0)

for payload in (
    {"contract": module.CONTRACT, "version": 1, "action": [], "repo": "/"},
    {"contract": module.CONTRACT, "version": 1, "action": "commit", "repo": "/", "paths": {"a": 1}, "message": "m"},
    *(
        {"contract": module.CONTRACT, "version": 1, "action": "commit", "repo": "/", "paths": [f"a{separator}b"], "message": "m"}
        for separator in ("\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\x85", " ", " ")
    ),
    {"contract": module.CONTRACT, "version": 1, "action": "commit", "repo": "/", "paths": [" leading"], "message": "m"},
    {"contract": module.CONTRACT, "version": 1, "action": "commit", "repo": "/", "paths": ["trailing "], "message": "m"},
):
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output):
            module.validate(payload)
    except SystemExit as exc:
        assert exc.code == 2
    else:
        raise AssertionError("invalid input was accepted")
    assert json.loads(output.getvalue())["reason"] == "invalid_input"

exact_paths = ["ordinary space.txt", "internal\ttab.txt", "src/a.py", "src/b.py"]
validated = module.validate({
    "contract": module.CONTRACT, "version": 1, "action": "commit", "repo": "/",
    "paths": exact_paths, "message": "m",
})
assert validated["paths"] == exact_paths

code, value = module.read_json([sys.executable, "-c", "print('not-json')"])
assert code != 0 and value["reason"] == "invalid_internal_result"
for invalid_status in ([], {}):
    code, value = module.normalize_internal_operation(0, {"status": invalid_status})
    assert code != 0 and value == {"status": "failed", "reason": "invalid_internal_result"}
code, value = module.normalize_internal_operation(2, {"error": "policy設定の型が不正", "key": "permissions.commit"})
assert code == 3 and value["status"] == "failed" and value["reason"] == "error" and value["detail"]["key"] == "permissions.commit"

# policy schema: 正例・反例・境界例
def policy():
    return {
        "version": 1,
        "workspace": {"use_worktree": False, "require_clean_start": True, "base_branch": "main", "branch_prefix": "agent/", "worktree_root": ""},
        "git": {"remote": "origin"},
        "permissions": {"commit": True, "push": True, "pull_request": True, "merge": False},
        "gates": {"before_commit": True, "before_push": True, "before_pull_request": True, "before_merge": True},
        "verification": {"commands": ["git diff --check"]},
        "pull_request": {"draft": True},
        "merge": {"method": "squash", "delete_branch": False, "delete_worktree": False,
                  "readiness": {"min_approvals": 1, "required_checks": [{"name": "validate", "app": "github-actions"}], "require_no_unresolved_threads": True}},
    }
def rejects(cfg):
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            control.validate_policy(cfg, "fixture")
    except SystemExit as exc:
        assert exc.code == 2, exc.code
        return json.loads(out.getvalue())["error"]
    raise AssertionError("invalid policy accepted")
control.validate_policy(policy(), "fixture")
good = policy(); good["workspace"]["worktree_root"] = ""; good["merge"]["readiness"]["min_approvals"] = 0
control.validate_policy(good, "fixture")  # 境界例: 空文字とmin_approvals 0 は有効
bad = policy(); bad["permissions"]["merge"] = 1; assert "型が不正" in rejects(bad)  # 境界例: 1 は boolean ではない
bad = policy(); bad["merge"]["readiness"]["min_approvals"] = True; assert "型が不正" in rejects(bad)
bad = policy(); del bad["gates"]["before_merge"]; assert "一致しない" in rejects(bad)
bad = policy(); bad["workspace"]["extra"] = 1; assert "一致しない" in rejects(bad)
bad = policy(); bad["instructions"] = {"execution": {"directive": "x"}}; assert "一致しない" in rejects(bad)  # 反例: agent向け指示文keyは未知keyとして拒否
bad = policy(); bad["version"] = 2; assert "version" in rejects(bad)
bad = policy(); bad["merge"]["method"] = "fast-forward"; assert "fast-forward" in rejects(bad)
bad = policy(); bad["merge"]["delete_worktree"] = True; assert "delete_worktree" in rejects(bad)
bad = policy(); bad["verification"]["commands"] = [""]; assert "型が不正" in rejects(bad)
bad = policy(); bad["merge"]["readiness"]["required_checks"] = []; assert "required_checks" in rejects(bad)  # 反例: 必須checkの宣言が無い
bad = policy(); bad["merge"]["readiness"]["required_checks"] = ["validate"]; assert "型が不正" in rejects(bad)  # 反例: 報告元Appの無い名前だけの宣言
bad = policy(); bad["merge"]["readiness"]["required_checks"] = [{"name": "validate", "app": "github-actions"}] * 2; assert "required_checks" in rejects(bad)
bad = policy(); bad["merge"]["readiness"]["require_checks_passed"] = True; assert "一致しない" in rejects(bad)  # 反例: 廃止したkey

# 必須checkは名前と報告元Appの組で判定する
runs = [{"name": "validate", "app": "github-actions", "status": "COMPLETED", "conclusion": "SUCCESS", "completedAt": "2026-09-24T00:00:00Z"}]
rollup = [{"name": "validate", "conclusion": "SUCCESS"}]
need = [{"name": "validate", "app": "github-actions"}]
done = lambda items: {"runs": items, "settled": True}
assert control.check_state(rollup, done(runs), need) == "passed"
assert control.check_state(rollup, done([{**runs[0], "app": "impostor"}]), need) == "missing"  # 反例: 同名checkを別のAppが成功させ、suiteは揃って完了した
assert control.check_state(rollup, {"runs": [{**runs[0], "app": "impostor"}], "settled": False}, need) == "pending"  # 境界例: suiteが走っている間はまだ作られていないだけ
assert control.check_state(rollup, {"runs": [], "settled": False}, need) == "pending"  # 境界例: pushの直後でsuiteがまだ無い
assert control.check_state([], done(runs), need) == "pending"  # 境界例: 最後のPR snapshotでまだ成功が見えない
assert control.check_state(rollup, done([{**runs[0], "status": "IN_PROGRESS", "conclusion": None}]), need) == "pending"
assert control.check_state(rollup, done([{**runs[0], "conclusion": "FAILURE"}]), need) == "failed"
two = need + [{"name": "lint", "app": "github-actions"}]
assert control.check_state(rollup, {"runs": [{**runs[0], "status": "IN_PROGRESS", "conclusion": None}], "settled": True}, two) == "pending"  # 実行中と未報告が並ぶときは pending を先に返す
older_failure = [{**runs[0], "conclusion": "FAILURE", "completedAt": "2026-09-23T00:00:00Z"}, runs[0]]
assert control.check_state(rollup, done(older_failure), need) == "passed"  # 境界例: 再実行で最新が成功なら成功

# update-branch の公開結果
assert module.map_completed_operation("update-branch", {"status": "updated", "pr": 7, "changed": True, "sha": "a" * 40}, cfg) == {"pull_request": 7, "changed": True, "sha": "a" * 40}

# 承認範囲: 形の検査と、action・対象・期限の照合
from datetime import datetime, timezone
scope = {"actions": ["merge"], "pull_requests": [24, 25], "until": "2026-09-25T00:00:00+09:00", "quote": ["PR 24と25はマージしていいよ"]}
assert control.approval_problem(scope, None) is None
assert control.approval_problem({**scope, "actions": ["merge", "ready-for-review"]}, None) is None  # 境界例: 他のpackageの確認の名前が並んでいても受け取る
assert control.approval_mismatch({**scope, "actions": ["ready-for-review"]}, "merge", 25, None, datetime(2026, 9, 24, 14, 0, tzinfo=timezone.utc)) == ["action"]
now = datetime(2026, 9, 24, 12, 0, tzinfo=timezone.utc)
assert control.approval_mismatch(scope, "merge", 25, None, datetime(2026, 9, 24, 14, 0, tzinfo=timezone.utc)) == []  # 正例
assert control.approval_mismatch(scope, "merge", 28, None, datetime(2026, 9, 24, 14, 0, tzinfo=timezone.utc)) == ["pull_request"]  # 反例: 範囲外のPR
assert control.approval_mismatch(scope, "push", None, "agent/x", datetime(2026, 9, 24, 14, 0, tzinfo=timezone.utc)) == ["action", "branch"]
assert control.approval_mismatch(scope, "merge", 24, None, datetime(2026, 9, 24, 15, 0, tzinfo=timezone.utc)) == ["until"]  # 境界例: 期限ちょうどは範囲外
for broken in (
    {**scope, "until": "2026-09-25T00:00:00"},  # 時差の無い時刻
    {**scope, "until": "session"},
    {k: v for k, v in scope.items() if k != "quote"},
    {**scope, "quote": " "},
    {**scope, "quote": []},
    {**scope, "quote": ["原文", ""]},
    {**scope, "actions": [""]},  # 空の名前
    {k: v for k, v in scope.items() if k != "pull_requests"},  # 対象の列挙が無い
    {**scope, "scope": "危険でない限り"},  # 列挙できない範囲
):
    assert control.approval_problem(broken, None) is not None, broken

# branchはprefix（末尾 /）でも指せる。policyの作業branchの外へは広げられない
wide = {"actions": ["commit", "push", "pull-request"], "branches": ["agent/"], "until": "2026-09-25T00:00:00+09:00",
        "quote": ["今から行う作業においては危険なコマンドでない限り許可不要", "それでいい"]}
at = datetime(2026, 9, 24, 14, 0, tzinfo=timezone.utc)
assert control.approval_problem(wide, None) is None
assert control.approval_mismatch(wide, "push", None, "agent/fix-a", at) == []  # 正例: 事前に名前の分からないbranch
assert control.approval_mismatch(wide, "push", None, "agentx/fix-a", at) == ["branch"]  # 反例: prefixの外
assert control.approval_mismatch({**wide, "branches": ["agent/fix-a"]}, "push", None, "agent/fix-ab", at) == ["branch"]  # 境界例: 末尾 / の無い要素は完全一致
policy_cfg = {"workspace": {"branch_prefix": "agent/", "base_branch": "main"}}
assert control.approval_problem(wide, policy_cfg) is None
assert control.approval_problem({**wide, "branches": ["main"]}, policy_cfg) is not None  # 反例: base branch
assert control.approval_problem({**wide, "branches": ["a"]}, policy_cfg) is not None  # 反例: 作業branchのprefixを覆う
assert control.approval_problem({**wide, "branches": [""]}, policy_cfg) is not None
PY
then
  pass "公開結果のaction別写像、型境界、内部JSON不正、policy schemaの正例・反例・境界例"
else
  fail "公開結果写像またはpolicy schemaの単体検査"
fi

# ── 5. inspect は read-only の照会である ─────────────────────────────────
inspect_repo="$TMP_ROOT/inspect-repo"
mkdir -p "$inspect_repo/.harness-plugins"
cp "$POLICY_EXAMPLE" "$inspect_repo/.harness-plugins/agent-work-policy.config.yml"
git -C "$inspect_repo" init -q
git -C "$inspect_repo" symbolic-ref HEAD refs/heads/main
printf 'a\n' > "$inspect_repo/a.txt"
git -C "$inspect_repo" add a.txt
git -C "$inspect_repo" -c user.email=t@example.invalid -c user.name=t commit -qm init
git -C "$inspect_repo" switch -qc agent/existing
printf 'dirty\n' > "$inspect_repo/b.txt"
inspect_cfg="$inspect_repo/.harness-plugins/agent-work-policy.config.yml"
if python3 "$ENTRY/scripts/control.py" inspect --config "$inspect_cfg" --repo "$inspect_repo" \
    > "$TMP_ROOT/inspect.json" 2> "$TMP_ROOT/inspect.err" \
  && jq -e '.status=="inspected" and .clean==false and .branch=="agent/existing"
            and .base_branch_exists==true and (has("worktree")) and (has("pull_request"))
            and (.remote|type=="string") and (.draft|type=="boolean")' "$TMP_ROOT/inspect.json" >/dev/null; then
  pass "inspectは既存branch・dirtyでも止まらず現況を返す"
else
  fail "inspectが現況を返さない: $(head -1 "$TMP_ROOT/inspect.err")"
fi
if python3 "$ENTRY/scripts/control.py" plan --config "$inspect_cfg" --repo "$inspect_repo" --branch agent/new >/dev/null 2>&1; then
  fail "planが汚れたworking treeで止まらない（inspectと役割が同じになっている）"
else
  pass "planは同じ状況で止まる（inspectと役割が分かれている）"
fi

# ── 6. 構文と既存の契約試験 ────────────────────────────────────────────
syntax_failed=0
while IFS= read -r script; do bash -n "$script" || syntax_failed=1; done < <(find "$ROOT/scripts" "$ROOT/tests" -name '*.sh' -type f | sort)
[ "$syntax_failed" -eq 0 ] && pass "shell構文" || fail "shell構文"
python_failed=0
while IFS= read -r script; do python3 -m py_compile "$script" || python_failed=1; done < <(find "$ENTRY/scripts" -name '*.py' -type f | sort)
[ "$python_failed" -eq 0 ] && pass "Python構文" || fail "Python構文"
# repositoryの回帰検査（harness-tools）: CI workflowのSHA固定、公開入口の一意性、doctorの読み取り専用性
python3 "$TOOLS/test-hardening.py" --repository "$ROOT" && pass "test-hardening --repository" || fail "test-hardening --repository"
bash "$ROOT/tests/publication-authority-contract.sh" && pass "公開操作の停止契約" || fail "公開操作の停止契約"
bash "$ROOT/tests/license-contract.sh" && pass "LICENSE契約" || fail "LICENSE契約"
bash "$ROOT/tests/secret-scanning-contract.sh" && pass "secret scanning契約" || fail "secret scanning契約"

symlink_count=$(find "$ROOT/plugins" -type l | wc -l | tr -d ' ')
[ "$symlink_count" -eq 0 ] && pass "配布物にsymlinkなし" || fail "配布物にsymlinkがある"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
