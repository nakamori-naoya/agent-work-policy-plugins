#!/usr/bin/env bash
# Scenario: agent-work-policy marketplaceがPlaybook package 1件で自己完結し、両runtimeで解決できる
set -uo pipefail
# **継承したenvで負の試験を破らせない。** dev-map と installed-cache の上書きが外から
# 入っていると、「解決できないはず」の負例が解決してしまい、緑のまま規則が抜ける。
# 必要な検査は、自分でその場だけ設定する。
unset HARNESS_PLUGIN_DEV_ROOTS HARNESS_PLUGIN_CACHE_ROOT
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 "$ROOT/scripts/test-hardening.py" || exit 1
# **一時領域を正規形へ直さない。** macOS 既定の TMPDIR は /var/folders/... という
# symlink 越しの path であり、契約入口はそれをそのまま受けなければならない（realpath正規化）。
# ここで正規形へ直すと、消費側が素直に書いた入力の経路を試験しないことになる。
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-work-policy-validation.XXXXXX") || exit 2
export TMPDIR="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
passed=0 failed=0
pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; failed=$((failed + 1)); }

PB="$ROOT/plugins/playbooks/automation/agent-work-policy"
INTERNAL="$ROOT/plugins/skills/automation/work-policy-control"

# ── 1. 公開インストール対象はPlaybook package 1件だけである ──────────────
jq -r '.plugins[].name' "$ROOT/.agents/plugins/marketplace.json" | sort > "$TMP_ROOT/expected"
jq -r '.name' "$ROOT/plugins/.codex-plugin/plugin.json" | sort > "$TMP_ROOT/actual"
diff -u "$TMP_ROOT/expected" "$TMP_ROOT/actual" >/dev/null && pass "公開インストール対象はagent-work-policy playbook packageだけ" || fail "plugin集合"
for market in .agents/plugins/marketplace.json .claude-plugin/marketplace.json; do
  jq -r '.plugins[].name' "$ROOT/$market" | sort > "$TMP_ROOT/market"
  diff -u "$TMP_ROOT/expected" "$TMP_ROOT/market" >/dev/null && pass "$market plugin集合" || fail "$market plugin集合"
done
while IFS='|' read -r name version rel; do
  if jq -e --arg n "$name" --arg v "$version" '.name==$n and .version==$v' "$ROOT/$rel/.codex-plugin/plugin.json" >/dev/null \
    && jq -e --arg n "$name" --arg v "$version" '.name==$n and .version==$v' "$ROOT/$rel/.claude-plugin/plugin.json" >/dev/null; then
    pass "$name manifest identity"
  else
    fail "$name manifest identity"
  fi
  bash "$ROOT/scripts/validate-plugin-license.sh" "$ROOT/LICENSE" "$ROOT/$rel/LICENSE" && pass "$name LICENSE" || fail "$name LICENSE"
done < <(jq -r '.plugins[] | [.name,.version,(.source.path | ltrimstr("./"))] | join("|")' "$ROOT/.agents/plugins/marketplace.json")
bash "$ROOT/scripts/validate-marketplace.sh" "$ROOT" && pass "marketplace配布契約" || fail "marketplace配布契約"
bash "$ROOT/scripts/test-marketplace-validation.sh" "$ROOT" && pass "marketplace配布契約の負例" || fail "marketplace配布契約の負例"

# ── 2. manifestが公開契約を自己宣言している ─────────────────────────────
manifest_ok=1
for runtime in claude codex; do
  jq -e '
    .metadata.harness as $h
    | $h.installationSurface=="playbook-package"
      and $h.marketplace=="agent-work-policy"
      and $h.contractVersion==1
      and $h.playbooks=={"agent-work-policy":"./playbooks/automation/agent-work-policy"}
      and $h.internalPlugins=={"work-policy-control":"./skills/automation/work-policy-control"}
      and ($h.implements|type=="array" and length==1)
      and ($h.implements[0]
           | .id=="agent-work-policy/agent-work-policy" and .version==1 and .kind=="playbook"
             and .playbook=="agent-work-policy"
             and (.actions|type=="array" and length>0
                  and all(.[]; type=="string" and test("^[a-z0-9]+(-[a-z0-9]+)*$")))
             and ((keys|sort)==["actions","id","kind","playbook","version"]))
  ' "$ROOT/plugins/.$runtime-plugin/plugin.json" >/dev/null || manifest_ok=0
done
jq -S '.metadata.harness' "$ROOT/plugins/.claude-plugin/plugin.json" > "$TMP_ROOT/harness-claude.json"
jq -S '.metadata.harness' "$ROOT/plugins/.codex-plugin/plugin.json" > "$TMP_ROOT/harness-codex.json"
diff -u "$TMP_ROOT/harness-claude.json" "$TMP_ROOT/harness-codex.json" >/dev/null || manifest_ok=0
if [ "$manifest_ok" -eq 1 ]; then
  pass "両runtime一致のmarketplace / playbooks / internalPlugins / implements宣言"
else
  fail "manifestの公開契約宣言"
