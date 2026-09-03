#!/usr/bin/env bash
# BDD fixture: downstream plugin delegates publication decisions to agent-work-policy.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN="$ROOT/plugins/skills/automation/agent-work-policy"
FIXTURE="$ROOT/tests/fixtures/publication-authority-contract.yml"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/publication-authority-contract.XXXXXX") || exit 2
CFG=""
trap 'rm -f "$CFG"; rm -rf "$TMP"' EXIT
FAIL=0

ok() { echo "  ok: $1"; }
ng() { echo "  NG: $1" >&2; FAIL=1; }
expect_json() {
  local expected_exit="$1" expected_status="$2"
  shift 2
  local output exit_code
  output=$("$@" 2>"$TMP/stderr")
  exit_code=$?
  if [ "$exit_code" -ne "$expected_exit" ]; then
    ng "$* exits $exit_code, expected $expected_exit"
    return
  fi
  if jq -e --arg status "$expected_status" '.status == $status' <<<"$output" >/dev/null; then
    ok "$expected_status (exit $expected_exit)"
  else
    ng "$* does not return status=$expected_status"
  fi
}

echo "Scenario: 下流pluginは設定を解決して公開判断を委譲する"
if [ "$(rg -c --no-filename 'pull-request-state' "$PLUGIN/scripts/control.py")" -eq 1 ]; then
  ok "PR状態の取得は単一helperに集約されている"
else
  ng "PR状態の取得が複数箇所に分散している"
fi
echo "  Given 公開先repositoryとagent-work-policy設定fixtureがある"
mkdir -p "$TMP/repository/.harness-plugins"
cp "$FIXTURE" "$TMP/repository/.harness-plugins/agent-work-policy.config.yml"
git -C "$TMP/repository" init -q -b main
git -C "$TMP/repository" config user.email fixture@example.invalid
git -C "$TMP/repository" config user.name fixture
touch "$TMP/repository/tracked"
git -C "$TMP/repository" add tracked
git -C "$TMP/repository" commit -qm initial
git -C "$TMP/repository" switch -qc agent/delegate
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ -n "${FAKE_GH_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_GH_LOG"
fi
if [ "${FAKE_GH_MODE:-failed}" = failed ]; then
  echo 'fixture gh failure' >&2
  exit 1
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
  printf '{"number":1,"isDraft":%s,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"%s","headRefOid":"fixture-sha","baseRefName":"%s","statusCheckRollup":[],"reviews":[],"url":"https://example.invalid/pr/1"}\n' "${FAKE_PR_DRAFT:-false}" "${FAKE_PR_HEAD:-agent/delegate}" "${FAKE_PR_BASE:-main}"
elif [ "$1" = pr ] && [ "$2" = ready ]; then
  printf '%s\n' 'https://example.invalid/pr/1'
elif [ "$1" = repo ] && [ "$2" = view ]; then
  printf '%s\n' '{"nameWithOwner":"fixture/repository"}'
elif [ "$1" = api ] && [[ " $* " == *' graphql '* ]]; then
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
elif [ "$1" = api ] && [[ " $* " == *' --method '* ]]; then
  if [ "${FAKE_GH_MODE:-}" = merged ]; then
    if [ -n "${FAKE_REMOTE_DELETE_REF:-}" ]; then
      git --git-dir "$FAKE_REMOTE_DELETE_REF" update-ref -d refs/heads/agent/delegate
    fi
    printf '%s\n' '{"merged":true,"sha":"fixture-merge-sha"}'
  else
    printf '%s\n' '{"merged":false,"message":"fixture merge failure"}'
  fi
else
  echo 'unexpected fixture gh invocation' >&2
  exit 1
fi
EOF
chmod +x "$TMP/bin/gh"

echo "  When prepare.shが設定を解決し、control.pyへ渡す"
CFG=$(bash "$PLUGIN/scripts/prepare.sh" "$TMP/repository") || { ng "prepare.sh resolves config"; exit 1; }
if yq -e '.repo_root and .plugin_root and .permissions.pull_request == true' "$CFG" >/dev/null; then
  ok "prepare.sh returns a resolved config path"
else
  ng "resolved config is incomplete"
