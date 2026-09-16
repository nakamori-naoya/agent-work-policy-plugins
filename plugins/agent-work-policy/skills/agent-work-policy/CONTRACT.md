# agent-work-policy 契約 v1

この文書は、**外部 plugin から `agent-work-policy` を使うときに頼ってよいものの全部**である。ここに書いていない振る舞いは契約ではない。

| 項目 | 値 |
|---|---|
| 契約 ID | `agent-work-policy/agent-work-policy` |
| 版 | 1 |
| kind | `playbook` |
| playbook 名 | `agent-work-policy` |

提供側は自分の `plugin.json` の `metadata.harness.implements[]` に `{id: agent-work-policy/agent-work-policy, version: 1, kind: playbook, playbook: agent-work-policy, actions: [<実装する action>]}` を宣言する。消費側が要求できる action はこの `actions` にある値だけである。**消費側の `requires` は書き換えない。**

## 1. 入口

消費側の`playbook.yml`から`steps[].playbook: agent-work-policy`で呼び、stepの`input`へ§2のobjectを渡す。providerは同じ呼び出しの結果として§3のobjectを直接返す。

消費側はproviderのroot、entry file、policy設定path、内部scriptを参照または実行しない。policy設定の読み取りはproviderの責務である。外部依存は`skill:`または`script:`stepで指さない。

`plugin.json`の`implements[]`にある契約ID、version、playbook、actionsと、`playbook.yml`の`contract`宣言が機械可読な入口正本である。`contract.invocation.input`と`output`はどちらも`object`である。

### 1.1 公開入口検査の宣言

- 正本: `plugin.json`の`metadata.harness.implements[]`と`playbook.yml`の`contract`
- 入力: 公開入口directoryと、標準入力から受け取るJSON object、対象repositoryのpolicy設定file
- 正規化: action名は宣言値と完全一致で比較し、repositoryとaction固有pathはrealpathへ正規化する。policy設定fileはrepository rootから固定名で解決する
- 述語: 宣言したcontract ID・version・actions・object入出力・entryが一致し、entryが入力schemaを満たす1 actionとschemaを満たすpolicyだけを内部policy実行へ渡す
- 診断: 不正な公開入力はGit/gh操作前に`status: failed`、`reason: invalid_input`で返し、policy設定fileの不在は`reason: policy_missing`、内部実行の失敗は§3.4の公開語彙へ写す
- 正例・反例・境界例: `scripts/validate.sh`が直接`inspect`、未知キー、旧`output_to`、不正action、policy不在、gate待ちとpermission拒否を検査する
- 意味評価の境界: 機械検査は宣言と実体の接続、schema、操作前停止、公開結果形を判定する。承認対象の十分性や各repositoryのpolicyが依頼意図に妥当かは利用時に人が判断する

## 2. 入力 — 1 呼び出し 1 action

入力はplaybook呼び出しへobjectとして直接渡す。providerが入力schemaを検査してからpolicyを内部解決する。

契約 ID・版の不一致、宣言に無い `action`、
その action の必須キーの欠落、**その action が使わないキー**、未知のキー、値の形の誤り、
対象外のrepositoryは、いずれも操作を1つも実行せず`status: failed`、`reason: invalid_input`で返す。

`repo`とaction固有のpathはrealpathで正規化してから境界を検査する。

**次はキーの一覧であって、1 回の呼び出しの例ではない。** 実際に渡すのは共通4キーと、その action の追加入力だけである。

```yaml
contract: agent-work-policy/agent-work-policy
version: 1
action: pull-request                 # 必須。§2.1 のいずれか1つ
repo: /Users/me/src/acme             # 必須。対象repositoryの絶対path
approved: false                      # 任意。既定 false
branch: agent/fix-order-cancel       # plan / start
paths:                               # commit
  - src/order/cancel.py
message: "取消の締切を出荷日基準へ揃える"     # commit
title: "取消の締切を出荷日基準へ"             # pull-request
body_file: /var/folders/x/body.md            # pull-request
pr: 1234                                     # ready-for-review / merge-readiness / merge / cleanup
```

| 名前 | 型 | 必須 | 対象 action |
|---|---|---|---|
| `contract` | string | ○ | 全部。`agent-work-policy/agent-work-policy` 固定 |
| `version` | int | ○ | 全部。`1` 固定 |
| `action` | string | ○ | 全部。宣言に無い値は`status: failed`、`reason: invalid_input` |
| `repo` | 絶対 path | ○ | 全部 |
| `approved` | bool | 任意 | gate のある action（`commit` / `push` / `pull-request` / `merge`） |
| `branch` | string | △ | `plan` / `start` |
| `paths` | string[] | △ | `commit`。repository root からの相対 path |
| `message` | string | △ | `commit` |
| `title` | string | △ | `pull-request` |
| `body_file` | 絶対 path | △ | `pull-request` |
| `pr` | int | △ | `ready-for-review` / `merge-readiness` / `merge` / `cleanup` |