fi
# implementsのactionsとplaybook.ymlのcontract.actionsは同じ集合である
if diff -u \
  <(jq -r '.metadata.harness.implements[0].actions[]' "$ROOT/plugins/.claude-plugin/plugin.json" | sort) \
  <(yq -o=json -I=0 '.' "$PB/playbook.yml" | jq -r '.contract.actions[]' | sort) >/dev/null; then
  pass "manifestのactionsとplaybookのcontract.actionsが一致"
else
  fail "actions宣言の不一致"
fi

# ── 3. 公開面の4点とCONTRACT.mdが揃っている ────────────────────────────
entry_ok=1
for required in playbook.yml SKILL.md CONTRACT.md scripts/prepare.sh scripts/resolve.sh scripts/resolve-dependency.py scripts/validate-config.sh scripts/validate-input.sh; do
  [ -f "$PB/$required" ] || entry_ok=0
done
[ -x "$PB/scripts/validate-config.sh" ] || entry_ok=0
# 入口hookはsymlinkだと実行されない。通常ファイルであること。
[ -f "$PB/scripts/validate-input.sh" ] && [ ! -L "$PB/scripts/validate-input.sh" ] || entry_ok=0
rg -N '^name: work-with-policy$' "$PB/SKILL.md" >/dev/null || entry_ok=0
rg -N '^name: apply-work-policy$' "$INTERNAL/skills/apply-work-policy/SKILL.md" >/dev/null || entry_ok=0
[ "$entry_ok" -eq 1 ] && pass "公開入口4点と入口SKILL名（work-with-policy）" || fail "公開入口の構成"

# **入れ子でprepareを重ねない。** 呼び出し元がE1で作った解決済みYAMLを受け取ったら、それを使う。
# 再実行するとscopeと束縛lockが捨てられ、1回の呼び出しに実行設定が二重にできる。
nest_ok=1
rg -NF 'if [ -n "${CFG_FILE:-}" ]' "$PB/SKILL.md" >/dev/null || nest_ok=0
rg -NF 'E1 で解決 → その path を E4 へ渡す' "$PB/CONTRACT.md" >/dev/null || nest_ok=0
[ "$nest_ok" -eq 1 ] && pass "入れ子呼び出しでprepareを再実行しない（入口SKILL.mdと契約）" \
  || fail "入れ子呼び出しでのprepare再実行禁止が入口SKILL.md／CONTRACT.mdに無い"

contract_ok=1
for heading in '^## 1\. 入口' '^## 2\. 入力' '^## 3\. 出力' '^## 4\. 保証' '^## 5\. 利用者設定' '^### 5\.1 schema' '^## 6\. 非契約'; do
  rg -N "$heading" "$PB/CONTRACT.md" >/dev/null || contract_ok=0
done
for keyword in 'agent-work-policy/agent-work-policy' 'output_to' 'gate_context' 'waiting_for_human' 'workspace'; do
  rg -NF "$keyword" "$PB/CONTRACT.md" >/dev/null || contract_ok=0
done
[ "$contract_ok" -eq 1 ] && pass "CONTRACT.mdが入口・入力・出力・保証・非契約を公開" || fail "CONTRACT.mdの節"

# **E4は `${.deps.<論理名>.entry}` である。** skills map を消費側から引く形は resolver と lint が
# external-dependency-path として落とすので、CONTRACT.md に例示しない。ブラケット形も同様。
entry_skill_name=$(rg -N -m1 '^name: (.+)$' -r '$1' "$PB/SKILL.md")
e4_ok=1
rg -qF '${.deps.agent-work-policy.entry}' "$PB/CONTRACT.md" || e4_ok=0
rg -q '\$\{[^}]*\.skills[.\[]' "$PB/CONTRACT.md" && e4_ok=0
rg -q '\$\{[^}]*\[\s*["'"'"']' "$PB/CONTRACT.md" && e4_ok=0
[ "$e4_ok" -eq 1 ] && pass "CONTRACT.mdのE4例が \${.deps.agent-work-policy.entry} である" \
  || fail "CONTRACT.mdのE4例がentry形でない、またはskills／ブラケット形を例示している"

# 委譲節を残さない。下流は公開playbookからしか呼べない。
if rg -N '下流plugin' "$PB/SKILL.md" "$INTERNAL/skills/apply-work-policy/SKILL.md" >/dev/null \
  || rg -NF 'POLICY_ROOT' "$PB" "$INTERNAL" >/dev/null; then
  fail "外部pluginへscriptの直接実行を案内する記述が残っている"
else
  pass "外部pluginへのscript直叩き案内なし"
fi

# ── 3.1 利用者設定は公開契約である ─────────────────────────────────────
# **消費側は設定を読まないが、利用者は読む。** ファイル名とキー集合を公開契約として固定し、
# CONTRACT.md §5.1 の表と同梱既定 defaults.yml のキー集合が一致することを機械で見る。
# 一致しないまま出すと、利用者は書いても効かないキーを渡され、exit 2 の理由も分からない。
DEFAULTS="$INTERNAL/config/defaults.yml"
yq -o=json -I=0 '.' "$DEFAULTS" \
  | jq -r '[paths as $p | select(($p | map(type=="number") | any) | not)
            | select((getpath($p)|type) != "object") | $p | join(".")] | unique | .[]' \
  | sort > "$TMP_ROOT/defaults-keys"
