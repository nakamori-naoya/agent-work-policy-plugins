# 公開操作の停止契約

この資料は、各操作がいつ実行され、いつ止まるかを定める。GitHubとの競合状態をどう閉じるかという実装の説明は、`scripts/control.py` の冒頭のコメントにある。

## 判定の順序

操作の前に、permission、merge readiness（mergeだけ）、human gateの順に確かめる。permissionが拒否なら、承認を求めずに止まる。readinessが未充足の間は、mergeの承認を求めない。GitHub reviewのApproveはreadinessの材料であり、human gateの承認ではない。gateは、呼び出しの承認範囲 `approval` が今回のaction・対象・時刻を含むときだけ通る。

## いつ操作し、いつ止まるか

### commit

明示したpathだけを、policyの検証commandを全件通してからcommitする。明示したpathの外が既にindexにあれば、stageする前に止まる。対象に変更が無ければ `no_changes` で止まる。

### push

作業branchのHEADを、GitHubのrepositoryと一致を確かめた単一のpush URLへ、通常のpushで送る。remoteの作業branchが無いか、同じcommitか、local HEADの祖先のときだけ送り、進んでいるか分岐していれば止まる。force pushとbase branchへのpushは提供しない。

### update-branch

baseの現在の先端を、GitHub上で作業branchへmergeして取り込み、localを同じcommitへ進める。working treeがclean、local HEADとremoteの作業branchとPRのheadが一致し、PRがこのrepositoryの作業branchから開いたOPENのPRであるときだけ動く。headが既に先端を含んでいれば、何も変えずに成功する。PRが競合していれば `conflicts` で止まる。merge方式が `rebase` か `fast-forward` なら `method_incompatible` で止まる。pushと同じpermissionとgateに従う。履歴を書き換えないので、他者のpushを上書きしない。

### pull-request

remoteの作業branchがlocal HEADと一致してから、policyのbaseと下書き設定でPRを作る。

### ready-for-review

内部レビューが終わった下書きPRを、レビュー受付の状態にする。既に公開済みなら何も変えずに成功する。新しい公開先もmergeも生まないので、`pull_request` のpermissionだけを使い、gateを持たない。

### merge-readiness

変更せずに、PRがmergeしてよい状態かを返す。headがbaseの現在の先端を含むこと、policyの必須checkがそのheadで成功していること、承認数と未解決threadの条件、PRがOPENで下書きでなくmerge可能であることを確かめる。満たさない条件は名前で返る（`behind_base`、`checks_failed`、`checks_pending`、`checks_missing`、`approvals`、`unresolved_threads` など）。否定的な結果も照会としては成功である。

### merge

readinessを取り直し、満たしていればgateを確かめてから、policyのmerge方式でmergeする。readinessの後でheadやbaseが変わっていれば、変更せずに `merge_failed` で止まる。baseを更新したのにPRへの反映を確認できなければ `merge_partial` を返し、mergeを再実行させない。merge後の片付け（remoteの作業branchと副worktreeの削除）だけが失敗したら、merge済みであることと残ったものを `cleanup_failed` で返す。merge APIを使う方式では、readinessの後にbaseが進む競合が残る。merge APIがheadの照合しか持たず、baseの照合を持たないためである。

### cleanup

merge済みのPRについて、remoteの作業branchと副worktreeを片付ける。remoteのbranchがPRのheadと一致するときだけ消し、既に無ければ成功とする。変更の残る副worktreeは消さない。

## control.pyの呼び出し

公開Git操作の持ち主はこのpackageだけであり、`control.py` を呼ぶのは同じ入口の `scripts/invoke.py` だけである。外部pluginは公開playbookを通してしか操作を要求できない。

`invoke.py` は、`--config` に対象repository rootのpolicy設定fileの絶対path、`--repo` に対象repository、actionごとに `--branch`、`--paths-file` と `--message`、`--title` と `--body-file`、`--pr` を渡す。承認範囲は、形を検査したうえで `--approval` にJSONのまま渡す。範囲の照合はgateを持つ `control.py` が一か所で行い、真偽値の承認は運ばない。policy設定fileは `--repo` のrepository rootにあるものでなければならず、別repositoryの設定は拒否される。

`control.py` は標準出力へJSON objectを1つ返す。成功の `status` は `inspected`、`ready`、`created`、`committed`、`pushed`、`updated`、`merged`、`cleaned` のどれかで、`update-branch` と `ready-for-review` の結果は外部を変えたかを `changed` で示す。終了codeは、0が成功、2が引数・設定・repositoryの不備（操作前に停止）、3がpermission拒否・承認待ち・readiness未充足・検証失敗・競合・操作失敗、4がbase更新後にPR反映を確認できない `merge_partial` である。

`invoke.py` はこの内部の結果を公開の語彙へ写し、内部の `status` 名と終了codeをそのまま外へ出さない。成功は `completed`、承認待ちは `waiting_for_human`、それ以外は `failed` になる。`forbidden` は `permission_denied`、`not_ready` は `not_ready`（merge-readinessの照会では `completed`）、`verification_failed`、`no_changes`、`conflicts`、`method_incompatible`、`merge_partial`、`merge_failed` はそれぞれ同名、`merged_cleanup_failed` は `cleanup_failed`、それ以外の失敗と操作前の不備は `error` になる。公開の語彙に写らない内部の理由は `detail` に添える。
