# Agent Work Policy

repositoryごとの変更、commit、push、PR、mergeの許可とhuman gateを、repositoryが所有するpolicy設定に従って適用するClaude Code/Codex両対応marketplaceである。公開するインストール対象はpackage `agent-work-policy`（`./plugins/agent-work-policy`）1件、公開入口は自己完結skill `agent-work-policy` 1件で、それが公開playbook `agent-work-policy` でもある。

## こんなときに使う

**AIエージェントへGit作業を任せながら、変更の公開範囲と人間の確認地点をrepositoryごとに固定したいときに使う。** worktree、branch、検証、commit、push、baseへの追従、PR、mergeを一つの設定に従って進める。

- mainへの直接変更を避け、必ず専用branchまたはworktreeで作業させたい
- commit、push、PR、mergeのうち、許可する操作だけを明示したい
- merge直前など、特定の地点だけ人間の承認を必須にしたい
- repository固有の検証commandが成功した変更だけをcommitさせたい
- headがbaseの最新を含み、policyに書いた必須checkが成功し、承認と未解決threadの条件を満たしてからmergeしたい（branch protectionが無いrepositoryでも使える）
- 作業branchを、履歴を書き換えずにbaseの最新へ追従させたい
- 「PR 24〜27はmergeしてよい」のような範囲の承認を、操作・対象・期限・発言の原文として渡し、その範囲だけ確認を省きたい

このpluginはGitHubのアクセス権限を設定しない。第三者の直pushや無断mergeを防ぐ設定は、GitHub Ruleset、CODEOWNERS、repository権限で行う。このpluginは、AIエージェント自身の作業手順と停止条件を制御する。

## 利用の流れ

1. repositoryの `.harness-plugins/agent-work-policy.config.yml` へ完全なpolicy設定を置く（記入例は `plugins/agent-work-policy/skills/agent-work-policy/assets/policy.example.yml`）。
2. エージェントが `inspect` で現況を、`plan` で作業可能かを確認する。
3. 設定に従ってbranchまたはworktreeを開始する。
4. 指定commandで検証し、許可された公開操作だけを進める。
5. human gateがある場合だけ利用者へ承認を求める。利用者が範囲で許したときは、その範囲を `approval` として渡す。
6. baseが進んだら `update-branch` で追従し、`merge-readiness` が満たされてからmergeする。

たとえば、次のように依頼できる。

```text
このIssueをrepositoryのwork policyに従って実装し、PR作成まで進めて。
```

```text
検証とmerge readinessを確認し、policyが許す場合だけPRをmergeして。
```

## 公開面

利用者が呼ぶ入口と、別pluginから使う公開playbookは同じ `agent-work-policy` 1つである。

| 公開面 | 実体 |
|---|---|
| 公開入口 / 公開 playbook | `agent-work-policy`（[SKILL.md](plugins/agent-work-policy/skills/agent-work-policy/SKILL.md)、[playbook.yml](plugins/agent-work-policy/skills/agent-work-policy/playbook.yml)） |
| 公開契約 | [CONTRACT.md](plugins/agent-work-policy/skills/agent-work-policy/CONTRACT.md)。契約ID `agent-work-policy/agent-work-policy`、版 1 |
| 公開entry | `scripts/invoke.py`。契約入力objectを標準入力で受け、契約出力objectを標準出力で返す |
| 利用者設定 | `<repo>/.harness-plugins/agent-work-policy.config.yml`（1層・必須） |

別pluginからこのpackageを使うときは、`steps[].playbook: agent-work-policy` だけで呼ぶ。内部の script、references、設定 schema、exit code へは依存できない。頼ってよい入力・出力・保証は [CONTRACT.md](plugins/agent-work-policy/skills/agent-work-policy/CONTRACT.md) が正式な定義である。

## インストール

インストールするのは`agent-work-policy@agent-work-policy`です。外部プラグインの追加は不要です。

内部のスキルは同梱されています。個別にインストールせず、公開入口から利用してください。

### Codex

利用するCodexと同じ設定環境で実行してください。

```bash
codex plugin marketplace add nakamori-naoya/agent-work-policy-plugins
codex plugin add agent-work-policy@agent-work-policy
codex plugin list
```

一覧で導入先を確認し、新しい会話で利用してください。

### Claude Code

次は自分の全プロジェクトで使う例です。このプロジェクトのチームで共有する場合は`project`、このプロジェクトで自分だけが使う場合は`local`に変更し、利用先のディレクトリで実行してください。

```bash
CLAUDE_PLUGIN_SCOPE=user
claude plugin marketplace add nakamori-naoya/agent-work-policy-plugins --scope "$CLAUDE_PLUGIN_SCOPE"
claude plugin install agent-work-policy@agent-work-policy --scope "$CLAUDE_PLUGIN_SCOPE"
claude plugin list
```

一覧で導入を確認し、Claude Codeを再起動してください。すでに導入しているパッケージは、次の更新手順を使ってください。

## 更新する

