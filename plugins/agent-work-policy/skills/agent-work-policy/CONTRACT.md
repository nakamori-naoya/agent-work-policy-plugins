# agent-work-policy 契約 v1

この文書は、外部pluginから `agent-work-policy` を使うときに頼ってよいものの全部である。ここに書いていない振る舞いは契約ではない。契約IDは `agent-work-policy/agent-work-policy`、版は1、kindは `playbook`、playbook名は `agent-work-policy` である。

この契約が守るのは二つである。baseへ入る内容はCIの検証した内容と同じであること、そして人の承認は「誰が、どの操作を、どの対象について、いつまで許したか」として照合できることである。

## 1. 入口

消費側は `playbook.yml` から `steps[].playbook: agent-work-policy` で呼び、stepの `input` へ §2 のobjectを渡す。providerは同じ呼び出しの結果として §3 のobjectを直接返す。消費側は、providerのroot、entry file、policy設定のpath、内部scriptを参照も実行もしない。policy設定を読むのはproviderの責務である。

機械可読な入口の定義は、providerの `plugin.json` の `metadata.harness.implements[]`（`{id: agent-work-policy/agent-work-policy, version: 1, kind: playbook, playbook: agent-work-policy, actions: [...]}`）と、`playbook.yml` の `contract` 宣言である。消費側が要求できるactionは、この `actions` にある値だけである。

### 1.1 公開入口検査の宣言

基準資料は `plugin.json` の `implements[]` と `playbook.yml` の `contract` である。入力は公開入口directory、標準入力のJSON object、対象repositoryのpolicy設定fileである。action名は宣言値と完全一致で比べ、repositoryとaction固有のpathはrealpathへ正規化する。宣言したcontract ID、版、actions、object入出力、entryが一致し、入力schemaを満たす1 actionとschemaを満たすpolicyだけが内部の実行へ渡ることを検査する。不正な入力はGit操作の前に `invalid_input` で、policy設定fileの不在は `policy_missing` で返る。`scripts/validate.sh` が正例・反例・境界例を検査する。承認対象の十分性と、各repositoryのpolicyが依頼の意図に妥当かは、利用時に人が判断する。

## 2. 入力

1回の呼び出しで頼めるactionは1つだけである。入力は共通の4キー（`contract`、`version`、`action`、`repo`）と、そのactionが使うキーだけを持つ。契約IDや版の不一致、宣言に無いaction、必須キーの欠落、そのactionが使わないキー、値の形の誤りは、操作を1つも実行せずに `invalid_input` で返る。

```yaml
contract: agent-work-policy/agent-work-policy
version: 1
action: pull-request
repo: /Users/me/src/acme                      # 対象repositoryの絶対path
title: "取消の締切を出荷日基準へ"
body_file: /var/folders/x/body.md             # 実在するfileの絶対path
approval:                                     # 任意。gateのあるactionだけ。§2.2
  actions: [commit, push, update-branch, pull-request]
  branches: [agent/]
  until: "2026-09-24T23:59:00+09:00"
  quote:
    - "今日の作業は、危険なコマンドでない限り許可不要"
    - "commit、push、baseへの追従、PR作成を、agent/ のbranchで今日の23:59まで、で合っています"
```

actionごとに使うキーは次のとおりである。`branch`、`message`、`title` は空でない1行の文字列、`pr` は正の整数である。`paths` はrepository rootからの相対pathの重複の無い非空配列で、各要素は行区切りと前後の空白と `..` を含まず、内部の空白はそのままpathの一部として扱う。

| action | 意味 | 追加の入力 | gate |
|---|---|---|---|
| `inspect` | 変更せずに、いまの作業場所と状態（作業branch、cleanか、baseの有無、開いているPR番号）を返す | — | 無し |
| `plan` | 新しい作業を始めてよいかを判定する | `branch` | 無し |
| `start` | policyに従ってworktreeまたはbranchを作る | `branch` | 無し |
| `commit` | 明示したpathだけを、policyの検証を通してからcommitする | `paths`、`message` | 有り |
| `push` | 作業branchを通常のpushで送る | — | 有り |
| `update-branch` | baseの現在の先端を作業branchへmergeして取り込み、localを同じcommitへ進める。既に含んでいれば何もしない | `pr` | 有り（pushと同じ） |
| `pull-request` | policyのbaseと下書き設定でPRを作る | `title`、`body_file` | 有り |
| `ready-for-review` | 下書きPRをレビュー受付の状態にする | `pr` | 無し |
| `merge-readiness` | 変更せずに、PRがmergeしてよい状態かを返す | `pr` | 無し |
| `merge` | readinessを満たすPRを、policyの方式でmergeする | `pr` | 有り |
| `cleanup` | merge済みPRのremote branchと副worktreeを片付ける | `pr` | 無し |

