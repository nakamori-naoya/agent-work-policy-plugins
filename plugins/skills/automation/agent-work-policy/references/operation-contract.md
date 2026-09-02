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

## 下流plugin向けCLI契約

このpluginが公開Git操作の唯一の所有者である。たとえばpull-request pluginは、設定を解決して`control.py`を呼ぶだけであり、permission、human gate、検証、readiness、`git` / `gh`の公開操作を再実装しない。

### 入力

1. `bash "$POLICY_ROOT/scripts/prepare.sh" "$TARGET_REPO"` のstdoutで得た、空でない解決済みYAML pathを`--config`へ渡す。`prepare.sh`失敗時はexit `2`として停止する。
2. `--repo`が必要なcommandには公開対象repositoryを渡す。`permission`と`gate`は`--repo`を取らない。
3. actionは`commit`、`push`、`pull_request`、`merge`だけである。各公開commandの追加入力は以下のとおり。

| command | 追加入力 | 実行前に正本が行うこと |
|---|---|---|
| `commit` | `--repo`、`--paths-file`、`--message` | permissionを判定し、pathを限定して設定済み検証を実行してからgateを判定する |
| `push` | `--repo` | permissionを判定し、branchとHEAD SHAを取得してからgateを判定する |
| `pull-request` | `--repo`、`--title`、`--body-file` | permissionを判定し、branch、base、draftを決めてからgateを判定する |
| `merge-readiness` | `--repo`、`--pr` | PRのApprove、checks、thread、base、headを再取得する |
| `merge` | `--repo`、`--pr` | permissionを判定し、readinessを再取得してからgateを判定し、設定されたmethodでmergeする |

### 結果

`argparse`がcommandと必須引数を受理した呼出しでは、stdoutはJSON objectである。`argparse`による入力不備はusageをstderrへ出してexit `2`で終わるため、stdout JSONの保証外である。下流pluginはJSONが返った場合に最低限`status`を読み、成功時だけ後続工程へ進む。成功JSONは`status`に`allowed`、`approved`、`ready`、`committed`、`pushed`、`created`、`merged`のいずれかを持つ。

| exit | 意味 | 下流pluginの扱い |
|---:|---|---|
| 0 | 判定または操作が成功した | stdout JSONの`status`を記録し、成功した判定または操作だけを後続へ渡す |
| 2 | 引数、設定、repository、依存commandが不正 | 公開操作を行わず停止する |
| 3 | permission拒否、承認待ち、readiness不足、検証失敗、操作失敗 | `forbidden`、`waiting_for_human`、`not_ready`、`verification_failed`、`failed`、`merge_failed`、`merged_cleanup_failed`、`no_changes`などを成功へ変換せず停止・報告する |

`waiting_for_human`だけは承認待ちを示すJSONである。人間の承認を取得していない下流pluginは`--approved`を付けない。`merge-readiness`が`not_ready`の間は、下流pluginもhuman gateを提示しない。
実行していない操作、取得できなかったPR状態、失敗したbranch・worktree削除を成功として報告しない。merge後の片付けだけが失敗した場合は`merged_cleanup_failed`として、merge済みであることと残った対象を同時に返す。
