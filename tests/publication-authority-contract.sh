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
    ng "$* exits $exit_code, expected $expected_exit: $output"
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
git init -q --bare "$TMP/repository-origin.git"
git -C "$TMP/repository" remote add origin "$TMP/repository-origin.git"
git -C "$TMP/repository" push -q origin main agent/delegate
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ -n "${FAKE_GH_LOG:-}" ]; then
  log_line=${*//$'\n'/ }
  printf '%s\n' "$log_line" >> "$FAKE_GH_LOG"
fi
if [ "${FAKE_GH_MODE:-failed}" = failed ]; then
  echo 'fixture gh failure' >&2
  exit 1
fi
if [ "$1" = pr ]; then
  target_repo=''
  previous=''
  for arg in "$@"; do
    if [ "$previous" = --repo ]; then target_repo=$arg; fi
    previous=$arg
  done
  if [ "$target_repo" != "${FAKE_EXPECT_REPO:-fixture/repository}" ]; then
    echo "fixture rejected unfixed PR repository: $target_repo" >&2
    exit 1
  fi
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
  state="${FAKE_PR_STATE:-OPEN}"
  draft="${FAKE_PR_DRAFT:-false}"
  mergeable="${FAKE_PR_MERGEABLE:-MERGEABLE}"
  merge_state="${FAKE_PR_MERGE_STATE:-CLEAN}"
  reviews="${FAKE_REVIEWS_JSON:-[]}"
  merged_at=null
  if [ "$state" = MERGED ]; then
    merged_at='"2026-09-03T00:00:00Z"'
  fi
  base_sha="${FAKE_PR_BASE_SHA:-$(git rev-parse main 2>/dev/null || printf 'fixture-base-sha')}"
  view_count=0
  if [ -n "${FAKE_VIEW_COUNT:-}" ]; then
    count=$(cat "$FAKE_VIEW_COUNT" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_VIEW_COUNT"
    view_count=$count
  fi
  if [ "${FAKE_GH_MODE:-}" = advance-base-on-second-view ]; then
    if [ "$count" -eq 2 ]; then
      git --git-dir "$FAKE_REMOTE" update-ref "refs/heads/${FAKE_PR_BASE:-main}" "$FAKE_ADVANCED_BASE"
    fi
  fi
  if [ "${FAKE_GH_MODE:-}" = fast-forward ] || [ "${FAKE_GH_MODE:-}" = fast-forward-unreflected ]; then
    remote_base=$(git --git-dir "$FAKE_REMOTE" rev-parse "refs/heads/${FAKE_PR_BASE:-main}" 2>/dev/null || true)
    if [ "${FAKE_GH_MODE:-}" = fast-forward ] && [ "$remote_base" = "${FAKE_PR_HEAD_SHA:-fixture-sha}" ]; then
      state=MERGED
      merged_at='"2026-09-03T00:00:00Z"'
    fi
  fi
  checks=${FAKE_CHECKS_JSON:-'[{"name":"gitleaks","conclusion":"SUCCESS","status":"COMPLETED"},{"name":"trufflehog","conclusion":"SUCCESS","status":"COMPLETED"}]'}
  head_sha="${FAKE_PR_HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || printf 'fixture-sha')}"
  head_branch="${FAKE_PR_HEAD:-agent/delegate}"
  base_branch="${FAKE_PR_BASE:-main}"
  head_owner="${FAKE_PR_HEAD_OWNER:-fixture}"
  head_repo="${FAKE_PR_HEAD_REPO:-fixture/repository}"
  if [ "$view_count" -eq "${FAKE_CHANGE_VIEW:-2}" ]; then
    case "${FAKE_GH_MODE:-}" in
      second-view-closed) state=CLOSED ;;
      second-view-head-changed) head_sha="${FAKE_SECOND_HEAD_SHA:-changed-head-sha}" ;;
      second-view-base-changed) base_sha="${FAKE_SECOND_BASE_SHA:-changed-base-sha}" ;;
      second-view-check-failed) checks='[{"name":"gitleaks","conclusion":"FAILURE","status":"COMPLETED"},{"name":"trufflehog","conclusion":"SUCCESS","status":"COMPLETED"}]' ;;
      second-view-draft) draft=true ;;
      second-view-unmergeable) mergeable=CONFLICTING ;;
      second-view-unstable) merge_state=UNSTABLE ;;
      second-view-approval-lost) reviews='[]' ;;
      second-view-head-retarget) head_branch=agent/retargeted ;;
      second-view-base-retarget) base_branch=other ;;
      second-view-repository-changed) head_owner=other; head_repo=other/repository ;;
    esac
  fi
  printf '{"number":1,"state":"%s","mergedAt":%s,"isDraft":%s,"mergeable":"%s","mergeStateStatus":"%s","headRefName":"%s","headRefOid":"%s","headRepositoryOwner":{"login":"%s"},"headRepository":{"nameWithOwner":"%s"},"baseRefName":"%s","baseRefOid":"%s","statusCheckRollup":%s,"reviews":%s,"url":"https://example.invalid/pr/1"}\n' "$state" "$merged_at" "$draft" "$mergeable" "$merge_state" "$head_branch" "$head_sha" "$head_owner" "$head_repo" "$base_branch" "$base_sha" "$checks" "$reviews"
elif [ "$1" = pr ] && [ "$2" = ready ]; then
  printf '%s\n' 'https://example.invalid/pr/1'
elif [ "$1" = pr ] && [ "$2" = create ]; then
  printf '%s\n' 'https://example.invalid/pr/1'