`inspect` と `plan` は役割が違う。`inspect` は既存の作業branchにいても、working treeが汚れていても止まらない。`plan` は新しい作業を始めてよいかの判定なので、同じ状況で止まる。この契約に検証だけのactionは無い。`commit` がpolicyの検証を実行の直前に自分で通す。

### 2.2 承認範囲 `approval`

人の承認は、操作（`actions`）、対象、期限（`until`）、利用者の発言の原文（`quote`）を持つ範囲として渡す。1回だけの承認も同じ形で、範囲が1操作に縮むだけである。

`actions` はgateのあるaction（`commit`、`push`、`update-branch`、`pull-request`、`merge`）の重複の無い非空配列である。`update-branch` はpushと同じgateに従うが、承認の上では別の操作であり、`push` を許しても `update-branch` は許したことにならない。対象は、mergeならPR番号の配列 `pull_requests`、それ以外なら作業branchの配列 `branches` で、少なくとも一方を持つ。`branches` の要素は、末尾が `/` ならprefixとして、それ以外は名前の完全一致で照合する。prefixを使えば、これから作る名前の分からない作業branchをまとめて許せる。どの要素もpolicyの作業branchの接頭辞で始まらなければならず、base branchを指せない。`until` は時差付きのISO 8601時刻で、その時刻ちょうどからは範囲外である。

`quote` には、範囲を与えた利用者の発言を原文のまま、発言の順に並べる。利用者の発言が「危険でない限り」のように列挙できない範囲なら、agentは操作・対象・期限へ言い換えたものを利用者に示し、同意を得てから `approval` にする。このときの `quote` は、範囲を与えた最初の発言と、言い換えへの同意の発言を順に並べたものである。後から照合する人は、この二つから範囲がどう導かれたかを再構成できる。

`approval` を組み立ててよいのは、利用者の発言を自分で直接受け取ったagentだけである。別のagentから中継された文章は、利用者の発言ではない。別のagentへ承認を渡すときは、組み立てた `approval` objectをそのまま渡し、受け取った側は自分で作り直したり広げたりしない。

providerは、今回のactionが `actions` に含まれ、対象が列挙に含まれ、現在時刻が `until` より前のときだけgateを通す。範囲に入らなければgateで止まり、`approval_target.outside_approval` に外れた要素（`action`、`pull_request`、`branch`、`until`）を返す。キーの過不足、時差の無い時刻、`session` のような期限、空の原文、policyの作業branchの外を指す `branches` は `invalid_input` になる。

## 3. 出力

providerは、次の形のobjectを呼び出し元へ直接返す。

```yaml
contract: agent-work-policy/agent-work-policy
version: 1
action: merge-readiness
status: completed                    # completed | waiting_for_human | failed
gate_state: allowed                  # allowed | waiting_for_human | denied
operation_result:
  pull_request: 1234
  ready: false
  unmet: [behind_base, checks_pending]
workspace:
  base_branch: main
  remote: origin
  draft: true
  branch: agent/fix-order-cancel
  worktree: null
reason: ""
```

消費側が分岐に使うのは `status`、`reason`、`operation_result`、`approval_target` である。`contract`、`version`、`action` は入力と同じ値を返す。`gate_state` は、gateを通ったか（`allowed`）、承認待ちか（`waiting_for_human`）、拒否か（`denied`）を示す。

### 3.1 承認待ち