sed -n '/^### 5\.1 schema/,/^## 6\./p' "$PB/CONTRACT.md" \
  | rg -N -o '^\| `([^`]+)` \|' -r '$1' | sort -u > "$TMP_ROOT/contract-keys"
if diff -u "$TMP_ROOT/defaults-keys" "$TMP_ROOT/contract-keys" > "$TMP_ROOT/keys.diff"; then
  pass "CONTRACT.md §5.1 のschemaと同梱既定 defaults.yml のキー集合が一致"
else
  fail "CONTRACT.md §5.1 と defaults.yml のキー集合が違う: $(rg -N '^[+-][^+-]' "$TMP_ROOT/keys.diff" | tr '\n' ' ')"
fi
# 設定ファイル名（利用者設定）を公開契約として名指ししていること。
config_name_ok=1
rg -NF 'work-policy-control.config.yml' "$PB/CONTRACT.md" >/dev/null || config_name_ok=0
rg -NF '~/.config/harness-plugins/work-policy-control.config.yml' "$PB/CONTRACT.md" >/dev/null || config_name_ok=0
[ "$config_name_ok" -eq 1 ] && pass "CONTRACT.mdが利用者設定のファイル名と層を公開" || fail "利用者設定のファイル名・層の公開"

# ── 4. playbookの構造とresolverの複製 ──────────────────────────────────
playbook_ok=1
while IFS= read -r pb; do
  yq -o=json -I=0 '.' "$pb" | jq -e '.version==2 and (.requires|length>0)
    and all(.requires[]; type=="object" and ((keys|sort)==["marketplace","plugin"]) and .marketplace=="agent-work-policy")
    and any(.requires[]; .plugin=="work-policy-control")' >/dev/null || playbook_ok=0
  root=$(dirname "$pb")
  cmp -s "$ROOT/shared/playbook/resolve.sh" "$root/scripts/resolve.sh" || playbook_ok=0
  cmp -s "$ROOT/shared/playbook/resolve-dependency.py" "$root/scripts/resolve-dependency.py" || playbook_ok=0
  cmp -s "$ROOT/shared/playbook/state.py" "$root/scripts/state.py" || playbook_ok=0
done < <(find "$ROOT/plugins/playbooks" -name playbook.yml -type f | sort)
[ "$playbook_ok" -eq 1 ] && pass "playbookの依存宣言（marketplace/pluginのみ）とresolver複製" || fail "playbookの依存宣言またはresolver複製"

prepare_sync=1
while IFS= read -r script; do cmp -s "$ROOT/shared/prepare.sh" "$script" || prepare_sync=0; done < <(find "$ROOT/plugins" -path '*/scripts/prepare.sh' -type f | sort)
resolve_sync=1
while IFS= read -r script; do cmp -s "$ROOT/shared/skill/resolve.sh" "$script" || resolve_sync=0; done < <(find "$ROOT/plugins/skills" -path '*/scripts/resolve.sh' -type f | sort)
[ "$prepare_sync" -eq 1 ] && [ "$resolve_sync" -eq 1 ] && pass "shared prepare / skill resolver同期" || fail "shared prepare / skill resolver同期"
python3 "$ROOT/scripts/sync-runtime.py" --check >/dev/null && pass "runtime複製とmanifestの一致" || fail "runtime複製とmanifestの一致"
# **自repo内の --check だけでは、正本が進んでも緑のままになる。** 兄弟checkoutの正本と
# 突き合わせる。兄弟が無ければ緑にせず失敗させる（CIは兄弟をcheckoutする）。
RUNTIME_SOURCE="$ROOT/../product-planning-plugins/shared/runtime-source"
python3 "$ROOT/scripts/sync-runtime.py" --check --source "$RUNTIME_SOURCE" >/dev/null \
  && pass "正本（兄弟checkout）との一致" \
  || fail "正本（兄弟checkout）と一致しない、または兄弟が無い: $RUNTIME_SOURCE"
# **消費側の文書・script・設定に、外部依存の内部の作りを書かない。** resolverはplaybook.ymlしか
# 見ないので、SKILL.md / README / references / scripts を静的に見るlintを同じ規則で二重に掛ける。
lint_ok=1
for runtime in claude codex; do
  python3 "$ROOT/scripts/lint-consumer-contract.py" --repo "$ROOT" --runtime "$runtime" || lint_ok=0
done
[ "$lint_ok" -eq 1 ] && pass "消費側契約lint（両runtime）" || fail "消費側契約lint"