elif [ "$1" = repo ] && [ "$2" = view ]; then
  remote_url=$(git remote get-url origin 2>/dev/null || true)
  if [ "${FAKE_OFFICIAL_URLS:-false}" = true ]; then
    remote_url='git@github.com:fixture/repository.git'
  fi
  printf '{"id":"fixture-repository-id","nameWithOwner":"%s","sshUrl":"%s","url":"%s"}\n' "${FAKE_REPOSITORY:-fixture/repository}" "${FAKE_REPO_SSH_URL:-$remote_url}" "${FAKE_WEB_URL:-https://github.com/fixture/repository}"
elif [ "$1" = api ] && [[ "${2:-}" == *'/protection' ]]; then
  if [ "${FAKE_REQUIRED_CHECKS_ERROR:-false}" = true ]; then
    echo 'fixture protection lookup failure' >&2
    exit 1
  fi
  if [ "${FAKE_REQUIRED_CHECKS_EMPTY:-false}" = true ]; then
    status_checks='{"contexts":[],"checks":[]}'
  elif [ "${FAKE_REQUIRED_CONTEXTS_ONLY:-false}" = true ]; then
    status_checks='{"contexts":["gitleaks","trufflehog"],"checks":[]}'
  else
    status_checks='{"contexts":["gitleaks","trufflehog"],"checks":[{"context":"gitleaks","app_id":'"${FAKE_REQUIRED_APP_ID:-15368}"'},{"context":"trufflehog","app_id":'"${FAKE_REQUIRED_APP_ID:-15368}"'}]}'
  fi
  printf '{"required_status_checks":%s,"required_pull_request_reviews":{"required_approving_review_count":%s},"required_conversation_resolution":{"enabled":%s},"enforce_admins":{"enabled":%s}}\n' "$status_checks" "${FAKE_PROTECTION_APPROVALS:-0}" "${FAKE_PROTECTION_CONVERSATIONS:-true}" "${FAKE_PROTECTION_ADMINS:-true}"
elif [ "$1" = api ] && [[ " $* " == *' graphql '* ]] && [[ " $* " == *'checkSuites'* ]]; then
  if [ "${FAKE_CHECK_RUNS_EMPTY:-false}" = true ]; then
    suites='[]'
  else
    check_conclusion=SUCCESS
    if [ "${FAKE_GH_MODE:-}" = second-view-check-failed ] && [ "$(cat "${FAKE_VIEW_COUNT:-/dev/null}" 2>/dev/null || printf '0')" -ge 2 ]; then
      check_conclusion=FAILURE
    fi
    suites='[{"app":{"databaseId":'"${FAKE_CHECK_APP_ID:-15368}"'},"checkRuns":{"nodes":[{"name":"gitleaks","status":"COMPLETED","conclusion":"'"$check_conclusion"'"},{"name":"trufflehog","status":"COMPLETED","conclusion":"SUCCESS"}],"pageInfo":{"hasNextPage":'"${FAKE_CHECK_RUNS_NEXT:-false}"'}}}]'
  fi
  if [ "${FAKE_CHECK_DATA_ERRORS:-false}" = true ]; then errors=',"errors":[{"message":"fixture"}]'; else errors=''; fi
  printf '{"data":{"repository":{"object":{"checkSuites":{"nodes":%s,"pageInfo":{"hasNextPage":%s}}}}}%s}\n' "$suites" "${FAKE_CHECK_SUITES_NEXT:-false}" "$errors"