fi
expect_json 0 allowed python3 "$PLUGIN/scripts/control.py" permission --config "$CFG" --action pull_request
expect_json 3 forbidden python3 "$PLUGIN/scripts/control.py" permission --config "$CFG" --action merge
expect_json 3 waiting_for_human python3 "$PLUGIN/scripts/control.py" gate --config "$CFG" --action push
expect_json 0 approved python3 "$PLUGIN/scripts/control.py" gate --config "$CFG" --action push --approved

echo "  Then commit前検証とhuman gateは正本が返し、下流pluginはcommitしない"
printf 'change\n' >> "$TMP/repository/tracked"
printf 'tracked\n' > "$TMP/paths.txt"
output=$(python3 "$PLUGIN/scripts/control.py" commit --config "$CFG" --repo "$TMP/repository" --paths-file "$TMP/paths.txt" --message fixture 2>"$TMP/stderr")
exit_code=$?
if [ "$exit_code" -eq 3 ] && jq -e '.status == "waiting_for_human" and .context.verification == [{"command":"git diff --check","exit_code":0}]' <<<"$output" >/dev/null; then
  ok "commit verification and gate are delegated"
else
  ng "commit verification or gate contract"
fi
if git -C "$TMP/repository" diff --quiet --cached; then
  ok "unapproved delegation does not stage or commit"
else
  ng "unapproved delegation staged changes"
fi

echo "  And pushとPR作成はgate待ちの後、実行失敗をJSONで返す"
expect_json 3 waiting_for_human python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository"
expect_json 3 failed python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository" --approved
printf 'fixture body\n' > "$TMP/body.md"
expect_json 3 waiting_for_human python3 "$PLUGIN/scripts/control.py" pull-request --config "$CFG" --repo "$TMP/repository" --title fixture --body-file "$TMP/body.md"
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=failed python3 "$PLUGIN/scripts/control.py" pull-request --config "$CFG" --repo "$TMP/repository" --title fixture --body-file "$TMP/body.md" --approved

echo "  And ready-for-reviewはpull_request permissionと既存PR境界を再利用して冪等に公開する"
: > "$TMP/gh.log"
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=ready FAKE_PR_DRAFT=true python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1 2>"$TMP/stderr")
exit_code=$?
if [ "$exit_code" -eq 0 ] && jq -e '.status == "ready" and .changed == true' <<<"$output" >/dev/null && rg -qx 'pr ready 1' "$TMP/gh.log"; then
  ok "draft PR is made ready for review"
else
  ng "draft PR ready-for-review contract"
fi
: > "$TMP/gh.log"
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=ready FAKE_PR_DRAFT=false python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1 2>"$TMP/stderr")
exit_code=$?
if [ "$exit_code" -eq 0 ] && jq -e '.status == "ready" and .changed == false' <<<"$output" >/dev/null && ! rg -q '^pr ready ' "$TMP/gh.log"; then
  ok "ready PR is unchanged"
else
  ng "ready PR idempotency contract"
fi
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=failed python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_DRAFT=true python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 2
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_DRAFT=true FAKE_PR_HEAD=agent/other python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_DRAFT=true FAKE_PR_BASE=other python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1
cp "$FIXTURE" "$TMP/repository/.harness-plugins/pull-request-disabled.yml"
yq -i '.permissions.pull_request = false' "$TMP/repository/.harness-plugins/pull-request-disabled.yml"
mkdir -p "$TMP/pull-request-disabled/.harness-plugins"
cp "$TMP/repository/.harness-plugins/pull-request-disabled.yml" "$TMP/pull-request-disabled/.harness-plugins/agent-work-policy.config.yml"
git -C "$TMP/pull-request-disabled" init -q -b main
git -C "$TMP/pull-request-disabled" config user.email fixture@example.invalid
git -C "$TMP/pull-request-disabled" config user.name fixture
touch "$TMP/pull-request-disabled/tracked"
git -C "$TMP/pull-request-disabled" add tracked
git -C "$TMP/pull-request-disabled" commit -qm initial
git -C "$TMP/pull-request-disabled" switch -qc agent/delegate
CFG_DISABLED=$(bash "$PLUGIN/scripts/prepare.sh" "$TMP/pull-request-disabled") || { ng "pull-request-disabled config resolves"; exit 1; }
expect_json 3 forbidden python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG_DISABLED" --repo "$TMP/pull-request-disabled" --pr 1
rm -f "$CFG_DISABLED"