**「対象 action」の列は、そのキーを書いてよい action の全部である。** 対象外の action へ渡した
キーは未知のキーとして拒否する（`push` に `title` を添える、`commit` に `pr` を添える、など）。
値の形は次を満たすこと。`version` は整数 `1`、`approved` は真偽値、`pr` は正の整数、
`repo` は実在する directory の絶対 path、`body_file` は実在する regular file の絶対 path、
`paths` は repository root からの相対 path の非空配列（各要素はLF・CR・Unicode行区切りを含む
行境界と前後空白を含まず、
`..` を含まない、重複しない）。要素内部の通常空白やTABはpathの一部として同一のまま扱い、
入口と内部処理の間で分割・trimしない。
`branch` / `message` / `title` は空でない1行の文字列。

`approved: true` は、**実際に人間の承認を得た再呼び出しにだけ**付ける。承認を得ていない呼び出しへ付けない。

### 2.1 action

`plugin.json` の `metadata.harness.implements[].actions` が正本である。v1 の値は次の 10 個。

| action | 意味 | 追加入力 | human gate |
|---|---|---|---|
| `inspect` | **read-only の照会。** いまの `workspace` と状態（作業 branch、working tree が clean か、base branch の有無、その branch へ開いている PR 番号）を返す。何も変更しない | — | 無し |
| `plan` | 作業を開始してよいか（開始元の状態、branch 名、base の存在）を判定する | `branch` | 無し |
| `start` | 設定に従って worktree または branch を作り、作業場所を返す | `branch` | 無し |
| `commit` | 明示した path だけを、設定された検証を通してから commit する | `paths`、`message` | 有り |
| `push` | 検査済みの単一 push URL へ作業 branch を送る | — | 有り |
| `pull-request` | base と draft 設定に従って PR を作る | `title`、`body_file` | 有り |
| `ready-for-review` | 下書き PR をレビュー受付状態にする | `pr` | 無し |
| `merge-readiness` | PR が merge 可能な機械状態かを判定する（変更しない） | `pr` | 無し |
| `merge` | readiness 充足後に、設定された method で merge する | `pr` | 有り |
| `cleanup` | merge 済み PR の remote branch と副 worktree を片付ける | `pr` | 無し |

**`inspect` は `plan` の代わりではない。** `inspect` は「いま何がどうなっているか」を返すだけなので、既存の作業 branch にいても、working tree が汚れていても停止しない。`plan` は「新しい作業を始めてよいか」の判定なので、同じ状況では `not_ready` / `failed` で止まる。**状況を知りたいだけのときに `plan` を使わない。**

**1 呼び出しにつき action は 1 つだけ**である。複数の操作をまとめて要求しない。消費側は必要な操作ごとに step を分ける。

**この契約に検証（verify）の action は無い。** 変更内容の検証は依頼側の仕事であり、`commit` は自分の設定に書かれた検証を実行直前に自分で通す。

## 3. 出力

次のobjectを呼び出し元へ直接返す。

```yaml
contract: agent-work-policy/agent-work-policy
version: 1
action: pull-request
status: waiting_for_human            # completed | waiting_for_human | failed
gate_state: waiting_for_human        # allowed | waiting_for_human | denied
approval_target:                     # status: waiting_for_human のときだけ
  gate: before_pull_request
  summary: "3 files changed, 42 insertions(+), 7 deletions(-)"
  target: "agent/fix-order-cancel -> main"
  detail_path: /var/folders/x/gate-detail.txt
operation_result:                    # 操作が返した公開結果
  pull_request: 1234
  url: https://github.com/acme/app/pull/1234
workspace:                           # 常に返す
  base_branch: main
  remote: origin
  draft: true
  branch: agent/fix-order-cancel
  worktree: /Users/me/src/acme-worktrees/agent-fix-order-cancel
reason: ""                           # status: failed のときだけ非空
```

| 名前 | 型 | 必須 | 意味 |
|---|---|---|---|
| `contract` / `version` / `action` | | ○ | 入力と同じ値を返す |
| `status` | string | ○ | `completed` / `waiting_for_human` / `failed` |
| `gate_state` | string | ○ | `allowed` / `waiting_for_human` / `denied` |
| `approval_target` | object | △ | `waiting_for_human` のときだけ。**承認の対象そのもの** |
| `operation_result` | object | ○ | actionごとの観測結果。実行していない操作を成功として含めない |
| `workspace` | object | ○ | **常に返す**。§3.3 |
| `reason` | string | ○ | `failed` のときだけ非空。§3.4 |