elif [ "$1" = api ] && [[ " $* " == *' graphql '* ]] && [[ " $* " == *'updateRefs'* ]]; then
  if [ -n "${FAKE_REMOTE:-}" ] && [ -n "${FAKE_PR_HEAD_SHA:-}" ]; then
    query=''
    for arg in "$@"; do
      case "$arg" in query=*) query=${arg#query=} ;; esac
    done
    parsed=$(python3 -c 'import json,re,sys
q=sys.argv[1]
items=[]
for body in re.findall(r"\{name:(\"(?:[^\"\\]|\\.)*\"),beforeOid:(\"[0-9a-f]{40}\"),afterOid:(\"[0-9a-f]{40}\"),force:(true|false)\}",q):
    items.append({"name":json.loads(body[0]),"before":json.loads(body[1]),"after":json.loads(body[2]),"force":body[3] == "true"})
repository=re.search(r"repositoryId:(\"(?:[^\"\\]|\\.)*\")",q)
if not repository or not items or q.count("{name:") != len(items): raise SystemExit(2)
print(json.dumps({"repository_id":json.loads(repository.group(1)),"updates":items},separators=(",",":")))' "$query") || { echo 'fixture cannot parse updateRefs query' >&2; exit 1; }
    zero=0000000000000000000000000000000000000000
    if jq -e --arg base "${FAKE_PR_BASE_SHA:-}" --arg head "${FAKE_PR_HEAD_SHA:-}" '
      .repository_id == "fixture-repository-id" and
      (.updates | length) == 2 and
      .updates[0] == {name:"refs/heads/main",before:$base,after:$head,force:false} and
      .updates[1] == {name:"refs/heads/agent/delegate",before:$head,after:$head,force:false}
    ' <<<"$parsed" >/dev/null; then
      mutation=merge
    elif jq -e --arg head "${FAKE_PR_HEAD_SHA:-}" --arg zero "$zero" '
      .repository_id == "fixture-repository-id" and
      (.updates | length) == 1 and
      .updates[0] == {name:"refs/heads/agent/delegate",before:$head,after:$zero,force:false}
    ' <<<"$parsed" >/dev/null; then
      mutation=cleanup
    else
      echo "fixture rejected unexpected updateRefs contract: $parsed" >&2
      exit 1
    fi
    if [ "${FAKE_GH_MODE:-}" = fast-forward-push-failure ]; then
      echo 'fixture updateRefs failure' >&2
      exit 1
    fi
    if [ "${FAKE_GH_MODE:-}" = update-refs-invalid-json ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ "${FAKE_GH_MODE:-}" = update-refs-graphql-error ]; then
      printf '%s\n' '{"errors":[{"message":"fixture rejection"}]}'
      exit 0
    fi
    if [ "${FAKE_GH_MODE:-}" = update-refs-data-and-error ]; then
      printf '%s\n' '{"data":{"updateRefs":{"clientMutationId":null}},"errors":[{"message":"fixture partial error"}]}'
      exit 0
    fi
    current_head=$(git --git-dir "$FAKE_REMOTE" rev-parse "refs/heads/${FAKE_PR_HEAD:-agent/delegate}" 2>/dev/null || true)
    if [ "$current_head" != "$FAKE_PR_HEAD_SHA" ]; then
      echo 'fixture compare-and-swap rejected' >&2
      exit 1
    fi
    if [ "$mutation" = merge ]; then
      current_base=$(git --git-dir "$FAKE_REMOTE" rev-parse "refs/heads/${FAKE_PR_BASE:-main}" 2>/dev/null || true)
      if [ "$current_base" != "${FAKE_PR_BASE_SHA:-}" ]; then
        echo 'fixture compare-and-swap rejected' >&2
        exit 1
      fi
      git --git-dir "$FAKE_REMOTE" update-ref "refs/heads/${FAKE_PR_BASE:-main}" "$FAKE_PR_HEAD_SHA" "$FAKE_PR_BASE_SHA"
      if [ -n "${FAKE_REF_TRACE:-}" ]; then
        printf '%s\n' 'merge:head-retained' >> "$FAKE_REF_TRACE"
      fi
    else
      git --git-dir "$FAKE_REMOTE" update-ref -d "refs/heads/${FAKE_PR_HEAD:-agent/delegate}" "$FAKE_PR_HEAD_SHA"
      if [ -n "${FAKE_REF_TRACE:-}" ]; then
        printf '%s\n' 'cleanup:head-deleted' >> "$FAKE_REF_TRACE"
      fi
    fi
    if [ "${FAKE_GH_MODE:-}" = update-refs-applied-error ]; then
      printf '%s\n' '{"data":{"updateRefs":null},"errors":[{"message":"response lost after apply"}]}'
      exit 0
    fi
    if [ "${FAKE_GH_MODE:-}" = update-refs-applied-lookup-failure ]; then
      mv "$FAKE_REMOTE" "$FAKE_REMOTE.unavailable"
      printf '%s\n' 'not-json'
      exit 0
    fi
  fi
  printf '%s\n' '{"data":{"updateRefs":{"clientMutationId":null}}}'
elif [ "$1" = api ] && [[ " $* " == *' graphql '* ]]; then
  unresolved=false
  change_before=$((${FAKE_CHANGE_VIEW:-2} - 1))
  if [ "${FAKE_UNRESOLVED:-false}" = true ] || { [ "${FAKE_GH_MODE:-}" = second-view-thread ] && [ "$(cat "${FAKE_VIEW_COUNT:-/dev/null}" 2>/dev/null || printf '0')" -ge "$change_before" ]; }; then unresolved=true; fi
  if [ "$unresolved" = true ]; then nodes='[{"isResolved":false}]'; else nodes='[]'; fi
  if [ "${FAKE_THREAD_DATA_ERRORS:-false}" = true ]; then errors=',"errors":[{"message":"fixture"}]'; else errors=''; fi
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":%s,"pageInfo":{"hasNextPage":false}}}}}%s}\n' "$nodes" "$errors"
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
mkdir "$TMP/other-repository"
git -C "$TMP/other-repository" init -q -b main
output=$(python3 "$PLUGIN/scripts/control.py" preflight --config "$CFG" --repo "$TMP/other-repository" 2>"$TMP/stderr")
exit_code=$?
if [ "$exit_code" -eq 2 ] && jq -e '.error == "設定と対象repositoryが一致しない"' <<<"$output" >/dev/null; then
  ok "resolved config is bound to its canonical repository"
else
  ng "resolved config can be reused for another repository"
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
printf 'outside\n' > "$TMP/repository/outside"
git -C "$TMP/repository" add outside
output=$(python3 "$PLUGIN/scripts/control.py" commit --config "$CFG" --repo "$TMP/repository" --paths-file "$TMP/paths.txt" --message fixture --approved 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.reason=="pre_staged_paths_outside_scope" and (.paths | index("outside"))' <<<"$output" >/dev/null; then ok "pre-staged path outside scope is rejected"; else ng "pre-staged outside path was committed"; fi
git -C "$TMP/repository" reset -q outside
printf ':(glob)**\n' > "$TMP/magic-paths.txt"
before_index=$(git -C "$TMP/repository" write-tree)
output=$(python3 "$PLUGIN/scripts/control.py" commit --config "$CFG" --repo "$TMP/repository" --paths-file "$TMP/magic-paths.txt" --message fixture --approved 2>"$TMP/stderr")
if [ "$?" -eq 2 ] && jq -e '.error=="repository外または.gitはcommit対象にできない"' <<<"$output" >/dev/null && [ "$(git -C "$TMP/repository" write-tree)" = "$before_index" ]; then ok "Git pathspec magic is rejected without changing index"; else ng "pathspec magic changed index"; fi
printf './tracked\n' > "$TMP/dot-paths.txt"
before_index=$(git -C "$TMP/repository" write-tree)
output=$(python3 "$PLUGIN/scripts/control.py" commit --config "$CFG" --repo "$TMP/repository" --paths-file "$TMP/dot-paths.txt" --message fixture --approved 2>"$TMP/stderr")
if [ "$?" -eq 2 ] && jq -e '.error=="repository外または.gitはcommit対象にできない"' <<<"$output" >/dev/null && [ "$(git -C "$TMP/repository" write-tree)" = "$before_index" ]; then ok "dot-relative path is rejected without changing index"; else ng "dot-relative path changed index"; fi

echo "  And pushとPR作成はgate待ちの後、実行失敗をJSONで返す"
expect_json 3 waiting_for_human env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository"
git -C "$TMP/repository" remote set-url --add --push origin "$TMP/repository-origin.git"
git -C "$TMP/repository" remote set-url --add --push origin "$TMP/repository-origin.git"
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository" --approved 2>"$TMP/stderr")
if [ "$?" -eq 2 ] && jq -e '.error=="GitHub対象とgit remoteが一致しない"' <<<"$output" >/dev/null; then ok "multiple push URLs are rejected"; else ng "multiple push URLs were accepted"; fi
git -C "$TMP/repository" config --unset-all remote.origin.pushurl
git -C "$TMP/repository" remote set-url origin "$TMP/missing-push.git"
expect_json 3 failed python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository" --approved
git -C "$TMP/repository" remote set-url origin "$TMP/repository-origin.git"
git -C "$TMP/repository" commit -q --allow-empty -m additional
local_sha=$(git -C "$TMP/repository" rev-parse HEAD)
expect_json 0 pushed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository" --approved
expect_json 0 pushed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository" --approved
if [ "$(git --git-dir "$TMP/repository-origin.git" rev-parse refs/heads/agent/delegate)" = "$local_sha" ]; then ok "push sends the fixed local SHA and is idempotent"; else ng "push did not send the inspected SHA"; fi
git clone -q "$TMP/repository-origin.git" "$TMP/remote-writer"
git -C "$TMP/remote-writer" config user.email fixture@example.invalid
git -C "$TMP/remote-writer" config user.name fixture
git -C "$TMP/remote-writer" switch -q agent/delegate
git -C "$TMP/remote-writer" commit -q --allow-empty -m ahead
git -C "$TMP/remote-writer" push -q origin HEAD:agent/delegate
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository" --approved
git -C "$TMP/remote-writer" switch -q -C divergent origin/main
git -C "$TMP/remote-writer" commit -q --allow-empty -m divergent
git -C "$TMP/remote-writer" push -q --force origin HEAD:agent/delegate
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" push --config "$CFG" --repo "$TMP/repository" --approved
git --git-dir "$TMP/repository-origin.git" update-ref refs/heads/agent/delegate "$local_sha"
printf 'fixture body\n' > "$TMP/body.md"
expect_json 3 waiting_for_human env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" pull-request --config "$CFG" --repo "$TMP/repository" --title fixture --body-file "$TMP/body.md"
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=failed python3 "$PLUGIN/scripts/control.py" pull-request --config "$CFG" --repo "$TMP/repository" --title fixture --body-file "$TMP/body.md" --approved
git -C "$TMP/repository" commit -q --allow-empty -m unpublished
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" pull-request --config "$CFG" --repo "$TMP/repository" --title fixture --body-file "$TMP/body.md" --approved
git -C "$TMP/repository" reset -q --soft HEAD^

echo "  And ready-for-reviewはpull_request permissionと既存PR境界を再利用して冪等に公開する"
: > "$TMP/gh.log"
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=ready FAKE_PR_DRAFT=true python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1 2>"$TMP/stderr")
exit_code=$?
if [ "$exit_code" -eq 0 ] && jq -e '.status == "ready" and .changed == true' <<<"$output" >/dev/null && rg -qx 'pr ready 1 --repo fixture/repository' "$TMP/gh.log"; then
  ok "draft PR is made ready for review"
else
  ng "draft PR ready-for-review contract"
fi
if tail -2 "$TMP/gh.log" | sed -n '1p' | rg -q '^pr view ' && tail -1 "$TMP/gh.log" | rg -q '^pr ready '; then ok "ready mutation immediately follows the final PR snapshot"; else ng "ready has a network read after the final PR snapshot"; fi
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
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_DRAFT=true FAKE_PR_STATE=CLOSED python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_DRAFT=true FAKE_PR_HEAD_OWNER=other FAKE_PR_HEAD_REPO=other/repository python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG" --repo "$TMP/repository" --pr 1
: > "$TMP/gh.log"
output=$(env PATH="$TMP/bin:$PATH" GH_REPO=attacker/other FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" pull-request --config "$CFG" --repo "$TMP/repository" --title fixture --body-file "$TMP/body.md" --approved 2>"$TMP/stderr")
if [ "$?" -eq 0 ] && jq -e '.status=="created"' <<<"$output" >/dev/null && rg -q '^pr create --repo fixture/repository ' "$TMP/gh.log"; then ok "GH_REPO cannot redirect PR creation"; else ng "PR creation was not pinned to nameWithOwner"; fi
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
git -C "$TMP/pull-request-disabled" remote add origin "$TMP/repository-origin.git"
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
git -C "$TMP/merge-enabled" remote add origin "$TMP/repository-origin.git"
git -C "$TMP/merge-enabled" push -q --force origin main agent/delegate
CFG_MERGE=$(bash "$PLUGIN/scripts/prepare.sh" "$TMP/merge-enabled") || { ng "merge-enabled config resolves"; exit 1; }
expect_json 3 waiting_for_human env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" merge --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready python3 "$PLUGIN/scripts/control.py" merge --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 --approved
: > "$TMP/gh.log"
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=ready FAKE_PR_STATE=CLOSED python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and (.reasons | index("state:CLOSED"))' <<<"$output" >/dev/null && ! rg -q 'updateRefs|push ' "$TMP/gh.log"; then ok "closed PR is rejected before mutation"; else ng "closed PR rejection reason"; fi
: > "$TMP/gh.log"
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=ready FAKE_PR_HEAD_OWNER=other FAKE_PR_HEAD_REPO=other/repository python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and (.reasons | index("cross_repository"))' <<<"$output" >/dev/null && ! rg -q 'updateRefs|push ' "$TMP/gh.log"; then ok "cross-repository PR is rejected before mutation"; else ng "cross-repository rejection reason"; fi
: > "$TMP/gh.log"
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=ready FAKE_REQUIRED_CONTEXTS_ONLY=true FAKE_CHECKS_JSON='[]' python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and .checks_passed==false and (.reasons | index("checks"))' <<<"$output" >/dev/null && ! rg -q 'updateRefs|push ' "$TMP/gh.log"; then ok "empty check rollup fails closed"; else ng "empty check rollup"; fi
expect_json 3 failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_REQUIRED_CHECKS_ERROR=true python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_REQUIRED_CHECKS_EMPTY=true python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and .required_checks==[] and .checks_passed==false' <<<"$output" >/dev/null; then ok "empty required contexts fail closed"; else ng "empty required contexts"; fi
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_REQUIRED_CONTEXTS_ONLY=true FAKE_CHECKS_JSON='[{"name":"gitleaks","conclusion":"SUCCESS","status":"COMPLETED"}]' python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and .checks_passed==false' <<<"$output" >/dev/null; then ok "missing required context fails closed"; else ng "missing required context"; fi
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_CHECK_APP_ID=999 python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and .checks_passed==false and (.reasons | index("checks"))' <<<"$output" >/dev/null; then ok "required check rejects a different GitHub App"; else ng "required check accepted a different GitHub App"; fi
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_CHECK_RUNS_EMPTY=true python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and .checks_passed==false' <<<"$output" >/dev/null; then ok "empty app check runs fail closed"; else ng "empty app check runs fail open"; fi
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_CHECK_DATA_ERRORS=true python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 2 ] && jq -e '.error=="GitHub APIがerrorを返した"' <<<"$output" >/dev/null; then ok "check data with GraphQL errors fails closed"; else ng "check GraphQL errors were accepted"; fi
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_THREAD_DATA_ERRORS=true python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 2 ] && jq -e '.error=="GitHub APIがerrorを返した"' <<<"$output" >/dev/null; then ok "thread data with GraphQL errors fails closed"; else ng "thread GraphQL errors were accepted"; fi
for pagination in FAKE_CHECK_SUITES_NEXT FAKE_CHECK_RUNS_NEXT; do
  output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready "$pagination"=true python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
  if [ "$?" -eq 2 ] && jq -e '.error | contains("完全に取得できない")' <<<"$output" >/dev/null; then ok "$pagination fails closed"; else ng "$pagination did not fail closed"; fi
done
for required_app in null -1; do
  output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_REQUIRED_APP_ID="$required_app" FAKE_CHECK_APP_ID=999 python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
  if [ "$?" -eq 0 ] && jq -e '.status=="ready" and .checks_passed==true' <<<"$output" >/dev/null; then ok "app_id=$required_app accepts a successful check run from any App"; else ng "app_id=$required_app did not accept an arbitrary App check run"; fi
done
git -C "$TMP/merge-enabled" remote set-url origin 'https://evil.invalid/path/github.com/fixture/repository.git'
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_OFFICIAL_URLS=true python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 2 ] && jq -e '.error=="GitHub対象とgit remoteが一致しない"' <<<"$output" >/dev/null; then ok "remote parser rejects github.com embedded in an evil host path"; else ng "remote parser accepted an evil host path"; fi
fake_credential_uri=$(bash "$ROOT/tests/fixtures/fake-credential-uri.sh")
secret_query_url=$(printf '%s%s' 'https://github.com/fixture/repository.git?token=' 'fixture-secret-query')
secret_fragment_url=$(printf '%s%s' 'ssh://git@github.com/fixture/repository.git#' 'fixture-secret-fragment')
sanitized=$(python3 -c 'import importlib.util,json,sys
spec=importlib.util.spec_from_file_location("control",sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
print(json.dumps([module.redacted_remote_url(value) for value in sys.argv[2:]]))' "$PLUGIN/scripts/control.py" "$fake_credential_uri" "$secret_query_url" "$secret_fragment_url" 'root@github.com:fixture/repository.git')
if jq -e 'all(.[]; .=="<redacted-invalid-remote-url>")' <<<"$sanitized" >/dev/null && [[ "$sanitized" != *fixture-password* ]] && [[ "$sanitized" != *fixture-secret-query* ]] && [[ "$sanitized" != *fixture-secret-fragment* ]]; then ok "remote URL sanitizer never returns invalid secrets"; else ng "remote URL sanitizer exposed invalid input"; fi
for remote_url in \
  'https://github.com/fixture/repository.git?token=x' \
  "$fake_credential_uri" \
  'https://github.com/extra/fixture/repository.git' \
  'ssh://git@github.com/fixture/repository.git#fragment' \
  'ssh://git@github.com:443/fixture/repository.git' \
  'git@github.com:fixture/repository/extra.git'; do
  git -C "$TMP/merge-enabled" remote set-url origin "$remote_url"
  output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_OFFICIAL_URLS=true FAKE_REPO_SSH_URL='git@github.com:unused/unused.git' python3 "$PLUGIN/scripts/control.py" ready-for-review --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1 2>"$TMP/stderr")
  if [ "$?" -eq 2 ] && jq -e '.error=="GitHub対象とgit remoteが一致しない"' <<<"$output" >/dev/null && [[ "$output" != *fixture-password* ]]; then ok "remote parser rejects and redacts invalid URL"; else ng "remote parser accepted or exposed invalid URL"; fi
done
for remote_url in 'ssh://git@github.com/fixture/repository.git' 'git@github.com:fixture/repository.git'; do
  git -C "$TMP/merge-enabled" remote set-url origin "$remote_url"
  expect_json 0 ready env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_OFFICIAL_URLS=true FAKE_REPO_SSH_URL='git@github.com:unused/unused.git' python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1
done
git -C "$TMP/merge-enabled" remote set-url origin 'ssh://git@ghe.example.com/fixture/repository.git'
expect_json 0 ready env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_OFFICIAL_URLS=true FAKE_REPO_SSH_URL='git@ghe.example.com:unused/unused.git' FAKE_WEB_URL='https://ghe.example.com/fixture/repository' python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$CFG_MERGE" --repo "$TMP/merge-enabled" --pr 1
git -C "$TMP/merge-enabled" remote set-url origin "$TMP/repository-origin.git"
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

echo "  And fast-forwardは同一headと未進行baseだけを直接更新し、GitHub反映まで確認する"
cp "$FIXTURE" "$TMP/repository/.harness-plugins/fast-forward.yml"
yq -i '.permissions.merge = true' "$TMP/repository/.harness-plugins/fast-forward.yml"
yq -i '.gates.before_merge = false' "$TMP/repository/.harness-plugins/fast-forward.yml"
yq -i '.merge.method = "fast-forward"' "$TMP/repository/.harness-plugins/fast-forward.yml"
yq -i '.merge.delete_branch = true' "$TMP/repository/.harness-plugins/fast-forward.yml"
yq -i '.merge.readiness.min_approvals = 0' "$TMP/repository/.harness-plugins/fast-forward.yml"
make_ff_repo() {
  local name="$1"
  FF_REPO="$TMP/$name"
  FF_REMOTE="$TMP/$name.git"
  git init -q --bare "$FF_REMOTE"
  mkdir -p "$FF_REPO/.harness-plugins"
  cp "$TMP/repository/.harness-plugins/fast-forward.yml" "$FF_REPO/.harness-plugins/agent-work-policy.config.yml"
  git -C "$FF_REPO" init -q -b main
  git -C "$FF_REPO" config user.email fixture@example.invalid
  git -C "$FF_REPO" config user.name fixture
  printf 'base\n' > "$FF_REPO/tracked"
  git -C "$FF_REPO" add tracked
  git -C "$FF_REPO" commit -qm initial
  FF_BASE=$(git -C "$FF_REPO" rev-parse HEAD)
  git -C "$FF_REPO" switch -qc agent/delegate
  printf 'head\n' >> "$FF_REPO/tracked"
  git -C "$FF_REPO" commit -qam middle
  FF_MID=$(git -C "$FF_REPO" rev-parse HEAD)
  printf 'head-again\n' >> "$FF_REPO/tracked"
  git -C "$FF_REPO" commit -qam head
  FF_HEAD=$(git -C "$FF_REPO" rev-parse HEAD)
  git -C "$FF_REPO" remote add origin "$FF_REMOTE"
  git -C "$FF_REPO" push -q origin main agent/delegate
  FF_CFG=$(bash "$PLUGIN/scripts/prepare.sh" "$FF_REPO") || { ng "fast-forward config resolves"; return 1; }
}

make_ff_repo fast-forward-success || exit 1
: > "$TMP/ref-trace"
: > "$TMP/gh.log"
expect_json 0 merged env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=fast-forward FAKE_REMOTE="$FF_REMOTE" FAKE_REF_TRACE="$TMP/ref-trace" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
if [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_HEAD" ]; then ok "fast-forward updates base to head"; else ng "fast-forward base update"; fi
if [ "$(sed -n '1p' "$TMP/ref-trace")" = 'merge:head-retained' ] && [ "$(sed -n '2p' "$TMP/ref-trace")" = 'cleanup:head-deleted' ]; then
  ok "head is retained for GitHub reflection and deleted only afterward"
else
  ng "head cleanup ran before GitHub merge reflection"
fi
first_update_line=$(rg -n 'updateRefs' "$TMP/gh.log" | head -1 | cut -d: -f1)
before_update=$((first_update_line - 1))
if [ "$first_update_line" -gt 1 ] && sed -n "${before_update}p" "$TMP/gh.log" | rg -q '^pr view .* --repo fixture/repository ';
then
  ok "updateRefs immediately follows the final readiness network response"
else
  ng "an extra network call remains between final readiness and updateRefs"
fi
if [ "$(rg -c '^repo view ' "$TMP/gh.log")" -eq 1 ]; then ok "merge fixes repository identity once"; else ng "merge re-resolved repository identity"; fi
rm -f "$FF_CFG"

echo "  And fast-forwardはpolicy要求以上のserver branch protectionを必須にする"
for protection_case in conversations admins; do
  make_ff_repo "protection-$protection_case" || exit 1
  if [ "$protection_case" = conversations ]; then protection_env=FAKE_PROTECTION_CONVERSATIONS; expected_reason=protection:conversation_resolution; else protection_env=FAKE_PROTECTION_ADMINS; expected_reason=protection:admins; fi
  output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready "$protection_env"=false python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$FF_CFG" --repo "$FF_REPO" --pr 1 2>"$TMP/stderr")
  if [ "$?" -eq 3 ] && jq -e --arg reason "$expected_reason" '.status=="not_ready" and (.reasons | index($reason))' <<<"$output" >/dev/null && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_BASE" ] && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_HEAD" ]; then ok "$expected_reason fails closed with refs unchanged"; else ng "$expected_reason was accepted"; fi
  rm -f "$FF_CFG"
done

make_ff_repo protection-approvals || exit 1
rm -f "$FF_CFG"
yq -i '.merge.readiness.min_approvals = 1' "$FF_REPO/.harness-plugins/agent-work-policy.config.yml"
FF_CFG=$(bash "$PLUGIN/scripts/prepare.sh" "$FF_REPO") || exit 1
approved_reviews='[{"author":{"login":"reviewer"},"submittedAt":"2026-09-03T00:00:00Z","state":"APPROVED"}]'
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_REVIEWS_JSON="$approved_reviews" FAKE_PROTECTION_APPROVALS=0 python3 "$PLUGIN/scripts/control.py" merge-readiness --config "$FF_CFG" --repo "$FF_REPO" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="not_ready" and (.reasons | index("protection:approvals"))' <<<"$output" >/dev/null && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_BASE" ] && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_HEAD" ]; then ok "weaker server approval protection fails closed with refs unchanged"; else ng "weaker server approval protection was accepted"; fi
rm -f "$FF_CFG"

echo "  And 2回目readinessのstate・head・check変化はmutation前に拒否する"
for scenario in second-view-closed second-view-head-changed second-view-base-changed second-view-head-retarget second-view-base-retarget second-view-repository-changed second-view-check-failed second-view-draft second-view-unmergeable second-view-unstable second-view-thread; do
  make_ff_repo "$scenario" || exit 1
  : > "$TMP/view-count"
  : > "$TMP/gh.log"
  output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE="$scenario" FAKE_VIEW_COUNT="$TMP/view-count" FAKE_REMOTE="$FF_REMOTE" FAKE_SECOND_HEAD_SHA="$FF_MID" FAKE_SECOND_BASE_SHA="$FF_MID" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1 2>"$TMP/stderr")
  exit_code=$?
  case "$scenario" in
    second-view-closed) expected_reason=state:CLOSED ;;
    second-view-head-changed) expected_reason=snapshot_head_changed ;;
    second-view-base-changed) expected_reason=snapshot_base_changed ;;
    second-view-head-retarget) expected_reason=snapshot_head_branch_changed ;;
    second-view-base-retarget) expected_reason=snapshot_base_branch_changed ;;
    second-view-repository-changed) expected_reason=snapshot_head_repository_changed ;;
    second-view-check-failed) expected_reason=checks ;;
    second-view-draft) expected_reason=draft ;;
    second-view-unmergeable) expected_reason=mergeable:CONFLICTING ;;
    second-view-unstable) expected_reason=merge_state:UNSTABLE ;;
    second-view-thread) expected_reason=unresolved_threads ;;
  esac
  if [ "$exit_code" -eq 3 ] && jq -e --arg reason "$expected_reason" '.status=="not_ready" and (.reasons | index($reason))' <<<"$output" >/dev/null && ! rg -q 'updateRefs' "$TMP/gh.log" && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_BASE" ] && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_HEAD" ]; then
    ok "$scenario is rejected and both refs stay unchanged"
  else
    ng "$scenario was not rejected before mutation: $output"
  fi
  rm -f "$FF_CFG"
