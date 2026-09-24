# policy設定の意味

policy設定は、対象repository rootの `.harness-plugins/agent-work-policy.config.yml` 1つである。`scripts/invoke.py` がrepositoryから解決して読み、`scripts/control.py` がkey集合の完全一致と型を検査する。`false` と空文字は有効な値であり、欠落と `null` は止まる。同梱既定へのfallbackは無い。全keyと書き方は [`assets/policy.example.yml`](../assets/policy.example.yml) のコメントにある。この資料は、keyの一覧ではなく、値が作業のどこでどう効くかを説明する。

## permissionとgateは別の問いに答える

`permissions.*` は「その操作をこのrepositoryでagentにさせてよいか」に答える。falseなら、人がどれだけ承認しても実行しない。承認で上書きできると、policyの意味が承認の与え方しだいで変わってしまうからである。

`gates.*` は「その操作の直前に人の確認が要るか」に答える。trueなら、呼び出しの承認範囲 `approval` が今回のaction・対象・時刻を含むときだけ通り、含まなければ承認対象を返して止まる。

permissionとgateは、操作が何を変えるかで対にして決める。remoteの作業branchを進める操作（`push` と `update-branch`）は、`permissions.push` と `gates.before_push` に従う。`update-branch` も、PRのheadを変え、CIを走らせ直し、承認済みのreviewを古くするからである。既存PRの状態だけを変える `ready-for-review` は、`permissions.pull_request` に従い、gateを持たない。

## mergeしてよい状態は二つの条件で決まる

一つ目の条件は、headがbaseの現在の先端を含むことである。readinessはPRが返すbaseではなく、base branchのrefから先端を取り直して比べる。PRが返すbaseは古い値のことがあり、GitHubの `BEHIND` はbranch protectionで最新を必須にしたときしか返らないためである。含まなければ `behind_base` になる。

二つ目の条件は、`merge.readiness.required_checks` が並べた必須checkが、そのheadで成功していることである。この配列が必須checkの唯一の定義であり、branch protectionの有無には依存しない。各要素はcheck名と報告元GitHub Appのslugの組である。名前だけで照合しないのは、別のAppやworkflowが同名のcheckを成功させられるからである。GitHub Actionsのslugは `github-actions` で、ほかのAppのslugは次の参照系のAPIで確かめられる。

```bash
gh api repos/<owner>/<repo>/commits/<sha>/check-runs --jq '.check_runs[] | {name, app: .app.slug}'
```

必須checkの状態は、完了して失敗したもの（`checks_failed`）、まだ完了していないか、pushの直後や前のjobを待つ間でまだ作られていないもの（`checks_pending`）、headのcheck suiteがすべて完了したのにその名前とAppの組が報告されなかったもの（`checks_missing`）に分けて返る。pendingなら待って確かめ直し、failedなら直す作業へ戻り、missingならpolicyの名前かAppが実際の報告と合っているかを確かめる。

このほか、`merge.readiness.min_approvals` は最新reviewのApprove数、`merge.readiness.require_no_unresolved_threads` は未解決review threadが0件であることを求める。承認数が0のpolicyでGitHubが `BLOCKED` を返したときは、実際に当たるRulesetをすべて現在の利用者がPR経由でbypassできる場合に限り、承認不足による `BLOCKED` を許す。必須checkと未解決threadはbypassしない。

## merge方式はbaseへの追従の仕方も決める

`merge.method` の `squash`、`merge`、`rebase` はGitHubのmerge APIへ渡し、`fast-forward` はbaseのrefを直接headへ進める。`update-branch` はbaseを作業branchへmergeして取り込むので、`squash` と `merge` のときだけ使える。`squash` なら取り込んだmerge commitはbaseに入らず、baseの履歴は一直線のまま保てる。`rebase` と `fast-forward` では、そのmerge commitがそのままbaseの履歴に入り、その方式を選んだ意味が失われるので、`method_incompatible` で止まる。

`fast-forward` はGitHubのmerge判定を経ないので、server側にpolicy以上の保護があることを求める。branch protectionの必須checkが `required_checks` の名前をすべて含み、必要な承認数が `min_approvals` 以上で、未解決threadを求めるならconversation resolutionが必須で、管理者にも保護が当たることである。また `merge.delete_branch: true` が必須である。

`merge.delete_branch` はmerge後にremoteの作業branchを消すか、`merge.delete_worktree` はmerge後にcleanな副worktreeを消すかを決める。後者は `workspace.use_worktree: true` のときだけtrueにできる。

## 作業場所の値

`workspace.use_worktree` はworktreeで作業するか、現在のcheckoutで専用branchを切るかを決める。`workspace.require_clean_start` がtrueなら、開始元に未commitの変更があるとき `plan` と `start` が止まる（`inspect` は止まらない）。`workspace.base_branch` は作業branchの作成元でありPRのbase、`workspace.branch_prefix` は作業branch名に必須の接頭辞、`workspace.worktree_root` はworktreeの親directory（空文字ならOSの一時directory）、`git.remote` はpushとremote branchの照会に使うremote名である。`verification.commands` はcommitの前に記載順に全件成功させるcommand、`pull_request.draft` はPRを下書きで作るかを決める。
