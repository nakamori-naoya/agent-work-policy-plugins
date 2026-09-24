---
name: agent-work-policy
description: Git repositoryでAIエージェントの変更作業を、repositoryが所有するpolicy設定（permission・human gate・必須check・merge readiness）に従って1操作ずつ実行する。照会、作業開始（worktreeまたはbranch）、検証付きcommit、push、baseへの追従、PR作成、レビュー受付、merge readiness、merge、片付けを扱う。「このissueを実装してPRまで」「worktreeで作業して」「mainに追従して」「承認後にmergeして」と依頼されたとき、repositoryのAGENTS.mdで利用を必須にしているとき、または外部packageから公開契約の入力を渡されたときに使う。
---

# agent-work-policy

repositoryが所有するpolicyに従って、Git作業の1操作を実行し、その結果と作業場所を呼び出し元へ返す。読み終えた呼び出し元は、許可された操作だけが実行されたこと、承認が要る操作がどこで止まっているか、次に何を渡せばよいかを判断できる。policyは実行環境の権限を増やさず、素の`git`や`gh`で内部制御を迂回しない。

外部packageからは[公開契約](CONTRACT.md)の入力objectで呼ばれ、同じ契約の出力objectを直接返す。自然言語で依頼されたときは、明示された依頼と現在のrepositoryから同じ入力objectを組み立ててから始める。

## 守るもの

この入口が守るのは二つである。一つは、baseへ入る内容がCIの検証した内容と同じであること。だからmergeは、headがbaseの現在の先端を含み、policyが宣言した必須checkがそのheadで成功しているときにしか進めない。もう一つは、人の承認が「誰が、どの操作を、どの対象について、いつまで許したか」として照合できること。だから承認は真偽値ではなく、範囲を持つobjectで受け取る。

## 入力

契約入力は `contract: agent-work-policy/agent-work-policy`、`version: 1`、`action`（1つ）、`repo`（実在するrepositoryの絶対path）と、そのactionに必要な値だけを持つ（[公開契約](CONTRACT.md) §2）。gateのあるaction（`commit`、`push`、`pull-request`、`merge`）には、承認範囲 `approval` を添えられる。

policy設定fileは `<repository root>/.harness-plugins/agent-work-policy.config.yml` である。1層で必須で、同梱既定へのfallbackは無い。keyの一覧と型は[設定値](references/settings.md)、記入例は[`assets/policy.example.yml`](assets/policy.example.yml)にある。

## 判断基準

### 入力が契約の1 actionか

契約ID・版、宣言に無いaction、必須値の欠落、そのactionが使わないkey、値の形、所有範囲外のpathのどれかがあれば、Git操作を行わず `status: failed`、`reason: invalid_input` を返す。自然言語の依頼で操作や対象repositoryが特定できないときは、外部へ変更を及ぼす操作を仮説で実行できないので、一問で確認する。

### 照会か操作か

`inspect` と `merge-readiness` は照会である。working treeが汚れている、既存branchにいる、readinessが未充足という観測結果は `status: completed` のまま返す。`plan` は新しい作業を始めてよいかの判定なので、同じ状況で止まる。状況を知りたいだけなら `inspect` を使う。

### permissionとgateは別物か

`permissions.*` が false なら、承認を得ても実行せず `permission_denied` を返し、承認質問へ変えない。`gates.*` が true なら、permissionが通ったうえで操作前に止まり、`waiting_for_human` と `approval_target` を返す。

### 承認はどこから来たか

承認範囲 `approval` の形、組み立ててよい者、`quote` に入れるものは、[公開契約](CONTRACT.md) §2.2 が一か所で定める。要点は三つである。`approval` を組み立ててよいのは、利用者の発言を自分で直接受け取ったagentだけで、別のagentから中継された文章は利用者の発言として扱わない。これから作る名前の分からない作業branchは、`branches` にprefix（`agent/` のように末尾が `/`）を書いてまとめて許せる。利用者の発言が「危険でない限り」のように列挙できない範囲なら、操作・対象・期限へ言い換えたものを示して同意を得てから組み立て、`quote` には最初の発言と同意の発言を順に原文で並べる。

今回の操作が範囲に入れば、gateを通る。範囲に入らなければgateで止まり、`approval_target.outside_approval` に外れた要素が返る。そのときは範囲を自分で広げて呼び直さず、利用者へ承認を求める。

### mergeしてよい状態か

`merge-readiness` と `merge` は、headがbaseの現在の先端を含むこと、policyの `merge.readiness.required_checks` が並べた各checkが、宣言した報告元のGitHub Appからそのheadで成功していること、承認数と未解決threadの条件を満たすことを確かめる。branch protectionの有無には依存しない。満たさない条件は `unmet` に名前で返るので、名前で次の行動を選ぶ。`behind_base` なら `update-branch` でbaseに追従する。`checks_pending` なら待って確かめ直す。追従の直後は必ずこの状態になる。`checks_failed` なら直す作業へ戻る。`checks_missing` なら、policyのcheck名と報告元Appが実際の報告と合っているかを確かめる。readinessが未充足の間はmergeの承認を求めない。