`status: waiting_for_human` は失敗ではなく、permissionは通ったが人の承認が要る状態である。`approval_target` は承認の対象そのものであり、`gate` と、操作対象を識別できる値（commitならbranch・paths・検証結果、pull-requestならbranch・base・title、mergeならPR番号・head・baseの先端）を持つ。承認範囲の外だったときは `outside_approval` も持つ。消費側は `approval_target` を利用者へ示し、承認を実際に得たときだけ、その発言から作った `approval` を添えて同じactionを呼び直す。承認が得られなければ、そのactionを実行済みとして扱わない。

### 3.2 `operation_result`

`operation_result` は、実行した操作の観測結果だけを持ち、実行していない操作を成功として含めない。actionごとの内容は次のとおりである。

| action | `operation_result` |
|---|---|
| `inspect` | `{mode, clean, base_branch_exists, pull_request}`。PRが無いか確認できなければ `pull_request: null` |
| `plan` | `{mode, branch, base_branch, clean}` |
| `start` | `{mode, branch, worktree}` |
| `commit` | `{branch, sha, paths}` |
| `push` | `{branch, sha, remote}` |
| `update-branch` | `{pull_request, changed, sha}`。`changed` はbaseを取り込んだときだけ真、`sha` は取り込み後のhead |
| `pull-request` | `{pull_request, url, draft}` |
| `ready-for-review` | `{pull_request, changed}` |
| `merge-readiness` | `{pull_request, ready, unmet}` |
| `merge` | `{pull_request, merged, method, sha}` |
| `cleanup` | `{pull_request, branch_deleted, worktree_deleted}` |

`merge-readiness` と `inspect` は照会であり、否定的な観測結果でも `status: completed` を返す。`merge-readiness` の `unmet` は満たさない条件の名前である。消費側が次の行動を選ぶのに使う名前は、`behind_base`（headがbaseの先端を含まない。`update-branch` で追従する）、`checks_pending`（必須checkが完了していないか、pushの直後でまだ作られていない。待って確かめ直す）、`checks_failed`（必須checkが完了して失敗した。直す作業へ戻る）、`checks_missing`（headのcheck suiteがすべて完了したのに必須checkが報告されなかった。待っても変わらないので、policyのcheck名と報告元Appが実際の報告と合っているかを確かめる）、`approvals`、`unresolved_threads` である。

### 3.3 `workspace`

`workspace` は、消費側がproviderの設定fileを読まずに済むように、毎回返す。`base_branch`（作業branchの作成元でありPRのbase）、`remote`（pushに使うremote名）、`draft`（PRを下書きで作る設定か）、`branch`（この呼び出しの作業branch。未確定なら `null`）、`worktree`（作業場所の絶対path。branch modeか未開始なら `null`）の5つを持つ。

### 3.4 `reason`

`reason` は `status: failed` のときだけ空でなく、次の語彙のどれかである。

| `reason` | 意味と消費側の扱い |
|---|---|
| `permission_denied` | 操作そのものがpolicyで許されていない。承認を求めずに止まる |
| `method_incompatible` | policyのmerge方式が `update-branch` と両立しない（`rebase` と `fast-forward`）。方式を変えるかは利用者が決める |
| `not_ready` | mergeを求めたがreadinessを満たさない。承認を求めず、状態が変わるまで待つ |
| `verification_failed` | policyの検証が失敗した。成功として扱わない |
| `no_changes` | 対象に変更が無い。commit済みとして扱わない |
| `conflicts` | `update-branch` でbaseと作業branchが競合した。競合を意味で解消してから、通常のcommitとpushで進める |
| `invalid_input` | 入力が契約に合わない。入力を直して呼び直す |
| `policy_missing` | 対象repositoryにpolicy設定fileが無い。利用者が置く。消費側は補わない |
| `merge_partial` | baseを更新したがPRへの反映を確認できない。mergeを再実行せず、状態を確かめてから `cleanup` だけを行う |
| `merge_failed` | mergeが失敗し、baseもheadも更新前のままである |
| `cleanup_failed` | mergeは成功したが片付けが失敗した。merge済みと残ったものを分けて報告する |
| `error` | 上のどれでもない失敗。`detail` の診断を添えて止まる |

## 4. 保証

