#!/usr/bin/env bash
# agent-work-policy 固有のschema検査と、解決結果の組み立て。
# shared/skill/resolve.sh から source される。
jq -e '
  .version == 1 and
  (.workspace|type=="object" and (keys|sort)==["base_branch","branch_prefix","require_clean_start","use_worktree","worktree_root"] and
    (.use_worktree|type=="boolean") and (.require_clean_start|type=="boolean") and
    (.base_branch|type=="string" and test("^[A-Za-z0-9._/-]+$") and length>0) and
    (.branch_prefix|type=="string" and test("^[A-Za-z0-9._/-]+/$")) and
    (.worktree_root|type=="string")) and
  (.git|type=="object" and (keys|sort)==["remote"] and (.remote|type=="string" and test("^[A-Za-z0-9._-]+$") and length>0)) and
  (.permissions|type=="object" and (keys|sort)==["commit","merge","pull_request","push"] and all(.[]; type=="boolean")) and
  (.gates|type=="object" and (keys|sort)==["before_commit","before_merge","before_pull_request","before_push"] and all(.[]; type=="boolean")) and
  (.verification|type=="object" and (keys|sort)==["commands"] and
    (.commands|type=="array" and length>0 and all(.[]; type=="string" and length>0))) and
  (.pull_request|type=="object" and (keys|sort)==["draft"] and (.draft|type=="boolean")) and
  (.merge|type=="object" and (keys|sort)==["delete_branch","delete_worktree","method","readiness"] and
    (.method=="squash" or .method=="merge" or .method=="rebase" or .method=="fast-forward") and
    (.delete_branch|type=="boolean") and
    (.delete_worktree|type=="boolean") and
    (.readiness|type=="object" and (keys|sort)==["min_approvals","require_checks_passed","require_no_unresolved_threads"] and
      (.min_approvals|type=="number" and floor==. and .>=0 and .<=100) and
      (.require_checks_passed|type=="boolean") and (.require_no_unresolved_threads|type=="boolean"))) and
  ((.merge.delete_worktree|not) or .workspace.use_worktree) and
  (.instructions.execution.directive|type=="string" and length>0)
' >/dev/null <<<"$merged" \
  || { echo "[error] agent-work-policyの設定schemaが不正" >&2; exit 2; }

base=$(jq -r '.workspace.base_branch' <<<"$merged")
prefix=$(jq -r '.workspace.branch_prefix' <<<"$merged")
case "$base" in "$prefix"*) echo "[error] base_branchを作業branch_prefix配下にできない" >&2; exit 2 ;; esac

worktree_root=$(jq -r '.workspace.worktree_root' <<<"$merged")
if [ -n "$worktree_root" ]; then
  worktree_root=$(resolve_path "$worktree_root")
fi
out=$(jq -c --arg root "$root" --arg pr "$PLUGIN_ROOT" --arg wr "$worktree_root" \
  '.workspace.worktree_root=$wr | . + {repo_root:$root,plugin_root:$pr}' <<<"$merged")
