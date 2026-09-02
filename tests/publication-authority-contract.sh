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
if [ "${FAKE_GH_MODE:-failed}" = failed ]; then
  echo 'fixture gh failure' >&2
  exit 1
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
  printf '%s\n' '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"agent/delegate","headRefOid":"fixture-sha","baseRefName":"main","statusCheckRollup":[],"reviews":[],"url":"https://example.invalid/pr/1"}'
elif [ "$1" = repo ] && [ "$2" = view ]; then
  printf '%s\n' '{"nameWithOwner":"fixture/repository"}'
elif [ "$1" = api ] && [[ " $* " == *' graphql '* ]]; then
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
elif [ "$1" = api ] && [[ " $* " == *' --method '* ]]; then
  printf '%s\n' '{"merged":false,"message":"fixture merge failure"}'
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

if [ "$FAIL" -eq 0 ]; then
  echo "Publication authority contract: passed"
else
  echo "Publication authority contract: failed" >&2
fi
exit "$FAIL"
