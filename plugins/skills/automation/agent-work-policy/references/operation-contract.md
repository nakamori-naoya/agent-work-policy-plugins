# 公開操作の停止契約

このreferenceは、`control.py`がcommit、push、PR作成、mergeを実行してよい条件と返り値を定める。

## 3つの条件

| 条件 | 意味 | 上書き |
|---|---|---|
| permission | 操作そのものが許されているか | できない |
| human gate | 操作直前に依頼者の明示承認が必要か | 実際の承認後だけ`--approved`で通る |
| merge readiness | PRがmerge可能な機械状態か | 状態が変わるまで通らない |

順番は`permission → readiness（mergeだけ）→ gate → 操作`である。permission拒否を承認質問へ変えない。
readiness未充足の間はmerge承認を求めない。GitHub reviewのApproveはreadinessの材料であり、human gateの承認ではない。

## 操作ごとの入力

- commit: 明示したpath、message、検証結果を使う。path外をstageしない。
- push: 現在の作業branchと設定remoteを使う。force pushとbase branch pushを提供しない。
- pull-request: title、body file、作業branch、base branch、draft設定を使う。
- merge: PR番号、head SHA、methodを使う。ready判定後も操作直前に状態を再取得し、成功後は設定に従ってremote branchと副worktreeを片付ける。

scriptが`waiting_for_human`を返した場合だけ、対象を提示して承認を求める。承認を得ていない呼出しへ
`--approved`を付けない。`forbidden`、`not_ready`、`verification_failed`を成功として扱わない。

## exit contract

| exit | 意味 |
|---:|---|
| 0 | 判定または操作が成功した |
| 2 | 引数、設定、repository、依存commandが不正 |
| 3 | permission拒否、承認待ち、readiness不足、操作失敗 |

stdoutのJSONから`status`、対象、停止理由を読む。exit 3は「問題なし」でも「確認済み」でもない。
実行していない操作、取得できなかったPR状態、失敗したbranch・worktree削除を成功として報告しない。
merge後の片付けだけが失敗した場合は`merged_cleanup_failed`として、merge済みであることと残った対象を同時に返す。
