# policy設定の意味

このreferenceは、agent-work-policyのpolicy設定の各値を作業判断へ対応させる。設定fileは対象repository rootの `.harness-plugins/agent-work-policy.config.yml` 1つで、`scripts/invoke.py` がrepositoryから解決して読み、`scripts/control.py` がschema（key集合の完全一致と型）を検査する。`false` と空文字は有効な値であり、欠落と `null` は停止する。同梱既定へのfallbackは無く、記入例は `assets/policy.example.yml` にある。

## schema

- `version`: schema version。`1` 以外は停止する。設定は permission・gate・readiness・workspace の値だけを持ち、agent向けの指示文は持たない。

## workspace

- `workspace.use_worktree`: `true` なら別worktree、`false` なら現在checkout内の専用branchを使う。
- `workspace.require_clean_start`: `true` なら開始元に未commit変更があれば `plan` / `start` で停止する。`inspect` は止まらない。
- `workspace.base_branch`: 作業branchの作成元であり、PRのbase。保護branchへ直接pushしない。
- `workspace.branch_prefix`: task slugの前へ付ける必須prefix。
- `workspace.worktree_root`: worktreeの親directory。空文字ならOSの一時directoryを使う。

## Git操作

- `git.remote`: push、remote branch確認、削除に使うremote名。
- `permissions.commit`: commit操作そのものを許すか。
- `permissions.push`: push操作そのものを許すか。`update-branch` も作業branchのremoteを進めるので同じpermissionを使う。
- `permissions.pull_request`: PR作成そのものを許すか。`ready-for-review` も同じpermissionを使う。
- `permissions.merge`: merge操作そのものを許すか。

permissionが `false` なら `permission_denied` で停止し、人間の承認で上書きしない。

## human gate

- `gates.before_commit`: commit直前に依頼者の明示承認を要求するか。
- `gates.before_push`: push直前に依頼者の明示承認を要求するか。
- `gates.before_pull_request`: PR作成直前に依頼者の明示承認を要求するか。
- `gates.before_merge`: readiness充足後、merge直前に依頼者の明示承認を要求するか。

gateが `true` なら、呼び出しの `approval` が今回のaction・対象・時刻を含むときだけ通り、含まなければ承認対象を返して `waiting_for_human` で止まる。`update-branch` は公開済みのbaseを取り込むだけで新しい内容を公開しないので、gateを持たない。

## 検証とPR

- `verification.commands`: commit前に作業directoryで記載順に全件成功させるcommand配列。
- `pull_request.draft`: `true` ならPRをdraftとして作る。

## merge

- `merge.method`: `squash` / `merge` / `rebase` はGitHub merge APIへ渡す。`update-branch` は `squash` と `merge` のときだけ使える（`rebase` と `fast-forward` では、baseから取り込んだmerge commitがbaseの履歴へ入るため）。`fast-forward` はGraphQL `updateRefs` の `beforeOid` と `force:false` でbase更新とhead no-op CASをatomicに行い、GitHubのmerge反映後にheadを別CASで削除する。`fast-forward` では `delete_branch: true` が必須で、そうでなければschema検査で停止する。
- `merge.delete_branch`: merge成功後にremote作業branchを削除するか。worktree削除とは別である。
- `merge.delete_worktree`: merge成功後にcleanな副worktreeを削除するか。`workspace.use_worktree: true` のときだけ `true` にでき、そうでなければschema検査で停止する。
- `merge.readiness.min_approvals`: readyに必要な最新reviewのApprove数。`0` も有効である。
- `merge.readiness.required_checks`: mergeに必要なcheckの唯一の定義である。`{name: <check名>, app: <報告元GitHub Appのslug>}` の重複の無い非空配列で、各要素について、head commitでその名前とAppの組の最新のcheck runが完了して成功し、最後に取り直したPRのcheck rollupでも同じ名前が成功していることをready条件にする。名前だけで照合しないのは、別のAppやworkflowが同名のcheckを成功させられるからである。branch protectionの有無には依存しない。check suiteやcheck runを完全に取得できなければ止まる。
- `merge.readiness.require_no_unresolved_threads`: `true` なら未解決review threadが0件であることをready条件にする。

`merge.readiness.min_approvals` が `0` で、GitHubが `mergeStateStatus=BLOCKED` を返した場合、実行器は対象branchへ実際に適用されるRulesetを取得する。全ルールがPRルールであり、選択したmerge methodが許可され、review thread必須をpolicyでも検査し、現在利用者が全RulesetをPR経由でbypassできるとGitHubが返した場合だけ、承認不足による `BLOCKED` を許容する。required checkと未解決threadの失敗はbypassしない。

readinessは、PRの `baseRefOid` ではなくbase branchのrefから現在の先端を取り直し、headがそれを含まなければ `behind_base` を未充足に加える。PRが返すbaseは古い値のことがあり、GitHubの `BEHIND` はbranch protectionで最新を必須にしたときしか返らないためである。

`fast-forward` ではbranch protectionのrequired checkが `required_checks` の名前をすべて含み、required approvalsが `merge.readiness.min_approvals` 以上であり、conversation resolutionが要求時にserver側でも必須で、administratorにも保護が適用されることを確認する。policy判定より弱いserver protectionでは更新しない。

設定値を報告用に列挙するだけで終わらせない。各値はworkspace作成、公開操作、停止、PR、mergeの該当箇所へ反映する。
