# agent-work-policy 契約 v1

この文書は、**外部 plugin から `agent-work-policy` を使うときに頼ってよいものの全部**である。ここに書いていない振る舞いは契約ではない。

| 項目 | 値 |
|---|---|
| 契約 ID | `agent-work-policy/agent-work-policy` |
| 版 | 1 |
| kind | `playbook` |
| playbook 名 | `agent-work-policy` |

## 1. 入口

消費側の `playbook.yml` からは `steps[].playbook: agent-work-policy` で呼ぶ。解決結果 `deps.<論理名>` から参照してよいのは次の 4 点だけである。

| # | 参照形 | 用途 |
|---|---|---|
| E1 | `${.deps.<論理名>.root}/scripts/prepare.sh` | 入力を渡して実行設定を解決する |
| E2 | `${.deps.<論理名>.root}/playbook.yml` | 段取りの宣言を読む |
| E3 | `${.deps.<論理名>.root}/scripts/resolve.sh` | `prepare.sh` が内部で呼ぶ入口 |
| E4 | `${.deps.agent-work-policy.entry}` | この playbook 入口の `SKILL.md` の絶対 path。実行手順はここに従う |

これ以外の path を `root` から組み立てない。`skill:` / `script:` step でこの plugin を指さない。

**呼び出し手順は「E1 で解決 → その path を E4 へ渡す」である。** 消費側は E1 が返した解決済み YAML の絶対 path を、そのまま E4 の入口 SKILL.md へ渡す。**入口 SKILL.md は受け取った path をそのまま使い、`prepare.sh` を再実行しない。** 再実行すると入口が決めた `--scope` と `--bindings` の lock が捨てられ、同じ 1 回の呼び出しに実行設定が二重にできる。実行設定の後始末は、E1 を呼んだのが消費側であってもagent-work-policy が行う（AP8）。

**`.deps.<論理名>` から組み立ててよいのは `.root`（許された suffix 付き）と `.entry` だけである。**
`entry` は `implements[]` のうち契約 ID が一致する要素の `playbook` が指す directory の `SKILL.md` である。
`entryRoot` は契約の解決に使わない。`.deps.<論理名>.skills.<名前>` を組み立てるのは**禁止**であり、消費側 lint と resolver が `external-dependency-path` として落とす。

`entry_skill`（入口 SKILL.md の frontmatter `name`。ここでは `work-with-policy`）は**表示用**である。**その名前で分岐しない。** 名前が変わっても呼び出し方は変わらない。

**参照はドット形で書く。** `.deps` の後ろを角かっこと引用符で綴るブラケット形も lint が落とす。

## 2. 入力 — 1 呼び出し 1 action

入力は YAML ファイル 1 本に書き、`prepare.sh --input=<絶対path>` で渡す。

**この schema の検査は E1 の入口で行われる。** 契約 ID・版の不一致、宣言に無い `action`、
その action の必須キーの欠落、**その action が使わないキー**、未知のキー、値の形の誤り、
書けない `output_to` は、いずれも操作を1つも実行せずに exit 2 で止まる。
診断は stderr へ `[error:input-schema] key=value` の形で出る。

**path は realpath で正規化してから検査する。** `--input` の絶対 path と `output_to` の親 directory は、
祖先に symlink を含んでいてよい（macOS 既定の `TMPDIR`＝`/var/folders/...` をそのまま渡せる）。
解決済み設定に載る `output_to` は正規化後の絶対 path である。

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
output_to: /var/folders/x/policy-output.yml  # 必須
```

| 名前 | 型 | 必須 | 対象 action |
|---|---|---|---|
| `contract` | string | ○ | 全部。`agent-work-policy/agent-work-policy` 固定 |
| `version` | int | ○ | 全部。`1` 固定 |
| `action` | string | ○ | 全部。宣言に無い値は exit 2 |
| `repo` | 絶対 path | ○ | 全部 |
| `approved` | bool | 任意 | gate のある action（`commit` / `push` / `pull-request` / `merge`） |
| `branch` | string | △ | `plan` / `start` |
| `paths` | string[] | △ | `commit`。repository root からの相対 path |
| `message` | string | △ | `commit` |
| `title` | string | △ | `pull-request` |
| `body_file` | 絶対 path | △ | `pull-request` |
| `pr` | int | △ | `ready-for-review` / `merge-readiness` / `merge` / `cleanup` |
| `output_to` | 絶対 path | ○ | 全部 |

**「対象 action」の列は、そのキーを書いてよい action の全部である。** 対象外の action へ渡した
キーは未知のキーとして拒否する（`push` に `title` を添える、`commit` に `pr` を添える、など）。
値の形は次を満たすこと。`version` は整数 `1`、`approved` は真偽値、`pr` は正の整数、
`repo` は実在する directory の絶対 path、`body_file` は実在する regular file の絶対 path、
`paths` は repository root からの相対 path の非空配列（`..` を含まない、重複しない）、
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

`output_to` の絶対 path へ、次の YAML を書く。

```yaml
contract: agent-work-policy/agent-work-policy
version: 1
action: pull-request
status: waiting_for_human            # completed | waiting_for_human | failed
gate_state: waiting_for_human        # allowed | waiting_for_human | denied
gate_context:                        # status: waiting_for_human のときだけ
  gate: before_pull_request
  summary: "3 files changed, 42 insertions(+), 7 deletions(-)"
  target: "agent/fix-order-cancel -> main"
  detail_path: /var/folders/x/gate-detail.txt