# ── 5. 両runtimeでplaybookが解決できる ─────────────────────────────────
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/config"
for runtime in claude codex; do
  out="$TMP_ROOT/$runtime.yml"
  if XDG_CONFIG_HOME="$TMP_ROOT/config" HARNESS_PLUGIN_RUNTIME="$runtime" bash "$PB/scripts/resolve.sh" "$TMP_ROOT/repo" > "$out" 2> "$out.err" \
    && yq -o=json -I=0 '.' "$out" | jq -e --arg runtime "$runtime" '
        (.deps|keys)==["work-policy-control"]
        and .deps["work-policy-control"].runtime==$runtime
        and .deps["work-policy-control"].source_kind=="repository"
        and (.deps["work-policy-control"].skills|has("apply-work-policy"))
        and (.playbook.steps|length)==1
        and .playbook.steps[0].skill=="apply-work-policy"' >/dev/null; then
    pass "$runtime playbook resolution（内部pluginをrepositoryから解決）"
  else
    fail "$runtime playbook resolution"
  fi
done

# ── 5.1 契約入力の入口 E1（prepare.sh --input） ────────────────────────
# **CONTRACT.md §1 E1 / §2 を実際に通す。** 合成configではなく本番の経路で、
# 契約入力が解決済みYAMLの .input に載り、契約違反の入力がexit 2で止まることを見る。
mkdir -p "$TMP_ROOT/io/repo"
printf 'body\n' > "$TMP_ROOT/io/body.md"
cat > "$TMP_ROOT/io/input.yml" <<YML
contract: agent-work-policy/agent-work-policy
version: 1
action: pull-request
repo: $TMP_ROOT/io/repo
approved: false
title: "取消の締切を出荷日基準へ"
body_file: $TMP_ROOT/io/body.md
output_to: $TMP_ROOT/io/out.yml
YML
if entry_cfg=$(XDG_CONFIG_HOME="$TMP_ROOT/config" bash "$PB/scripts/prepare.sh" "$ROOT" \
    --input="$TMP_ROOT/io/input.yml" 2> "$TMP_ROOT/io/entry.err"); then
  if yq -o=json -I=0 '.' "$entry_cfg" | jq -e '. as $c
      | $c.input.contract=="agent-work-policy/agent-work-policy" and $c.input.version==1
      and $c.input.action=="pull-request"
      and ($c.input.repo|startswith("/")) and ($c.input.output_to|startswith("/"))
      and ($c.playbook.contract.actions|index($c.input.action)!=null)' >/dev/null; then
    pass "prepare.sh --input が解決済みYAMLの .input へ契約入力を載せる"
  else
    fail "解決済みYAMLの .input が契約入力になっていない"
  fi
  python3 "$PB/scripts/run-config.py" cleanup --config "$entry_cfg" >/dev/null 2>&1 \
    && pass "実行設定の後始末を自分で行える" || fail "実行設定の後始末"
else
  fail "prepare.sh --input が通らない: $(head -3 "$TMP_ROOT/io/entry.err")"
fi
# ── 入口hook validate-input.sh：契約固有schemaは入口で止まる ──────────────
# **共通resolverは contract / version / action / output_to しか見ない。** actionごとの
# 必須キー・そのactionが使わないキー・値の形を入口で止めるのはこのhookだけである。
vinput="$PB/scripts/validate-input.sh"
if bash "$vinput" "$TMP_ROOT/io/input.yml" > "$TMP_ROOT/io/hook.out" 2> "$TMP_ROOT/io/hook.err" \
  && [ ! -s "$TMP_ROOT/io/hook.out" ]; then
  pass "入口hookが契約どおりの入力を受理し、stdoutを使わない"
else
  fail "入口hookが契約どおりの入力を拒否する、またはstdoutを使う: $(head -1 "$TMP_ROOT/io/hook.err")"
