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

- `${.merge.method}`: `squash` / `merge` / `rebase`はGitHub merge APIへ渡す。`fast-forward`はGraphQL `updateRefs`の`beforeOid`と`force:false`でbase更新とhead no-op CASをatomicに行い、GitHubのmerge反映後にheadを別CASで削除する。`fast-forward`では`delete_branch: true`が必須。
- `${.merge.delete_branch}`: merge成功後にremote作業branchを削除するか。worktree削除とは別である。
- `${.merge.delete_worktree}`: merge成功後にcleanな副worktreeを削除するか。`workspace.use_worktree: true`のときだけ有効にできる。
- `${.merge.readiness.min_approvals}`: readyに必要な最新reviewのApprove数。`0`も有効である。
- `${.merge.readiness.require_checks_passed}`: `true`ならbase branch protectionのrequired checkを取得し、1件以上ある全checkの存在と成功をready条件にする。`checks[].app_id`が正の値ならhead commitのCheckRun名とGitHub App database IDの両方を照合する。`null`または`-1`は任意Appの同名CheckRunを許すが、legacy StatusContextでは満たせない。`checks`がなく`contexts`だけなら名前で照合する。取得不能・0件・欠落・100件超で完全取得できない場合はfail-closed。
- `${.merge.readiness.require_no_unresolved_threads}`: `true`なら未解決review threadが0件であることをready条件にする。

`${.merge.readiness.min_approvals}`が`0`で、GitHubが`mergeStateStatus=BLOCKED`を返した場合、実行器は対象branchへ実際に適用されるRulesetを取得する。全ルールがPRルールであり、選択したmerge methodが許可され、review thread必須をpolicyでも検査し、現在利用者が全RulesetをPR経由でbypassできるとGitHubが返した場合だけ、承認不足による`BLOCKED`を許容する。required checkと未解決threadの失敗はbypassしない。

`fast-forward`ではbranch protectionのrequired approvalsが`${.merge.readiness.min_approvals}`以上であり、conversation resolutionが要求時にserver側でも必須で、administratorにも保護が適用されることを確認する。policy判定より弱いserver protectionでは更新しない。

設定値を報告用に列挙するだけで終わらせない。各値はworkspace作成、公開操作、停止、PR、mergeの該当箇所へ反映する。