echo "  And merge-readinessとmergeはforbidden・gate待ち・失敗を区別する"
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=failed python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG" --repo "$TMP/repository" --pr 1
expect_json 3 forbidden python3 "$PLUGIN/scripts/control.py" merge --config "$CFG" --repo "$TMP/repository" --pr 1
cp "$FIXTURE" "$TMP/repository/.harness-plugins/merge-enabled.yml"
yq -i '.permissions.merge = true' "$TMP/repository/.harness-plugins/merge-enabled.yml"
yq -i '.merge.readiness.min_approvals = 0' "$TMP/repository/.harness-plugins/merge-enabled.yml"
mkdir -p "$TMP/merge-enabled/.harness-plugins"
cp "$TMP/repository/.harness-plugins/merge-enabled.yml" "$TMP/merge-enabled/.harness-plugins/agent-work-policy.config.yml"
git -C "$TMP/merge-enabled" init -q -b main
git -C "$TMP/merge-enabled" config user.email fixture@example.invalid
git -C "$TMP/merge-enabled" config user.name fixture
touch "$TMP/merge-enabled/tracked"
git -C "$TMP/merge-enabled" add tracked
git -C "$TMP/merge-enabled" commit -qm initial
git -C "$TMP/merge-enabled" switch -qc agent/delegate
CFG_MERGE=$(bash "$PLUGIN/scripts/prepare.sh" "$TMP/merge-enabled") || { ng "merge-enabled config resolves"; exit 1; }
expect_json 3 waiting_for_human env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" merge --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" merge --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 --approved
rm -f "$CFG_MERGE"

echo "  And merge後にremote branchが既に無ければcleanupは冪等に成功する"
cp "$FIXTURE" "$TMP/repository/.harness-plugins/merge-cleanup.yml"
yq -i '.permissions.merge = true' "$TMP/repository/.harness-plugins/merge-cleanup.yml"
yq -i '.gates.before_merge = false' "$TMP/repository/.harness-plugins/merge-cleanup.yml"
yq -i '.merge.delete_branch = true' "$TMP/repository/.harness-plugins/merge-cleanup.yml"
yq -i '.merge.readiness.min_approvals = 0' "$TMP/repository/.harness-plugins/merge-cleanup.yml"
git init -q --bare "$TMP/remote.git"
mkdir -p "$TMP/merge-cleanup/.harness-plugins"
cp "$TMP/repository/.harness-plugins/merge-cleanup.yml" "$TMP/merge-cleanup/.harness-plugins/agent-work-policy.config.yml"
git -C "$TMP/merge-cleanup" init -q -b main
git -C "$TMP/merge-cleanup" config user.email fixture@example.invalid
git -C "$TMP/merge-cleanup" config user.name fixture
touch "$TMP/merge-cleanup/tracked"
git -C "$TMP/merge-cleanup" add tracked
git -C "$TMP/merge-cleanup" commit -qm initial
git -C "$TMP/merge-cleanup" switch -qc agent/delegate
git -C "$TMP/merge-cleanup" remote add origin "$TMP/remote.git"
git -C "$TMP/merge-cleanup" push -q origin main agent/delegate
CFG_CLEANUP=$(bash "$PLUGIN/scripts/prepare.sh" "$TMP/merge-cleanup") || { ng "merge-cleanup config resolves"; exit 1; }
expect_json 0 merged env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=merged FAKE_REMOTE_DELETE_REF="$TMP/remote.git" python3 "$PLUGIN/scripts/control.py" merge --config "$CFG_CLEANUP" --repo "$TMP/merge-cleanup" --pr 1
if git --git-dir "$TMP/remote.git" show-ref --verify --quiet refs/heads/agent/delegate; then
  ng "already absent remote branch remains"
else
  ok "already absent remote branch is successful cleanup"
fi

echo "  But remote照会の通信・権限相当エラーはcleanup失敗のまま返す"
git -C "$TMP/merge-cleanup" remote set-url origin "$TMP/missing-remote.git"
expect_json 3 merged_cleanup_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=merged python3 "$PLUGIN/scripts/control.py" merge --config "$CFG_CLEANUP" --repo "$TMP/merge-cleanup" --pr 1
rm -f "$CFG_CLEANUP"

if [ "$FAIL" -eq 0 ]; then
  echo "Publication authority contract: passed"
else
  echo "Publication authority contract: failed" >&2
fi
exit "$FAIL"