GitHubから登録したmarketplaceを更新し、その公開パッケージを更新します。新規インストールと同じCodexの設定環境、Claude Codeの適用範囲を使ってください。

### Codex

```bash
codex plugin marketplace upgrade agent-work-policy
codex plugin add agent-work-policy@agent-work-policy
codex plugin list
```

更新後は新しい会話で確認してください。ローカルのパスからmarketplaceを登録した場合は、Git版の更新コマンドではなく、その登録先のソースを更新してから追加し直します。

### Claude Code

```bash
# インストール時に合わせてuser / project / localを選ぶ
CLAUDE_PLUGIN_SCOPE=user
claude plugin marketplace update agent-work-policy
claude plugin update agent-work-policy@agent-work-policy --scope "$CLAUDE_PLUGIN_SCOPE"
claude plugin list
```

更新後はClaude Codeを再起動してください。

marketplaceの取得と、インストール済みパッケージの更新は分けて確認します。同じバージョンとして公開された変更は、更新コマンドだけでは反映されない場合があります。「最新」と表示された場合は公開バージョンを確認し、キャッシュ内のファイルを直接編集しないでください。

コマンドは2026-09-06時点のCLIヘルプと、[Codexのmarketplace管理](https://developers.openai.com/plugins/build/plugins)、[Claude Codeの更新仕様](https://code.claude.com/docs/en/plugins-reference#plugin-update)を確認しています。

## 依存plugin

`agent-work-policy@agent-work-policy`に外部pluginへの依存はない。

## policy設定

policy設定は `<repo>/.harness-plugins/agent-work-policy.config.yml` の1層だけである。利用者の個人設定（`~/.config/harness-plugins/`）、端末固有の `.local.yml`、同梱既定へのfallbackは無い。方針はrepositoryが所有し、実行者の個人設定で緩められない。読み取りは入口の `scripts/config.py check|read --repo <repository配下のpath>`（stdin不要、pathはtoolが固定、stdoutにJSON 1文書。失敗は終了code 2と `reason`: `policy_missing` / `schema_violation` / `not_a_git_repository`）で行い、`invoke.py` も同じ検査を内部で共有する。fileが無ければ操作を行わず `reason: policy_missing` を返し、schemaに無いkey・欠けたkey・型違いは診断付きで止まる。全keyの意味は [settings.md](plugins/agent-work-policy/skills/agent-work-policy/references/settings.md)、schemaは [CONTRACT.md §5](plugins/agent-work-policy/skills/agent-work-policy/CONTRACT.md) にある。

repositoryのすべての変更作業へ適用するには、そのrepositoryの `AGENTS.md` / `CLAUDE.md` で `agent-work-policy` の利用を必須にする（[activation.md](plugins/agent-work-policy/skills/agent-work-policy/references/activation.md)）。

## 検証

```bash
bash scripts/validate.sh
bash /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/scripts/validate.sh /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/agent-work-policy-plugins
```

`scripts/validate.sh` は宣言と実体の対応、公開entryの入出力schema、policy不在・schema違反・gate・permissionでの操作前停止、`tests/publication-authority-contract.sh` による `control.py` の停止契約を検査する。policyの妥当性、承認対象の十分性、SKILL本文の判断基準の十分性は意味評価として残る。

## 保守tool

保守用tool（doctor / lint-consumer-contract / evaluate-skills / release / test-hardening / validate-plugin-repository）の実装元は兄弟checkoutの `../harness-tools/` であり、このrepositoryは複製を持たない。`scripts/validate.sh` は `../harness-tools/tools/` の実在を確認してから呼び、無ければ止まる。CIの `validate.yml` も `harness-tools` を兄弟checkoutして `harness-tools/ci/validate.sh` を実行する。呼び方は `../harness-tools/README.md` にある。

[意味評価fixture](evals/scenarios.json)を `harness-tools` の評価runner（`scripts/run-evals.sh`）へ渡した記録は、criterionの真偽を機械の合否にせず、人またはエージェントが根拠付きで評価する。

## このpackageが持つ判断

`agent-work-policy` は、Git作業の公開操作（commit、push、baseへの追従、PR作成、レビュー受付、merge、片付け）を、いつ実行していつ止めるかを持つ。

permissionとgateの意味、承認範囲 `approval` の形と組み立ててよい者は、公開契約の §2.2 とpolicyの設定が持つ。

mergeしてよい状態（headがbaseの先端を含み、policyの必須checkがそのheadで成功していること）と、baseへの追従の手段（`update-branch`）とmerge方式の関係も、この package が持つ。

並行作業で分ける実行資源の判断は、`references/parallel-work.md` が持つ。

秘密値を検査する範囲、受け渡す一式が揃っているかの確かめ方、退避と写しでの扱いは、`references/secret-handling.md` が持つ。

依存の更新のPRを最新のbaseで作り直すことと、脆弱性の到達性の検査と版の警告を別の信号として扱うことは、`references/dependency-updates.md` が持つ。

誰が統合してよいかという役割の判断は持たず、`agent-roles` に従う。