done

echo "  And merge直前の2回目readiness内で変化してもmutationしない"
for scenario in second-view-closed second-view-head-changed second-view-base-changed second-view-head-retarget second-view-base-retarget second-view-repository-changed second-view-check-failed second-view-draft second-view-thread; do
  make_ff_repo "final-$scenario" || exit 1
  : > "$TMP/view-count"
  : > "$TMP/gh.log"
  output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE="$scenario" FAKE_CHANGE_VIEW=4 FAKE_VIEW_COUNT="$TMP/view-count" FAKE_REMOTE="$FF_REMOTE" FAKE_SECOND_HEAD_SHA="$FF_MID" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1 2>"$TMP/stderr")
  if [ "$?" -eq 3 ] && jq -e '.status=="merge_failed" and .reason=="readiness_changed" and .latest.status=="not_ready"' <<<"$output" >/dev/null && ! rg -q 'updateRefs' "$TMP/gh.log" && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_BASE" ] && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_HEAD" ]; then
    ok "final $scenario is rejected and both refs stay unchanged"
  else
    ng "final $scenario reached mutation: $output"
  fi
  rm -f "$FF_CFG"
done

make_ff_repo second-view-approval-lost || exit 1
rm -f "$FF_CFG"
yq -i '.merge.readiness.min_approvals = 1' "$FF_REPO/.harness-plugins/agent-work-policy.config.yml"
FF_CFG=$(bash "$PLUGIN/scripts/prepare.sh" "$FF_REPO") || exit 1
: > "$TMP/view-count"
: > "$TMP/gh.log"
approved_reviews='[{"author":{"login":"reviewer"},"submittedAt":"2026-09-03T00:00:00Z","state":"APPROVED"}]'
output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log" FAKE_GH_MODE=second-view-approval-lost FAKE_CHANGE_VIEW=4 FAKE_VIEW_COUNT="$TMP/view-count" FAKE_REMOTE="$FF_REMOTE" FAKE_PROTECTION_APPROVALS=1 FAKE_REVIEWS_JSON="$approved_reviews" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1 2>"$TMP/stderr")
if [ "$?" -eq 3 ] && jq -e '.status=="merge_failed" and .reason=="readiness_changed" and (.latest.reasons | index("approvals"))' <<<"$output" >/dev/null && ! rg -q 'updateRefs' "$TMP/gh.log" && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_BASE" ] && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_HEAD" ]; then
  ok "second-view approval loss is rejected and both refs stay unchanged"