### 3.1 承認待ち（`waiting_for_human`）

`status: waiting_for_human` は失敗ではない。「permission は通ったが、人間の承認が要る」状態である。消費側は次を守る。

1. `approval_target` を利用者へ提示して、承認を求める。
2. 承認を**実際に得た**ときだけ、`approved: true` を付けて**同じ action を再度呼ぶ**。
3. 承認が得られなければ、その action を実行済みとして扱わない。

`approval_target`は`gate`と、操作対象を識別できるaction固有値を持つ。たとえばcommitならbranch・paths・message・verification、pull-requestならrepository・branch・base・title、mergeならPR番号・URL・head SHA・baseを返す。固定した表示用文字列や内部file pathで対象を代理しない。

### 3.2 `operation_result`

| action | `operation_result` の内容 |
|---|---|
| `inspect` | `{mode, clean, base_branch_exists, pull_request}`。`pull_request` は開いている PR 番号、無いか確認できなければ `null` |
| `plan` | `{mode, branch, base_branch, clean}` |
| `start` | `{mode, branch, worktree}` |
| `commit` | `{branch, sha, paths}` |
| `push` | `{branch, sha, remote}` |
| `pull-request` | `{pull_request, url, draft}` |
| `ready-for-review` | `{pull_request, changed}` |
| `merge-readiness` | `{pull_request, ready, unmet}` |
| `merge` | `{pull_request, merged, method, sha}` |
| `cleanup` | `{pull_request, branch_deleted, worktree_deleted}` |

`merge-readiness` と `inspect` は**問い合わせ**である。readiness が未充足でも、working tree が汚れていても、`status: completed` を返す。`merge-readiness` は `operation_result.ready: false` と `unmet`（未充足の条件名）を、`inspect` は `operation_result.clean: false` を返す。**問い合わせの結果が否定的であることを失敗として返さない。**

### 3.3 `workspace` — 常に返す

消費側が提供側の設定ファイルを読まなくて済むように、毎回返す。

| 名前 | 型 | 意味 |
|---|---|---|
| `base_branch` | string | 作業 branch の作成元であり、PR の base |
| `remote` | string | push と remote branch 操作に使う remote 名 |
| `draft` | bool | PR を下書きとして作る設定か |
| `branch` | string \| null | この呼び出しの作業 branch。未確定なら `null` |
| `worktree` | 絶対 path \| null | 作業場所。branch mode または未開始なら `null` |

消費側はこの 5 つだけで、差分の確認先・既存 PR の照合先・公開後に必要な後続操作を決められる。**提供側の設定ファイル、設定キー、既定値を読まない。**

### 3.4 `reason`

`status: failed` のときだけ非空にする。値は次の語彙に固定する。

| `reason` | 意味 | 消費側の扱い |
|---|---|---|
| `permission_denied` | 操作そのものが許可されていない | 承認質問へ変えない。停止して報告する |
| `not_ready` | merge readiness が未充足 | human gate を提示しない。状態が変わるまで待つ |
| `verification_failed` | 設定された検証が失敗した | 成功として扱わない |
| `no_changes` | 対象に変更が無い | commit 済みとして扱わない |
| `invalid_input` | 入力が契約に合わない | 入力を直して呼び直す |
| `policy_missing` | 対象repositoryにpolicy設定file（§5）が無い | 利用者がrepositoryへpolicy設定を置く。消費側は補わない |
| `merge_partial` | base 更新後に PR 反映を確認できない | **merge を再実行しない。** 状態確認後に `cleanup` だけを再開する |
| `merge_failed` | merge が失敗し、base も head も更新前のまま | 停止して報告する |
| `cleanup_failed` | merge は成功したが片付けが失敗した | merge 済みと残存物を分けて報告する |
| `error` | 上記以外の失敗 | 停止して報告する |

`permission_denied` のとき `gate_state` は `denied` になる。**permission 拒否を承認質問へ変えない。**

## 4. 保証

| # | 保証 |
|---|---|
| AP1 | 設定は system・利用者・実行環境の権限を増やさない |
| AP2 | 素の `git` / `gh` で内部制御を迂回しない |
| AP3 | permission と human gate を action ごとに個別に適用する |
| AP4 | `approved` が偽のまま gate 必須の action を実行せず、`waiting_for_human` と `approval_target` を返す |
| AP5 | 依頼範囲外の差分を自分の変更へ含めない |
| AP6 | 失敗は停止する。部分的に実行して成功を報告しない |
| AP7 | `workspace` を常に返し、消費側が提供側の設定を読まなくて済むようにする |
| AP8 | 結果objectを直接返し、repository の policy 設定を読むだけで実行設定を作らない |
| AP9 | 1 呼び出しで実行する action は 1 つだけである |