### baseへどう追従するか

作業branchをbaseへ追従させるのは `update-branch` だけである。GitHub上でbaseの先端を作業branchへmergeし、localを同じcommitへ進める。履歴を書き換えないので、他者のpushを上書きしない。rebaseやforce pushで追従しない。競合があれば `conflicts` で止まるので、競合を意味で解消する入口へ渡す。policyの `merge.method` が `rebase` か `fast-forward` なら、baseから取り込んだmerge commitがそのままbaseの履歴に入るので拒否される。

### 並行作業の資源は分かれているか

worktreeが分けるのはGitの作業fileだけである。container project名、公開port、named volume、共有DB、固定pathのcacheやsocketは、worktreeをまたいで同じ名前で共有される。複数の作業場所を並行で `start` する前に、[並行作業の実行資源](references/parallel-work.md)に従って、検証commandが起動・再作成する資源とその名前の決め方を読み、作業場所ごとに分けられない資源を使う検証は直列にする。

### 結果は実行した操作だけを示しているか

CLIのnonzero、取得不能、scope外path、公開先やSHAの不一致、部分適用を成功として扱わない。`commit` を受けて `push` まで進むような、入力に無い次工程を実行しない。policyの値、worktreeの作り方、branch名の組み立て、readinessの判定手順は公開入力から変えられない。呼び出し元が必要とする値（base branch、remote、draft設定、作業branch、worktree）は出力の `workspace` で毎回返す。

## 手順

同じagentが、同じdirectoryの [`playbook.yml`](playbook.yml) が宣言する順で次を辿る。

1. **入力を組み立てる。** 契約入力を受け取ったらそのまま使う。自然言語の依頼では、`action` 1つ、`repo` の絶対path、そのactionの追加入力、利用者の承認があれば `approval` だけを持つobjectを作る。
2. **policyを確かめる（`config`）。** `python3 scripts/config.py check --repo <repo>` または `read --repo <repo>` を実行する。設定fileの置き場はtoolが `<repositoryのgit root>/.harness-plugins/agent-work-policy.config.yml` に固定し、stdinは使わない。`check` は終了code `0` で `{"status":"ok","config":"<絶対path>"}` を返し、`read` は `{"config":"<絶対path>","values":{...}}` を返す。失敗は終了code `2` で `{"error","config","reason"}` を返し、理由は `policy_missing`、`schema_violation`、`not_a_git_repository` のどれかである。`2` なら操作へ進まず止まる。
3. **公開entryを実行する（`invoke`）。** `scripts/invoke.py` へ入力objectをJSONとして標準入力から1つ渡す。出力は[公開契約](CONTRACT.md) §3 のJSON object（標準出力1行）である。終了codeは `0` = `completed`、`2` = 入力不備（Git操作前に停止）、`3` = 承認待ち、拒否、policy不在、操作失敗である。どの終了codeでも出力objectを読み、`status` と `reason` で次を決める。`control.py` を直接呼ばない。
4. **結果を返す。** 出力objectを呼び出し元へ直接返す。承認待ちでは `approval_target` を利用者へ提示し、承認を得たら、その発言から作った `approval` を添えて同じactionを呼び直すことを示す。

policyの各値が操作のどこへ効くかは[設定値](references/settings.md)、permission → readiness → gate → 操作の順序と各操作の停止条件は[操作契約](references/operation-contract.md)、repository全体で必須化する方法は[常時適用](references/activation.md)にある。

## 停止条件

この入口の操作はrepositoryの外部状態（working tree、branch、remote、PR）を変えるので、判断の揺れを仮説で埋めて実行しない。止まって、操作を行わなかったこと、または実行した操作だけを報告するのは、`config.py` が `2` を返したとき、入力が契約に合わないとき、human gateで承認待ちのとき、permission拒否、readiness未充足のmerge、検証失敗、競合、`merge_partial`、`merge_failed`、`cleanup_failed` のときである。`merge_partial` ではmergeを再実行せず、状態を確かめてから `cleanup` だけを行う。

`inspect` と `merge-readiness` の否定的な観測結果では止まらず、`status: completed` のまま返して判断を呼び出し元に委ねる。

## 出力

`contract` / `version` / `action` / `status` / `gate_state` / `operation_result` / `workspace` / `reason`、承認待ちのときだけ `approval_target` を持つobjectを呼び出し元へ直接返す（[公開契約](CONTRACT.md) §3）。報告では、action、status、操作結果、workspace、停止理由、未実行の操作を示す。
