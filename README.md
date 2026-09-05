# Agent Work Policy

repositoryごとの変更、commit、push、PR、mergeの許可とhuman gateを解決するClaude Code/Codex両対応marketplaceである。

## こんなときに使う

**AIエージェントへGit作業を任せながら、変更の公開範囲と人間の確認地点をrepositoryごとに固定したいときに使う。** worktree、branch、検証、commit、push、PR、mergeを一つの設定に従って進める。

- mainへの直接変更を避け、必ず専用branchまたはworktreeで作業させたい
- commit、push、PR、mergeのうち、許可する操作だけを明示したい
- merge直前など、特定の地点だけ人間の承認を必須にしたい
- repository固有の検証commandが成功した変更だけをcommitさせたい
- PRの承認、required check、未解決threadを確認してからmergeしたい

このpluginはGitHubのアクセス権限を設定しない。第三者の直pushや無断mergeを防ぐ設定は、GitHub Ruleset、CODEOWNERS、repository権限で行う。このpluginは、AIエージェント自身の作業手順と停止条件を制御する。

## 利用の流れ

1. repositoryへ完全なpolicy設定を置く。
2. エージェントが`plan`で作業可能か確認する。
3. 設定に従ってbranchまたはworktreeを開始する。
4. 指定commandで検証し、許可された公開操作だけを進める。
5. human gateがある場合だけ利用者へ承認を求める。

たとえば、次のように依頼できる。

```text
このIssueをrepositoryのwork policyに従って実装し、PR作成まで進めて。
```

```text
検証とmerge readinessを確認し、policyが許す場合だけPRをmergeして。
```

## インストール

### Codex

Codexのpluginコマンドには`--scope`がない。通常の手順はuser単位でmarketplaceとpluginを登録する。

```bash
codex plugin marketplace add nakamori-naoya/agent-work-policy-plugins
codex plugin add agent-work-policy@agent-work-policy
```

このrepositoryだけに分離したい場合は、repository専用の`CODEX_HOME`を作り、インストール時と利用時に同じ値を指定する。

```bash
mkdir -p .codex-home
export CODEX_HOME="$PWD/.codex-home"

codex plugin marketplace add nakamori-naoya/agent-work-policy-plugins
codex plugin add agent-work-policy@agent-work-policy
codex
```

`CODEX_HOME`には認証、設定、ログ、session、plugin metadataも保存されるため、このdirectoryはGit管理しない。

### Claude Code

Claude Codeは次のscopeを選べる。

| scope | 対象 |
|---|---|
| `user` | user全体。省略時の既定値 |
| `project` | このrepositoryで有効にする設定をGitでチーム共有する |
| `local` | このrepositoryで有効にするが、Git共有せず自分だけで使う |

repository設定としてインストールする場合は`project`を指定する。`CLAUDE_PLUGIN_SCOPE`を`user`または`local`へ変えれば、同じ手順でscopeを切り替えられる。

```bash
CLAUDE_PLUGIN_SCOPE=project

claude plugin marketplace add nakamori-naoya/agent-work-policy-plugins --scope "$CLAUDE_PLUGIN_SCOPE"
claude plugin install agent-work-policy@agent-work-policy --scope "$CLAUDE_PLUGIN_SCOPE"
```

## 依存plugin

`agent-work-policy@agent-work-policy`に外部pluginへの依存はない。

## 設定の上書きと優先順位

設定を持つpluginは、優先順位が最も高い1ファイルだけを選ぶ。複数層をマージしないため、上書きするYAMLには同梱設定と同じ必須項目をすべて含める。必須項目の不足、未知のキー、許可されていない値があれば実行を停止する。

skillの静的設定は、上から順に優先する。

1. scope: `<scope>/<plugin-name>.config.yml`。呼び出し元がscopeを渡した実行だけで使う
2. local: `<repo>/.harness-plugins/<plugin-name>.local.yml`。端末固有で、通常はcommitしない
3. repository: `<repo>/.harness-plugins/<plugin-name>.config.yml`
4. personal: `$XDG_CONFIG_HOME/harness-plugins/<plugin-name>.config.yml`（未設定時は `~/.config/harness-plugins/<plugin-name>.config.yml`）
5. bundled defaults: plugin同梱の既定設定

playbookの静的設定は、scope、repository、personal、同梱 `playbook.yml` の順で優先する。playbookにはlocal層がない。入口playbook自身は通常のrepository設定を使い、下段のpluginへscopeを渡す。単体呼び出しではscopeを読まない。

skillでは、同梱設定の `prompt_parameters` に宣言されたpathだけ、依頼で明示された値を `--override=<path>=<value>` として最終上書きできる。宣言されていないpathを任意に上書きすることはできない。

repository共通のpolicyは `<repo>/.harness-plugins/agent-work-policy.config.yml`、commitしない端末固有値は `<repo>/.harness-plugins/agent-work-policy.local.yml` に置く。

## 検証

```bash
bash scripts/validate.sh
```
