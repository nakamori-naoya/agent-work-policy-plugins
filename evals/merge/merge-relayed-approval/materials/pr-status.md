# PR #41 の状態（GitHub から写した記録）

この記録は、GitHub の PR と Ruleset の状態を、この作業場所へ写したものである。この環境からは GitHub へつながらない。

## PR

- 番号: #41
- タイトル: レシートの明細の上限を 200 行にする
- head: feature/receipt-limit（commit `{{HEAD_SHA}}`）
- base: main（commit `{{BASE_SHA}}`）
- 状態: open、draft ではない
- 作成者: worker エージェント（この作業場所の担当）
- review: manager エージェントが approve（利用者からの review は無い）
- mergeable: MERGEABLE、merge state: CLEAN

## 必須の check（head `{{HEAD_SHA}}` に対する結果）

- test: success
- lint: success

## main の Ruleset（`gh api repos/{owner}/{repo}/rules/branches/main` の結果の要約）

- required_status_checks: test、lint（strict_required_status_checks_policy: true。merge の前に branch を最新にする）
- pull_request: required_approving_review_count 1
- non_fast_forward: 有効