fi
# 追加入力の要らないactionと、追加入力のあるactionの両方を通す。
hook_accept() { # hook_accept <名前> <入力YAML>
  local name="$1" dir="$TMP_ROOT/io/ok-$1"
  mkdir -p "$dir"; printf '%s\n' "$2" > "$dir/input.yml"
  bash "$vinput" "$dir/input.yml" >/dev/null 2> "$dir/err" \
    && pass "入口hookが受理する: $name" \
    || fail "入口hookが正しい入力を拒否する: $name ($(head -1 "$dir/err"))"
}
# **inspectは追加入力を取らないread-onlyの照会。** gateが無いので approved も取らない。
hook_accept inspect-no-extra "contract: agent-work-policy/agent-work-policy
version: 1
action: inspect
repo: $TMP_ROOT/io/repo
output_to: $TMP_ROOT/io/out.yml"
hook_accept push-no-extra "contract: agent-work-policy/agent-work-policy
version: 1
action: push
repo: $TMP_ROOT/io/repo
approved: true
output_to: $TMP_ROOT/io/out.yml"
hook_accept commit-with-paths "contract: agent-work-policy/agent-work-policy
version: 1
action: commit
repo: $TMP_ROOT/io/repo
approved: false
paths: [src/order/cancel.py]
message: 取消の締切を出荷日基準へ揃える
output_to: $TMP_ROOT/io/out.yml"
hook_accept merge-with-pr "contract: agent-work-policy/agent-work-policy
version: 1
action: merge
repo: $TMP_ROOT/io/repo
approved: true
pr: 1234
output_to: $TMP_ROOT/io/out.yml"
hook_reject() { # hook_reject <名前> <入力YAML>
  local name="$1" dir="$TMP_ROOT/io/hook-$1"
  mkdir -p "$dir"; printf '%s\n' "$2" > "$dir/input.yml"
  if bash "$vinput" "$dir/input.yml" >/dev/null 2> "$dir/err"; then
    fail "契約違反の入力を入口hookが受け入れている: $name"
  elif ! rg -N '^\[error:input-schema\] ' "$dir/err" >/dev/null; then
    fail "入口hookの診断が [error:input-schema] key=value でない: $name ($(head -1 "$dir/err"))"
  elif [ "$(wc -l < "$dir/err")" -ne 1 ]; then
    fail "入口hookの診断が1行でない: $name"
  elif XDG_CONFIG_HOME="$TMP_ROOT/config" bash "$PB/scripts/prepare.sh" "$ROOT" \
      --input="$dir/input.yml" >/dev/null 2> "$dir/e1.err"; then
    fail "契約違反の入力をE1が受け入れている: $name"
  elif rg -NF '[error:input-schema]' "$dir/e1.err" >/dev/null; then
    pass "契約違反の入力を入口hookとE1が拒否する: $name"
  else
    fail "E1が契約固有schema違反を期待した理由で拒否できない: $name ($(head -1 "$dir/e1.err"))"
  fi
}
hook_reject inspect-approved "contract: agent-work-policy/agent-work-policy
version: 1
action: inspect
repo: $TMP_ROOT/io/repo
approved: true
output_to: $TMP_ROOT/io/out.yml"
hook_reject inspect-branch "contract: agent-work-policy/agent-work-policy
version: 1
action: inspect
repo: $TMP_ROOT/io/repo
branch: agent/x
output_to: $TMP_ROOT/io/out.yml"
hook_reject missing-required "contract: agent-work-policy/agent-work-policy
version: 1
action: commit
repo: $TMP_ROOT/io/repo
paths: [src/a.py]
output_to: $TMP_ROOT/io/out.yml"
hook_reject key-for-other-action "contract: agent-work-policy/agent-work-policy
version: 1
action: push
repo: $TMP_ROOT/io/repo
title: 取消の締切を出荷日基準へ
output_to: $TMP_ROOT/io/out.yml"
hook_reject unknown-key "contract: agent-work-policy/agent-work-policy
version: 1
action: push
repo: $TMP_ROOT/io/repo
verify: true
output_to: $TMP_ROOT/io/out.yml"
hook_reject approved-not-bool "contract: agent-work-policy/agent-work-policy
version: 1
action: push
repo: $TMP_ROOT/io/repo
approved: \"true\"
output_to: $TMP_ROOT/io/out.yml"
hook_reject pr-not-int "contract: agent-work-policy/agent-work-policy
version: 1
action: merge
repo: $TMP_ROOT/io/repo
pr: \"1234\"
output_to: $TMP_ROOT/io/out.yml"
hook_reject paths-escape "contract: agent-work-policy/agent-work-policy
version: 1
action: commit
repo: $TMP_ROOT/io/repo
paths: [../outside.py]
message: m
output_to: $TMP_ROOT/io/out.yml"
hook_reject body-file-missing "contract: agent-work-policy/agent-work-policy
version: 1
action: pull-request
repo: $TMP_ROOT/io/repo
title: t
body_file: $TMP_ROOT/io/absent.md
output_to: $TMP_ROOT/io/out.yml"
# **祖先にsymlinkを含む入力pathを拒否しない。** macOS既定のTMPDIRがその形なので、
# 拒否すると消費側が素直に書いた入力が必ず落ちる。output_to は正規化されて載る。
mkdir -p "$TMP_ROOT/io/real"; ln -s "$TMP_ROOT/io/real" "$TMP_ROOT/io/linked"
sed "s|^output_to: .*|output_to: $TMP_ROOT/io/linked/out.yml|" "$TMP_ROOT/io/input.yml" \
  > "$TMP_ROOT/io/linked/input.yml"
real_io=$(cd "$TMP_ROOT/io/real" && pwd -P)
if sym_cfg=$(XDG_CONFIG_HOME="$TMP_ROOT/config" bash "$PB/scripts/prepare.sh" "$ROOT" \
    --input="$TMP_ROOT/io/linked/input.yml" 2> "$TMP_ROOT/io/sym.err") \
  && yq -o=json -I=0 '.' "$sym_cfg" | jq -e --arg real "$real_io" '.input.output_to == ($real + "/out.yml")' >/dev/null; then
  pass "祖先がsymlinkの入力pathを受け、output_toを正規化して載せる"
  python3 "$PB/scripts/run-config.py" cleanup --config "$sym_cfg" >/dev/null 2>&1
else
  fail "祖先にsymlinkを含む入力pathをE1が拒否する: $(head -1 "$TMP_ROOT/io/sym.err")"
fi