result:                              # status: completed のときだけ
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
| `gate_context` | object | △ | `waiting_for_human` のときだけ。**承認の対象そのもの** |
| `result` | object | △ | `completed` のときだけ。action ごとの結果（§3.2） |
| `workspace` | object | ○ | **常に返す**。§3.3 |
| `reason` | string | ○ | `failed` のときだけ非空。§3.4 |

### 3.1 承認待ち（`waiting_for_human`）

`status: waiting_for_human` は失敗ではない。「permission は通ったが、人間の承認が要る」状態である。消費側は次を守る。

1. `gate_context` を利用者へ提示して、承認を求める。
2. 承認を**実際に得た**ときだけ、`approved: true` を付けて**同じ action を再度呼ぶ**。
3. 承認が得られなければ、その action を実行済みとして扱わない。

| `gate_context` の名前 | 型 | 意味 |
|---|---|---|
| `gate` | string | どの地点の承認か |
| `summary` | string | 承認対象の1行要約（変更規模、対象 PR など） |
| `target` | string | 何がどこへ向かうか（`<branch> -> <base>`、`PR #<n>` など） |
| `detail_path` | 絶対 path | 差分・検証結果・readiness など、提示に使う詳細の全文 |

### 3.2 `result`

| action | `result` の内容 |
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

`merge-readiness` と `inspect` は**問い合わせ**である。readiness が未充足でも、working tree が汚れていても、`status: completed` を返す。`merge-readiness` は `result.ready: false` と `unmet`（未充足の条件名）を、`inspect` は `result.clean: false` を返す。**問い合わせの結果が否定的であることを失敗として返さない。**

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
| AP4 | `approved` が偽のまま gate 必須の action を実行せず、`waiting_for_human` と `gate_context` を返す |
| AP5 | 依頼範囲外の差分を自分の変更へ含めない |
| AP6 | 失敗は停止する。部分的に実行して成功を報告しない |
| AP7 | `workspace` を常に返し、消費側が提供側の設定を読まなくて済むようにする |
| AP8 | `output_to` へ出力 YAML を書き、実行設定の後始末を自分で行う |
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
| 利用者 | `~/.config/harness-plugins/work-policy-control.config.yml` |
| repository | `<repo>/.harness-plugins/work-policy-control.config.yml` |
| repository（commit しない端末固有値） | `<repo>/.harness-plugins/work-policy-control.local.yml` |

**ファイル名は `work-policy-control.config.yml` である。** `agent-work-policy.config.yml` は
公開 playbook の段取り設定であり、別のファイルである。旧名のまま残すと解決が停止する。

### 5.1 schema

同梱既定に無いキーは受け付けない（exit 2）。v1 のキーは次で全部である。

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
| `instructions.execution.directive` | string | 実行時に最初に従う指示文 |

**permission と gate は別物である。** `permissions.*` が false なら、その操作は承認を得ても実行しない
（`reason: permission_denied`）。`gates.*` が true なら、permission は通ったうえで人間の承認を待つ
（`status: waiting_for_human`）。**permission 拒否を承認質問へ変えない。**

## 6. 非契約 — 頼ってはいけないもの

次はいつでも変わる。消費側の playbook.yml、SKILL.md、README、references、scripts、設定のどこにも書かない。

- 内部 script の存在・名前・引数・サブコマンド名・stdout の形（`control.py`、`run-config.py`、`prepare.sh` を消費側から直接実行する手順を含む）
- 内部 script の exit code
- 内部 plugin 名と内部 skill 名
- **消費側が**設定ファイルを読むこと・書くこと・そのキーを語ること（`workspace.base_branch`、`git.remote`、
  `pull_request.draft` など）。ファイル名と schema は§5 のとおり**利用者**向けの公開契約であって、
  消費側 plugin が触ってよい面ではない。実行時に必要な値は出力の `workspace` から読む
- `references/` の文書とその節
- worktree の作り方、branch 名の組み立て方、readiness の判定手順
- 工程 id、保存モード名、状態ファイルの形式
