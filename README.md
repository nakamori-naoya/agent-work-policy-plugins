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

## 実行契約と保守

設定はprepareが返すrun専用の絶対pathで引き継ぐ。別shellで同じpathを明示し、完了・失敗停止の最後に同梱run-configのcleanupを呼ぶ。中断後は保存したpathを使い、既にcleanup済みなら設定を再解決する。

[doctor](scripts/doctor.py)は`python3 scripts/doctor.py --repo <対象project>`でCLI構文、両runtime公開入口、依存、設定の解決元を読み取り専用で診断する。`--distribution-only`は依存・project設定を検査しない限定診断であり、full診断の代用にはしない。

共通実装の開発時正本はProduct Planning repositoryの`shared/runtime-source`にある。更新時はそのsource checkoutを取得し、[生成CLI](scripts/sync-runtime.py)へ`--source <取得した正本directory>`を渡す。`--check`は生成差分と[生成履歴](shared/runtime-manifest.json)のversion・内容hash・対象集合を検査する。正本checkoutなしのCIでも同梱物のhashと対象集合を検査できる。実行時に別repositoryや生成CLIは不要である。変更は正本へ加え、同じ生成コマンドを各source repositoryへ適用する。

[release CLI](scripts/release.py)は`--plugin --version --notes --breaking --migration --checks`で更新計画を返す。`--checks`にはcodex/claudeの実検証結果、または未検証と理由を明示する。`--apply`で両manifestとcatalogの整合を確認して一括更新し、releases配下へ変更内容・移行・検証結果のJSON記録を残す。依存宣言は変更しない。

[意味評価fixture](evals/scenarios.json)を[評価runner](scripts/evaluate-skills.py)へ渡し、異なる生成modelとjudge modelを指定する。モデル名、実model利用、適用設定、入力、出力、SKILL hash、判定の引用と理由を保存する。これはツール無効の次応答を対象とした代表caseの意味評価であり、実ツールを使った全工程E2Eや全行動の保証ではない。保存・CLI・再開の検証は[振る舞い回帰試験](scripts/test-hardening.py)と既存validateが担う。実モデル未実行のfixtureを合格扱いにしない。

### 破壊的変更の移行

重複した薄いSKILL入口を廃止した。利用者は公開manifestに列挙された入口を使い、旧入口pathを保存した独自ランチャーは新しい宣言へ切り替える。設定のEXIT trapは廃止し、返されたrun pathを明示して完了・停止時にcleanupする。旧式の一時pathやshell変数だけを再利用しない。

### 開発CLIの入力境界

`doctor`、`release`、`sync-runtime`、意味評価runnerは、操作者が明示したローカルsource、出力先、adapter argvを扱う開発CLIである。外部から受け取った文書やモデル出力をCLI引数へ自動変換しない。doctorのfull modeは選んだrepositoryのresolverを実行するため、信頼するsource checkoutを対象にする。doctorは配布treeのsymlinkを読取・実行前に拒否し、sync-runtimeは生成先と正本treeのsymlinkをcopy前に拒否する。評価の会話・fixture・モデル出力はadapterへstdinデータとして渡し、実行argvに混ぜない。