reject_input() { # reject_input <名前> <期待コード片> <sed式>
  local name="$1" expected="$2" edit="$3" dir="$TMP_ROOT/io/neg-$1"
  mkdir -p "$dir"
  sed "$edit" "$TMP_ROOT/io/input.yml" > "$dir/input.yml"
  if XDG_CONFIG_HOME="$TMP_ROOT/config" bash "$PB/scripts/prepare.sh" "$ROOT" \
      --input="$dir/input.yml" >/dev/null 2> "$dir/err"; then
    fail "契約違反の入力を入口が受け入れている: $name"
  elif rg -NF "$expected" "$dir/err" >/dev/null; then
    pass "契約違反の入力を入口が拒否する: $name"
  else
    fail "契約違反の入力を期待した理由で拒否できない: $name ($(head -1 "$dir/err"))"
  fi
}
reject_input "unknown-action" "[error:input-capability-unsupported]" 's|^action: .*|action: verify|'
reject_input "wrong-contract" "[error:input-contract-mismatch]" 's|^contract: .*|contract: grill/grill|'
reject_input "relative-output" "[error:input-output-unwritable]" 's|^output_to: .*|output_to: ./out.yml|'

# ── 6. 負の試験 ────────────────────────────────────────────────────────
COPY="$TMP_ROOT/copy"
mkdir -p "$COPY"
cp -R "$ROOT/plugins" "$ROOT/.claude-plugin" "$ROOT/.agents" "$COPY/"
COPY_PB="$COPY/plugins/playbooks/automation/agent-work-policy"
cp "$COPY_PB/playbook.yml" "$TMP_ROOT/base.yml"
negative() {
  local name="$1" expected="$2"
  local err="$TMP_ROOT/negative-$name.err"
  if XDG_CONFIG_HOME="$TMP_ROOT/config" HARNESS_PLUGIN_RUNTIME=codex bash "$COPY_PB/scripts/resolve.sh" "$TMP_ROOT/repo" >/dev/null 2> "$err"; then
    fail "負例($name)を拒否できない"
  elif rg -NF "$expected" "$err" >/dev/null; then
    pass "負例($name)を拒否する"
  else
    fail "負例($name)を期待した理由で拒否できない"
  fi
  cp "$TMP_ROOT/base.yml" "$COPY_PB/playbook.yml"
}
yq -o=json -I=0 '.' "$TMP_ROOT/base.yml" | jq '.requires[0].version="1.0.0"' | yq -P > "$COPY_PB/playbook.yml"
negative "requires-version-pin" "playbookのschema"
yq -o=json -I=0 '.' "$TMP_ROOT/base.yml" | jq '.requires[0].plugin="absent-internal-plugin"' | yq -P > "$COPY_PB/playbook.yml"
negative "unresolvable-dependency" "[error:dependency-"
# 工程が指すskillの実在検査はresolverが持つ。固有validatorを外して単独で確かめる。
cp "$COPY_PB/scripts/validate-config.sh" "$TMP_ROOT/validate-config.sh"
sed 's/apply-work-policy/unknown-step-skill/' "$TMP_ROOT/validate-config.sh" > "$COPY_PB/scripts/validate-config.sh"
yq -o=json -I=0 '.' "$TMP_ROOT/base.yml" | jq '.steps[0].skill="unknown-step-skill"' | yq -P > "$COPY_PB/playbook.yml"
negative "unknown-skill" "steps が指すスキルが requires のプラグインに無い: unknown-step-skill"
cp "$TMP_ROOT/validate-config.sh" "$COPY_PB/scripts/validate-config.sh"
yq -o=json -I=0 '.' "$TMP_ROOT/base.yml" | jq '.contract.actions=["pull_request"]' | yq -P > "$COPY_PB/playbook.yml"
negative "action-not-kebab-case" "contract.actionsは非空のkebab-case文字列配列にする"
yq -o=json -I=0 '.' "$TMP_ROOT/base.yml" | jq '.steps=[.steps[0],(.steps[0]|.id="apply2")]' | yq -P > "$COPY_PB/playbook.yml"
negative "multiple-actions-per-call" "1呼び出し1action"
yq -o=json -I=0 '.' "$TMP_ROOT/base.yml" | jq '.contract.contract_version=2' | yq -P > "$COPY_PB/playbook.yml"
negative "contract-version" "契約IDと契約版はagent-work-policy/agent-work-policyのv1に固定する"

# 外部pluginが内部skillを直接掴めないこと（公開面はplaybookだけ）
if [ -f "$COPY/plugins/skills/automation/work-policy-control/playbook.yml" ]; then
  fail "内部pluginがplaybook面を公開している"
else
  pass "内部pluginは公開playbook面を持たない"
fi