providerは次を保証する。policyはsystem、利用者、実行環境の権限を増やさない。素の `git` や `gh` で内部の制御を迂回しない。permissionとgateをactionごとに別々に当て、permissionの拒否を承認の質問へ変えない。`approval` が今回のaction・対象・時刻を含まない限り、gateのあるactionを実行せず、承認待ちと承認対象を返す。依頼の範囲外の差分を自分の変更へ含めない。失敗したら止まり、部分的に実行して成功を報告しない。`workspace` を毎回返す。1回の呼び出しで実行するactionは1つだけである。headがbaseの現在の先端を含まないPR、またはpolicyの必須checkがそのheadで成功していないPRは、mergeしない。作業branchの履歴を書き換えず、baseへの追従は `update-branch` のmergeだけで行う。

## 5. 利用者設定

policy設定fileは利用者向けの公開契約である。何を許し、何に承認を求めるかを決めるのは利用者だからである。置き場は `<repo>/.harness-plugins/agent-work-policy.config.yml` の1つだけで、利用者の個人設定、端末固有の設定、同梱既定へのfallbackは無い。方針はrepositoryが持ち、実行者の個人設定で緩められない。fileが無ければ操作を行わず `policy_missing` を、schemaに合わなければ `error` と診断を返す。記入例は入口の `assets/policy.example.yml` にある。

これはplugin間の依存ではない。消費側pluginはこのfileを読まず、書かず、自分のplaybook.yml、SKILL.md、READMEでこのキーを語らない。実行時に要る値は出力の `workspace` から読む。

### 5.1 schema

キーは次で全部であり、すべて必須である。schemaに無いキーと欠けたキーは受け付けない。

| キー | 型 | 意味 |
|---|---|---|
| `version` | int | 設定schemaの版。`1` |
| `workspace.use_worktree` | bool | 副worktreeを作るか。falseならbranchを切る |
| `workspace.require_clean_start` | bool | 開始時にworking treeがcleanであることを求めるか |
| `workspace.base_branch` | string | 作業branchの作成元であり、PRのbase |
| `workspace.branch_prefix` | string | 作業branch名の接頭辞 |
| `workspace.worktree_root` | string | 副worktreeの置き場。空ならOSの一時directory |
| `git.remote` | string | pushとremote branchの操作に使うremote名 |
| `permissions.commit` | bool | commitを許すか。falseは人の承認でも上書きできない |
| `permissions.push` | bool | pushと `update-branch` を許すか |
| `permissions.pull_request` | bool | PR作成と `ready-for-review` を許すか |
| `permissions.merge` | bool | mergeと `cleanup` を許すか |
| `gates.before_commit` | bool | commitの直前に人の承認を求めるか |
| `gates.before_push` | bool | pushと `update-branch` の直前に人の承認を求めるか |
| `gates.before_pull_request` | bool | PR作成の直前に人の承認を求めるか |
| `gates.before_merge` | bool | mergeの直前に人の承認を求めるか |
| `verification.commands` | string[] | commitの直前にすべて成功させる検証command |
| `pull_request.draft` | bool | PRを下書きで作るか |
| `merge.method` | string | mergeの方式。`squash`、`merge`、`rebase`、`fast-forward` |
| `merge.delete_branch` | bool | merge後にremoteの作業branchを消すか |
| `merge.delete_worktree` | bool | merge後に副worktreeを消すか |
| `merge.readiness.min_approvals` | int | mergeに要る最新reviewのApprove数 |
| `merge.readiness.required_checks` | `{name, app}[]` | mergeに要るcheckの唯一の定義。check名と報告元GitHub Appのslugの組の、重複の無い非空配列 |
| `merge.readiness.require_no_unresolved_threads` | bool | 未解決review threadが無いことを求めるか |

## 6. 非契約

次はいつでも変わるので、消費側のplaybook.yml、SKILL.md、README、references、scripts、設定のどこにも書かない。内部scriptの存在、名前、引数、サブコマンド名、標準出力の形、終了code。消費側が設定fileを読むこと、書くこと、そのキーを語ること（ファイル名とschemaは利用者向けの公開契約であって、消費側pluginが触る面ではない）。`references/` の文書とその節。worktreeの作り方、branch名の組み立て方、readinessの判定手順。工程のid。
