# 解決済み設定の意味

このreferenceは、agent-work-policyの設定値を作業判断へ対応させる。値は必ずSKILLが作った`$CFG_FILE`から
使用時に`yq -er`で読む。`false`と空文字は有効な値であり、欠落と`null`なら停止する。

## schemaと実行方針

- `${.version}`: schema version。`1`以外ならresolverが停止する。
- `${.instructions.execution.directive}`: 全工程へ適用する短い実行方針。permissionや停止条件を上書きしない。

## workspace

- `${.workspace.use_worktree}`: `true`なら別worktree、`false`なら現在checkout内の専用branchを使う。
- `${.workspace.require_clean_start}`: `true`なら開始元に未commit変更があれば停止する。
- `${.workspace.base_branch}`: 作業branchの作成元であり、PRのbase。保護branchへ直接pushしない。
- `${.workspace.branch_prefix}`: task slugの前へ付ける必須prefix。
- `${.workspace.worktree_root}`: worktreeの親directory。空文字ならOSの一時directoryを使う。

## Git操作

- `${.git.remote}`: push、remote branch確認、削除に使うremote名。
- `${.permissions.commit}`: commit操作そのものを許すか。
- `${.permissions.push}`: push操作そのものを許すか。
- `${.permissions.pull_request}`: PR作成そのものを許すか。
- `${.permissions.merge}`: merge操作そのものを許すか。

permissionが`false`なら停止し、人間の承認で上書きしない。

## human gate

- `${.gates.before_commit}`: commit直前に依頼者の明示承認を要求するか。
- `${.gates.before_push}`: push直前に依頼者の明示承認を要求するか。
- `${.gates.before_pull_request}`: PR作成直前に依頼者の明示承認を要求するか。
- `${.gates.before_merge}`: readiness充足後、merge直前に依頼者の明示承認を要求するか。

gateが`true`なら対象状態を提示し、実際に承認を得た再実行だけへ`--approved`を付ける。

## 検証とPR

- `${.verification.commands}`: commit前に作業directoryで記載順に全件成功させるcommand配列。
- `${.pull_request.draft}`: `true`ならPRをdraftとして作る。

## merge

- `${.merge.method}`: `squash` / `merge` / `rebase`はGitHub merge APIへ渡す。`fast-forward`はGraphQL `updateRefs`の`beforeOid`と`force:false`でbaseとheadをatomicに更新する。`fast-forward`では`delete_branch: true`が必須。
- `${.merge.delete_branch}`: merge成功後にremote作業branchを削除するか。worktree削除とは別である。
- `${.merge.delete_worktree}`: merge成功後にcleanな副worktreeを削除するか。`workspace.use_worktree: true`のときだけ有効にできる。
- `${.merge.readiness.min_approvals}`: readyに必要な最新reviewのApprove数。`0`も有効である。
- `${.merge.readiness.require_checks_passed}`: `true`ならbase branch protectionのrequired check contextを取得し、1件以上ある全contextの存在と成功をready条件にする。取得不能・0件・欠落はfail-closed。
- `${.merge.readiness.require_no_unresolved_threads}`: `true`なら未解決review threadが0件であることをready条件にする。

設定値を報告用に列挙するだけで終わらせない。各値はworkspace作成、公開操作、停止、PR、mergeの該当箇所へ反映する。