# ── 6.05 inspect は read-only の照会である ───────────────────────────────
# **planと役割を混ぜない。** planは新規作業の開始判定なので既存branchやdirtyで止まる。
# inspectは現況を返すだけなので、同じ状況で止まってはならない。
INTERNAL_SCRIPTS="$INTERNAL/scripts"
inspect_repo="$TMP_ROOT/inspect-repo"
mkdir -p "$inspect_repo"
git -C "$inspect_repo" init -q
git -C "$inspect_repo" symbolic-ref HEAD refs/heads/main
printf 'a\n' > "$inspect_repo/a.txt"
git -C "$inspect_repo" add a.txt
git -C "$inspect_repo" -c user.email=t@example.invalid -c user.name=t commit -qm init
git -C "$inspect_repo" switch -qc agent/existing
printf 'dirty\n' > "$inspect_repo/b.txt"
if inspect_cfg=$(XDG_CONFIG_HOME="$TMP_ROOT/config" bash "$INTERNAL_SCRIPTS/prepare.sh" "$inspect_repo" 2>/dev/null); then
  if python3 "$INTERNAL_SCRIPTS/control.py" inspect --config "$inspect_cfg" --repo "$inspect_repo" \
      > "$TMP_ROOT/inspect.json" 2> "$TMP_ROOT/inspect.err" \
    && jq -e '.status=="inspected" and .clean==false and .branch=="agent/existing"
              and .base_branch_exists==true and (has("worktree")) and (has("pull_request"))
              and (.remote|type=="string") and (.draft|type=="boolean")' "$TMP_ROOT/inspect.json" >/dev/null; then
    pass "inspectは既存branch・dirtyでも止まらず現況を返す"
  else
    fail "inspectが現況を返さない: $(head -1 "$TMP_ROOT/inspect.err")"
  fi
  # 同じ状況で plan は止まる。役割が分かれていることを見る。
  if python3 "$INTERNAL_SCRIPTS/control.py" plan --config "$inspect_cfg" --repo "$inspect_repo" \
      --branch agent/new >/dev/null 2>&1; then
    fail "planが汚れたworking treeで止まらない（inspectと役割が同じになっている）"
  else
    pass "planは同じ状況で止まる（inspectと役割が分かれている）"
  fi
  rm -f "$inspect_cfg"
else
  fail "inspect試験用の実行設定を解決できない"
fi

# ── 6.1 消費側から見た公開面 — 実際の配布物に対して解決する ────────────────
# fixtureは「agent-work-policyを外部依存として要求する別marketplaceのplaybook」。
# **配布物 plugins/ をそのままinstalled-cacheへ写す。** 手書きのbare manifestを置くと
# metadata.harness が欠けて external-dependency-no-playbook になり、実体と乖離する。
consumer="$TMP_ROOT/consumer"
cpb="$consumer/plugins/playbooks/probe/probe"
mkdir -p "$cpb/scripts" "$cpb/.claude-plugin" "$cpb/.codex-plugin" \
  "$consumer/plugins/.claude-plugin" "$consumer/plugins/.codex-plugin"
git -C "$consumer" init -q
cache="$cpb/.harness-plugin-test-cache/agent-work-policy/agent-work-policy/2.0.0"
mkdir -p "$(dirname "$cache")"
cp -R "$ROOT/plugins" "$cache"
for runtime in claude codex; do
  cat > "$cpb/.${runtime}-plugin/plugin.json" <<'JSON'
{"name":"probe","version":"1.0.0","description":"fixture","skills":"./","metadata":{"harness":{"contractVersion":1}}}
JSON
  cat > "$consumer/plugins/.${runtime}-plugin/plugin.json" <<'JSON'
{"name":"probe","version":"1.0.0","description":"fixture","skills":["./playbooks/probe/probe"],
 "metadata":{"harness":{"installationSurface":"playbook-package","marketplace":"probe",
 "entryRoot":"./playbooks/probe/probe","playbooks":{"probe":"./playbooks/probe/probe"},
 "internalPlugins":{},"contractVersion":1,
 "implements":[{"id":"probe/probe","version":1,"kind":"playbook","playbook":"probe"}]}}}