## 5. 利用者設定 — 公開契約の一部

**policy の設定ファイルは利用者向けの公開契約である。** 何を許し、何に承認を要求するかを決めるのは
利用者であり、この plugin の内部事情ではない。だからファイル名と schema をここで固定する。

**これは plugin 間依存ではない。** 消費側 plugin はこのファイルを読まないし、書かないし、
自分の playbook.yml・SKILL.md・README でこのキーを語らない（§6）。消費側 repository の
`.harness-plugins/` にこのファイルを置くのは、その repository の**利用者**である。
消費側が提供側の設定を読まなくて済むように、実行時に必要な値は出力の `workspace` で返す（§3.3、AP7）。

| 層 | 置き場 |
|---|---|
| repository | `<repo>/.harness-plugins/agent-work-policy.config.yml` |

**層はこの1つだけである。** 利用者の個人設定、端末固有設定、同梱既定への fallback は無い。方針は repository が所有し、
実行者の個人設定で緩められない。ファイルが無ければ操作を行わず `status: failed`、`reason: policy_missing` を返す。
schema に無いキー、欠けたキー、型違いは `reason: error` と診断で止まる。記入例は入口の `assets/policy.example.yml` にある。

### 5.1 schema

schema に無いキーと欠けたキーは受け付けない。v1 のキーは次で全部であり、すべて必須である。

| キー | 型 | 意味 |
|---|---|---|
| `version` | int | 設定 schema の版。`1` |
| `workspace.use_worktree` | bool | 副 worktree を作るか。false なら branch を切る |
| `workspace.require_clean_start` | bool | 開始時に working tree が clean であることを要求するか |
| `workspace.base_branch` | string | 作業 branch の作成元であり、PR の base |
| `workspace.branch_prefix` | string | 作業 branch 名の接頭辞 |
| `workspace.worktree_root` | string | 副 worktree の置き場。空なら OS の一時 directory |
| `git.remote` | string | push と remote branch 操作に使う remote 名 |
| `permissions.commit` | bool | commit を許すか。**false は人間の承認でも上書きできない** |
| `permissions.push` | bool | push を許すか |
| `permissions.pull_request` | bool | PR 作成を許すか |
| `permissions.merge` | bool | merge を許すか |
| `gates.before_commit` | bool | commit 直前に人間の明示承認を要求するか |
| `gates.before_push` | bool | push 直前に人間の明示承認を要求するか |
| `gates.before_pull_request` | bool | PR 作成直前に人間の明示承認を要求するか |
| `gates.before_merge` | bool | merge 直前に人間の明示承認を要求するか |
| `verification.commands` | string[] | commit 直前に全て成功させる検証コマンド |
| `pull_request.draft` | bool | PR を下書きとして作るか |
| `merge.method` | string | merge の方法 |
| `merge.delete_branch` | bool | merge 後に remote branch を消すか |
| `merge.delete_worktree` | bool | merge 後に副 worktree を消すか |
| `merge.readiness.min_approvals` | int | merge gate を提示してよい最小承認数 |
| `merge.readiness.require_checks_passed` | bool | required check の成功を要求するか |
| `merge.readiness.require_no_unresolved_threads` | bool | 未解決 thread が無いことを要求するか |

**permission と gate は別物である。** `permissions.*` が false なら、その操作は承認を得ても実行しない
（`reason: permission_denied`）。`gates.*` が true なら、permission は通ったうえで人間の承認を待つ
（`status: waiting_for_human`）。**permission 拒否を承認質問へ変えない。**

## 6. 非契約 — 頼ってはいけないもの

次はいつでも変わる。消費側の playbook.yml、SKILL.md、README、references、scripts、設定のどこにも書かない。

- 内部 script の存在・名前・引数・サブコマンド名・stdout の形（`control.py` を消費側から直接実行する手順を含む）
- 内部 script の exit code
- **消費側が**設定ファイルを読むこと・書くこと・そのキーを語ること（`workspace.base_branch`、`git.remote`、
  `pull_request.draft` など）。ファイル名と schema は§5 のとおり**利用者**向けの公開契約であって、
  消費側 plugin が触ってよい面ではない。実行時に必要な値は出力の `workspace` から読む
- `references/` の文書とその節
- worktree の作り方、branch 名の組み立て方、readiness の判定手順
- 工程 id
