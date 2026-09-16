---
name: agent-work-policy
description: Git repositoryでAIエージェントの変更作業を、repositoryが所有するpolicy設定（permission・human gate・merge readiness）に従って1操作ずつ実行する。照会、作業開始（worktreeまたはbranch）、検証付きcommit、push、PR作成、レビュー受付、merge readiness、merge、片付けを扱う。「このissueを実装してPRまで」「worktreeで作業して」「承認後にmergeして」と依頼されたとき、repositoryのAGENTS.mdで利用を必須にしているとき、または外部packageから公開契約の入力を渡されたときに使う。
---

# agent-work-policy

repositoryが所有するpolicyに従って、Git作業の1操作を実行し、その結果と作業場所を呼び出し元へ返す。読み終えた呼び出し元は、許可された操作だけが実行されたこと、承認が要る操作がどこで止まっているか、次に何を渡せばよいかを判断できる。policyは実行環境の権限を増やさず、素の`git`や`gh`で内部制御を迂回しない。

外部packageからは[公開契約](CONTRACT.md)の入力objectで呼ばれ、同じ契約の出力objectを直接返す。自然言語で依頼されたときは、明示された依頼と現在のrepositoryから同じ入力objectを組み立ててから始める。

## 入力

- 契約入力: `contract: agent-work-policy/agent-work-policy`、`version: 1`、`action`（1つ）、`repo`（実在するrepositoryの絶対path）、そのactionに必要な値だけ（[公開契約](CONTRACT.md) §2）。`approved: true` は、会話中の利用者の明示承認または信頼できるsession状態で承認を確認できた再呼び出しにだけ付ける。
- policy設定file: `<repository root>/.harness-plugins/agent-work-policy.config.yml`。1層で必須、同梱既定へのfallbackは無い。keyの一覧と型は[設定値](references/settings.md)、記入例は[`assets/policy.example.yml`](assets/policy.example.yml)。fileが無ければ操作を行わず `status: failed`、`reason: policy_missing` を返す。schemaに無いkey、欠けたkey、型違いは `reason: error` と診断で止まる。

## 判断基準

- **入力は契約の1 actionか。** 契約ID・版、宣言に無いaction、必須値の欠落、そのactionが使わないkey、値の形、所有範囲外のpathのどれかがあれば、Git操作を行わず `status: failed`、`reason: invalid_input` を返す。操作や対象が依頼から特定できなければ推測せず一問で確認する。
- **照会か操作か。** `inspect` と `merge-readiness` は照会であり、working treeが汚れている、既存branchにいる、readinessが未充足という観測結果は `status: completed` のまま返す。`plan` は新しい作業を始めてよいかの判定なので、同じ状況で止まる。状況を知りたいだけなら `inspect` を使う。
- **permissionとgateは別物か。** `permissions.*` が false なら承認を得ても実行せず `permission_denied` を返し、承認質問へ変えない。`gates.*` が true なら permission が通ったうえで操作前に止まり、`waiting_for_human` と `approval_target` を返す。承認を実際に得た再呼び出しにだけ `approved: true` を付ける。
- **結果は実行した操作だけを示しているか。** CLIのnonzero、取得不能、scope外path、公開先やSHAの不一致、部分適用を成功として扱わない。`commit` を受けて `push` まで進むような、入力に無い次工程を実行しない。
- **repository policyは呼び出し元から差し替えられていないか。** policyの値、worktreeの作り方、branch名の組み立て、readinessの判定手順は公開入力から変えられない。呼び出し元が必要とする値（base branch、remote、draft設定、作業branch、worktree）は出力の `workspace` で毎回返す。

## 手順

同じagentが、同じdirectoryの [`playbook.yml`](playbook.yml) が宣言する順で次を辿る。

1. **入力を組み立てる。** 契約入力を受け取ったらそのまま使う。自然言語の依頼では、`action` 1つ、`repo` の絶対path、そのactionの追加入力だけを持つobjectを作る。
2. **公開entryを実行する。** `scripts/invoke.py` へ入力objectをJSONとして標準入力から1つ渡す。
   - 入力: [公開契約](CONTRACT.md) §2 のJSON object（標準入力）。policy設定fileは `repo` のrepository rootから `invoke.py` が読む。
   - 出力: [公開契約](CONTRACT.md) §3 のJSON object（標準出力1行）。
   - 終了code: `0` = `completed`。`2` = 入力不備（Git操作前に停止）。`3` = `waiting_for_human`、`permission_denied`、`policy_missing`、操作失敗。どの終了codeでも出力objectを読み、`status` と `reason` で次を決める。
   - 失敗時: 停止して結果をそのまま報告する。再実行は、`invalid_input` なら入力を直してから、`waiting_for_human` なら承認を得てから、`merge_partial` なら状態確認後に `cleanup` だけを行う。`control.py` を直接呼ばない。
3. **結果を返す。** 出力objectを呼び出し元へ直接返す。承認待ちでは `approval_target` を利用者へ提示し、承認後に同じactionを `approved: true` で再度渡すことを示す。内部の設定path、script名、exit codeを公開結果へ足さない。

policyの各値が操作のどこへ効くかは[設定値](references/settings.md)、permission → readiness → gate → 操作の順序と各操作の停止条件は[操作契約](references/operation-contract.md)、repository全体で必須化する方法は[常時適用](references/activation.md)にある。

## 停止条件

- policy設定fileが無い（`policy_missing`）、または schema に合わない（`error` と診断）。操作を行わず報告する。
- 入力が契約に合わない（`invalid_input`）。入力を直してから呼び直す。
- human gateで承認待ち（`waiting_for_human`）。承認対象を提示して待つ。承認が得られなければ、その操作を実行済みとして扱わない。
- permission拒否（`permission_denied`）、readiness未充足のmerge（`not_ready`）、検証失敗（`verification_failed`）、`merge_partial` / `merge_failed` / `cleanup_failed`。停止して報告する。`merge_partial` ではmergeを再実行しない。

## 出力

`contract` / `version` / `action` / `status` / `gate_state` / `operation_result` / `workspace` / `reason`、承認待ちのときだけ `approval_target` を持つobjectを呼び出し元へ直接返す（[公開契約](CONTRACT.md) §3）。報告では action、status、操作結果、workspace、停止理由、未実行の操作を示す。