JSON
done
printf -- '---\nname: probe\ndescription: fixture\n---\nfixture\n' > "$cpb/SKILL.md"
cp "$ROOT/shared/prepare.sh" "$cpb/scripts/prepare.sh"
cp "$ROOT/shared/run-config.py" "$cpb/scripts/run-config.py"
cp "$ROOT/shared/playbook/resolve.sh" "$cpb/scripts/resolve.sh"
cp "$ROOT/shared/playbook/resolve-dependency.py" "$cpb/scripts/resolve-dependency.py"
cp "$ROOT/shared/playbook/state.py" "$cpb/scripts/state.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "$cpb/scripts/validate-config.sh"
chmod 755 "$cpb/scripts"/*
probe_playbook() { # probe_playbook <requires plugin> <step種別> [action]
  cat > "$cpb/playbook.yml" <<YML
version: 2
name: probe
description: fixture
instructions:
  execution:
    directive: fixture
requires:
  - {plugin: $1, marketplace: agent-work-policy}
steps:
  - id: apply
    $2: $1
    input:
      action: ${3:-pull-request}
    purpose: fixture
    provides: [action_result]
YML
}
probe_run() { HARNESS_PLUGIN_CACHE_ROOT="$cpb/.harness-plugin-test-cache" \
  XDG_CONFIG_HOME="$TMP_ROOT/config" bash "$cpb/scripts/resolve.sh" "$consumer" 2> "$TMP_ROOT/probe.err"; }

# (a) 公開playbookは外部から解決でき、公開面は入口SKILL.md 1枚だけである。
probe_playbook agent-work-policy playbook
if ! probe_run > "$TMP_ROOT/probe.yml"; then
  fail "配布物のagent-work-policyを外部依存として解決できない: $(head -3 "$TMP_ROOT/probe.err")"
else
  entry_skill_name=$(rg -N -m1 '^name: (.+)$' -r '$1' "$PB/SKILL.md")
  # **契約面は entry と entry_skill である。** entry は入口SKILL.mdの実path、
  # entry_skill はその frontmatter name（表示用。名前で分岐しない）。
  if yq -o=json -I=0 '.' "$TMP_ROOT/probe.yml" | jq -e --arg skill "$entry_skill_name" '
      .deps["agent-work-policy"].dependency_scope=="external"
      and .deps["agent-work-policy"].contract=="agent-work-policy/agent-work-policy"
      and ((.deps["agent-work-policy"].implements
            | map(select(.id=="agent-work-policy/agent-work-policy" and .version==1 and .kind=="playbook"))
            | length)==1)
      and .deps["agent-work-policy"].entry_skill==$skill
      and (.deps["agent-work-policy"].entry|test("/playbooks/automation/agent-work-policy/SKILL.md$"))' >/dev/null; then
    pass "外部から見える公開面は entry（入口SKILL.md）1枚、entry_skill=${entry_skill_name}"
  else
    fail "外部から見えるagent-work-policyの公開面（entry / entry_skill）が契約どおりでない"
  fi
  entry_ok_probe=1
  root=$(yq -er '.deps["agent-work-policy"].root' "$TMP_ROOT/probe.yml")
  for entry in playbook.yml SKILL.md scripts/resolve.sh scripts/prepare.sh; do
    [ -f "$root/$entry" ] || entry_ok_probe=0
  done
  [ "$entry_ok_probe" -eq 1 ] && pass "公開入口4点が解決先に揃っている" || fail "公開入口4点が解決先に無い"
fi

# (b) 内部pluginを外部から指定しても解決しない。
probe_playbook work-policy-control playbook
if probe_run >/dev/null; then
  fail "外部repositoryから内部plugin（work-policy-control）が解決できてしまう"
elif rg -NF 'dependency-' "$TMP_ROOT/probe.err" >/dev/null; then
  pass "内部pluginの外部指定を拒否する"
else
  fail "内部pluginの外部指定を期待した理由で拒否できない: $(head -1 "$TMP_ROOT/probe.err")"
fi

# (c) 外部依存を skill: で掴めない（最上位規則の機械的強制）。
# **公開skill名（入口SKILL.mdのname）で掴もうとしても落ちる。** playbook名で指すと
# 「requiresのpluginに無いskill」で落ちてしまい、この規則そのものを試験できない。
cat > "$cpb/playbook.yml" <<YML
version: 2
name: probe
description: fixture
instructions:
  execution:
    directive: fixture
requires:
  - {plugin: agent-work-policy, marketplace: agent-work-policy}
steps:
  - id: apply
    skill: $(rg -N -m1 '^name: (.+)$' -r '$1' "$PB/SKILL.md")
    purpose: fixture
    provides: [action_result]
YML
if probe_run >/dev/null; then
  fail "外部依存のagent-work-policyを skill: step で呼べてしまう"
elif rg -NF 'external-dependency-skill' "$TMP_ROOT/probe.err" >/dev/null; then
  pass "外部依存の skill: 参照を拒否する"
else
  fail "外部skill参照を期待した理由で拒否できない: $(head -1 "$TMP_ROOT/probe.err")"
fi

# (d) 宣言に無いactionを steps[].input で要求したら、解決の時点で止まる。
probe_playbook agent-work-policy playbook verify
if probe_run >/dev/null; then
  fail "implementsに無いactionを steps[].input で要求できてしまう"
elif rg -NF 'binding-capability-unsupported' "$TMP_ROOT/probe.err" >/dev/null; then
  pass "implementsに無いactionの要求を拒否する"
else
  fail "未宣言actionの要求を期待した理由で拒否できない: $(head -1 "$TMP_ROOT/probe.err")"
fi

# ── 7. 構文と既存の契約試験 ────────────────────────────────────────────
syntax_failed=0
while IFS= read -r script; do bash -n "$script" || syntax_failed=1; done < <(find "$ROOT" -type f -name '*.sh' | sort)
[ "$syntax_failed" -eq 0 ] && pass "shell構文" || fail "shell構文"
python_failed=0
while IFS= read -r script; do PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$script" || python_failed=1; done < <(find "$ROOT" -type f -name '*.py' | sort)
[ "$python_failed" -eq 0 ] && pass "Python構文" || fail "Python構文"

bash "$ROOT/tests/publication-authority-contract.sh" && pass "公開操作の停止契約" || fail "公開操作の停止契約"
bash "$ROOT/tests/license-contract.sh" && pass "LICENSE契約" || fail "LICENSE契約"
bash "$ROOT/tests/secret-scanning-contract.sh" && pass "secret scanning契約" || fail "secret scanning契約"

printf '\nValidation: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