else
  ng "second-view approval loss was not rejected before mutation: $output"
fi
rm -f "$FF_CFG"

destructive_query='mutation { updateRefs(input:{repositoryId:"fixture-repository-id",refUpdates:[{name:"refs/heads/main",beforeOid:"'"$FF_BASE"'",afterOid:"'"$FF_HEAD"'",force:false},{name:"refs/heads/agent/delegate",beforeOid:"'"$FF_HEAD"'",afterOid:"0000000000000000000000000000000000000000",force:false}]}) { clientMutationId } }'
env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" gh api graphql -f "query=$destructive_query" >/dev/null 2>"$TMP/stderr"
if [ "$?" -ne 0 ]; then ok "strict updateRefs parser rejects destructive merge mutation"; else ng "strict updateRefs parser accepted destructive merge mutation"; fi

echo "  But base進行、head不一致、non-FF、push失敗、PR未反映はmerge失敗にする"
make_ff_repo fast-forward-base-advanced || exit 1
git -C "$FF_REPO" switch -q main
printf 'advanced\n' >> "$FF_REPO/tracked"
git -C "$FF_REPO" commit -qam advanced
git -C "$FF_REPO" push -q origin main
git -C "$FF_REPO" switch -q agent/delegate
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=fast-forward FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo fast-forward-head-mismatch || exit 1
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_BASE" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo fast-forward-base-race || exit 1
: > "$TMP/view-count"
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=advance-base-on-second-view FAKE_VIEW_COUNT="$TMP/view-count" FAKE_REMOTE="$FF_REMOTE" FAKE_ADVANCED_BASE="$FF_MID" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
if [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_MID" ]; then ok "base race does not advance to head"; else ng "base race was overwritten"; fi
rm -f "$FF_CFG"

make_ff_repo fast-forward-non-ff || exit 1
git -C "$FF_REPO" switch -q main
printf 'diverged\n' >> "$FF_REPO/tracked"
git -C "$FF_REPO" commit -qam diverged
FF_ADVANCED=$(git -C "$FF_REPO" rev-parse HEAD)
git -C "$FF_REPO" push -q origin main
git -C "$FF_REPO" switch -q agent/delegate
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=fast-forward FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_ADVANCED" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo fast-forward-push-failure || exit 1
cat > "$FF_REMOTE/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FF_REMOTE/hooks/pre-receive"
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=fast-forward-push-failure FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
if [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_BASE" ] && [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_HEAD" ]; then
  ok "rejected atomic update leaves base and head unchanged"
else
  ng "rejected atomic update changed a ref"
fi
rm -f "$FF_CFG"

make_ff_repo fast-forward-unreflected || exit 1
partial_output=$(env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=fast-forward-unreflected FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1 2>"$TMP/stderr")
partial_exit=$?
if [ "$partial_exit" -eq 4 ] && jq -e --arg sha "$FF_HEAD" '.status == "merge_partial" and .base_updated == true and .remote_base_sha == $sha' <<<"$partial_output" >/dev/null; then
  ok "merge_partial returns actual updated base SHA (exit 4)"
else
  ng "unreflected merge did not report partial state and actual base SHA: $partial_output"
fi
if [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_HEAD" ]; then
  ok "reflection timeout retains the expected head for cleanup resume"
else
  ng "reflection timeout deleted the PR head"
fi
expect_json 0 cleaned env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_STATE=MERGED FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" cleanup --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo update-refs-invalid-json || exit 1
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=update-refs-invalid-json FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo update-refs-graphql-error || exit 1
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=update-refs-graphql-error FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo update-refs-data-and-error || exit 1
expect_json 3 merge_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=update-refs-data-and-error FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo update-refs-applied-error || exit 1
expect_json 4 merge_partial env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=update-refs-applied-error FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
if [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/main)" = "$FF_HEAD" ]; then ok "applied mutation with error is partial"; else ng "applied error fixture did not update base"; fi
rm -f "$FF_CFG"

make_ff_repo update-refs-applied-lookup-failure || exit 1
expect_json 4 merge_partial env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=update-refs-applied-lookup-failure FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" merge --config "$FF_CFG" --repo "$FF_REPO" --pr 1
rm -f "$FF_CFG"

make_ff_repo cleanup-head-mismatch || exit 1
git --git-dir "$FF_REMOTE" update-ref refs/heads/agent/delegate "$FF_MID" "$FF_HEAD"
expect_json 3 cleanup_failed env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_STATE=MERGED FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" cleanup --config "$FF_CFG" --repo "$FF_REPO" --pr 1
if [ "$(git --git-dir "$FF_REMOTE" rev-parse refs/heads/agent/delegate)" = "$FF_MID" ]; then ok "cleanup preserves a concurrently changed head"; else ng "cleanup deleted a changed head"; fi
rm -f "$FF_CFG"

make_ff_repo cleanup-exact-head || exit 1
expect_json 0 cleaned env PATH="$TMP/bin:$PATH" FAKE_GH_MODE=ready FAKE_PR_STATE=MERGED FAKE_REMOTE="$FF_REMOTE" FAKE_PR_HEAD_SHA="$FF_HEAD" FAKE_PR_BASE_SHA="$FF_BASE" python3 "$PLUGIN/scripts/control.py" cleanup --config "$FF_CFG" --repo "$FF_REPO" --pr 1
if git --git-dir "$FF_REMOTE" show-ref --verify --quiet refs/heads/agent/delegate; then ng "cleanup left exact head"; else ok "cleanup CAS deletes the exact PR head"; fi
rm -f "$FF_CFG"

if [ "$FAIL" -eq 0 ]; then
  echo "Publication authority contract: passed"
else
  echo "Publication authority contract: failed" >&2
fi
exit "$FAIL"
