# Agent Work Policy

repositoryごとの変更、commit、push、PR、mergeの許可とhuman gateを解決するClaude Code/Codex両対応marketplaceである。公開するインストール対象は、Playbook package `agent-work-policy` 1件だけである。

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

## 公開面

利用者が呼ぶ入口は skill `work-with-policy` の1つ、別pluginから使う入口は公開playbook `agent-work-policy` の1つである。

| 公開面 | 実体 |
|---|---|
| 利用者導線の skill | `work-with-policy`（[入口SKILL](plugins/playbooks/automation/agent-work-policy/SKILL.md)） |
| 公開 playbook | `agent-work-policy`（[playbook.yml](plugins/playbooks/automation/agent-work-policy/playbook.yml)） |
| 公開契約 | [CONTRACT.md](plugins/playbooks/automation/agent-work-policy/CONTRACT.md)。契約ID `agent-work-policy/agent-work-policy`、版 1 |
| 内部 plugin | `work-policy-control`。**外部から直接依存できない** |

別pluginからこのpackageを使うときは、`steps[].playbook: agent-work-policy` だけで呼ぶ。内部の skill、script、references、設定 schema、exit code へは依存できない。頼ってよい入力・出力・保証は [CONTRACT.md](plugins/playbooks/automation/agent-work-policy/CONTRACT.md) が正本である。

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

repository共通のpolicyは `<repo>/.harness-plugins/work-policy-control.config.yml`、commitしない端末固有値は `<repo>/.harness-plugins/work-policy-control.local.yml` に置く。playbookの段取り設定は `<repo>/.harness-plugins/agent-work-policy.config.yml` であり、policy設定とは別のファイルである。

## 検証

```bash
bash scripts/validate.sh
```

## 実行契約と保守

設定はprepareが返すrun専用の絶対pathで引き継ぐ。別shellで同じpathを明示し、完了・失敗停止の最後に同梱run-configのcleanupを呼ぶ。中断後は保存したpathを使い、既にcleanup済みなら設定を再解決する。

[doctor](scripts/doctor.py)は`python3 scripts/doctor.py --repo <対象project>`でCLI構文、両runtime公開入口、依存、設定の解決元を読み取り専用で診断する。`--distribution-only`は依存・project設定を検査しない限定診断であり、full診断の代用にはしない。

doctorのfull診断は、依存を**実配布物**に対して解く。依存先は`HARNESS_PLUGIN_REAL_ROOTS`（契約ID→package rootのJSON）か、兄弟checkout `../<marketplace>-plugins/plugins`（親directoryは`HARNESS_PLUGIN_SIBLING_ROOT`で差し替える）から探し、どちらでも見つからなければfixtureへ倒さず理由付きでNGにする。同梱既定に実値を置かない`prompt_parameters`（`required: true`で`default`が無いもの）を持つskillは、上書きが無ければ必ず落ちるので実行せず、`skipped: requires-override`と必要なパラメータ名を出す。これは配布物の不具合ではないのでNGにしない。

依存参照の検査はresolverとlintが同じ関数で行う。外部依存を指せるのは`${.deps.<論理名>.root}`直下3点と`${.deps.<論理名>.entry}`だけで、それ以外は`external-dependency-path`で落ちる。内部依存（同一package）の`${.deps.<内部名>.skills.<名前>}`は、解決結果に実在するskill名だけを許し、綴り違いや名前の無い形は`internal-skill-unknown`で落ちる。`--explain`の依存行は`[外部] <論理名> → <marketplace>/<plugin> <version> [runtime/source_kind]: <root>`の形で、束縛で実体が変わったときだけ行末に`← <層>`が付く。

CIは同ownerの依存repositoryを兄弟directoryへcheckoutしてからvalidate.shを走らせる。**兄弟のrefは既定でmainである。** PR headと同名のbranchを採るのは、(1)実行が`pull_request`であり、(2)PR headが同一repository（forkではない）で、(3)同ownerの兄弟repoにその名前のbranchが実在する、の3つが揃うときだけで、選んだrefと理由はログへ出る。forkのPR作者はownerの兄弟repoにbranchを作れないため、PRから兄弟checkoutの内容を差し替える経路は無い。code scanningの`actions/untrusted-checkout/medium`はこの根拠により`won't fix`として扱う。

共通実装の開発時正本はProduct Planning repositoryの`shared/runtime-source`にある。更新時はそのsource checkoutを取得し、[生成CLI](scripts/sync-runtime.py)へ`--source <取得した正本directory>`を渡す。`--check`は生成差分と[生成履歴](shared/runtime-manifest.json)のversion・内容hash・対象集合を検査する。正本checkoutなしのCIでも同梱物のhashと対象集合を検査できる。実行時に別repositoryや生成CLIは不要である。変更は正本へ加え、同じ生成コマンドを各source repositoryへ適用する。

[release CLI](scripts/release.py)は`--plugin --version --notes --breaking --migration --checks`で更新計画を返す。`--checks`にはcodex/claudeの実検証結果、または未検証と理由を明示する。`--apply`で両manifestとcatalogの整合を確認して一括更新し、releases配下へ変更内容・移行・検証結果のJSON記録を残す。依存宣言は変更しない。

[意味評価fixture](evals/scenarios.json)を[評価runner](scripts/evaluate-skills.py)へ渡し、異なる生成modelとjudge modelを指定する。モデル名、実model利用、適用設定、入力、出力、SKILL hash、判定の引用と理由を保存する。これはツール無効の次応答を対象とした代表caseの意味評価であり、実ツールを使った全工程E2Eや全行動の保証ではない。保存・CLI・再開の検証は[振る舞い回帰試験](scripts/test-hardening.py)と既存validateが担う。実モデル未実行のfixtureを合格扱いにしない。

### 依存先を束縛する`dependencies.yml`

契約ID（`marketplace/plugin`）に対する実体を`{plugin, marketplace}`で束縛する。**top-levelは`version: 1`と`bindings`の2つだけである。** それ以外のキーがあると`[error:binding-file-invalid] reason=top-level-keys`で停止する。

```yaml
version: 1
bindings:
  "agent-work-policy/agent-work-policy": {plugin: my-work-policy, marketplace: my-marketplace}
```

置き場所は3層で、下ほど優先する。**層はマージせず、見つかった最優先の1ファイルだけを使う。**

1. personal: `$XDG_CONFIG_HOME/harness-plugins/dependencies.yml`（未設定時は`~/.config/harness-plugins/dependencies.yml`）
2. repository: `<repo>/.harness-plugins/dependencies.yml`
3. scope: `<repo>/.harness-plugins/scopes/<入口playbook>/dependencies.yml`

値に書けるのは`plugin`と`marketplace`だけで、**pathやversionは書けない。** 差し替え先はmarketplace経由（installed cache、同一repository、開発時の`HARNESS_PLUGIN_DEV_ROOTS`）で解決でき、manifestの`metadata.harness.implements`にその契約IDを宣言しているpluginでなければならない。宣言が無ければ`[error:binding-not-implemented]`で停止する。playbook側の`requires`は書き換えない。

入口が選んだ束縛はrun専用のlockへ固定して子へ渡す。同じ実行の中で実体が食い違うことはなく、実行中に`dependencies.yml`を書き換えても、そのrunの解決は変わらない。

### explainの読み方

`scripts/prepare.sh`は`--explain`を引数に取らない。**explainは常にstderrへ出る。** stdoutは解決済みYAMLの絶対path1行だけなので、解決の内訳（選んだ設定層、依存の実体、束縛の出どころ、静的に解けた工程入力）はstderrで読む。`--explain`のような未知optionを渡すとusageを表示してexit 2で止まる。

### 破壊的変更の移行

**配布形をskill packageからPlaybook packageへ変えた。** marketplaceの`source`が`./plugins/skills/automation/agent-work-policy`から`./plugins`へ変わるため、**再インストールが要る**。

**policy設定ファイルの名前が変わった。** policyを実行する内部pluginを`work-policy-control`へ改名したので、`<repo>/.harness-plugins/agent-work-policy.config.yml`は`<repo>/.harness-plugins/work-policy-control.config.yml`へ、`~/.config/harness-plugins/agent-work-policy.config.yml`は`~/.config/harness-plugins/work-policy-control.config.yml`へ改名する。`agent-work-policy.config.yml`は公開playbookの段取り設定として解釈されるため、旧名のまま残すと解決が停止する。

**別pluginからの呼び出し方が変わった。** `control.py` / `prepare.sh` / `run-config.py` を外部から直接実行する経路は廃止した。消費側は`steps[].playbook: agent-work-policy`で呼び、[CONTRACT.md](plugins/playbooks/automation/agent-work-policy/CONTRACT.md)の入力・出力だけに依存する。

**束縛lockのschemaに `bindings` が増えた。** 実行中のrunが持っている旧schemaのlockは非互換なので、`--bindings=<lock>` へ渡さない。**runを跨いでlockを使い回さず、入口が作り直す。**

**外部依存の入口参照は `${.deps.<論理名>.entry}` になった。** `${.deps.<論理名>.skills.<名前>}` はresolverとlintが`external-dependency-path`で落とす。`entry_skill`は表示用で、その名前で分岐しない。

**read-onlyのaction `inspect` を足した。** 現況（`workspace`と作業branch・clean・既存PR番号）を返すだけの照会で、既存branchでもdirtyでも止まらない。**状況を知るために`plan`を呼んでいた消費側は`inspect`へ切り替える。**

重複した薄いSKILL入口を廃止した。利用者は公開manifestに列挙された入口を使い、旧入口pathを保存した独自ランチャーは新しい宣言へ切り替える。設定のEXIT trapは廃止し、返されたrun pathを明示して完了・停止時にcleanupする。旧式の一時pathやshell変数だけを再利用しない。

### 開発CLIの入力境界

`doctor`、`release`、`sync-runtime`、意味評価runnerは、操作者が明示したローカルsource、出力先、adapter argvを扱う開発CLIである。外部から受け取った文書やモデル出力をCLI引数へ自動変換しない。doctorのfull modeは選んだrepositoryのresolverを実行するため、信頼するsource checkoutを対象にする。doctorは配布treeのsymlinkを読取・実行前に拒否し、sync-runtimeは生成先と正本treeのsymlinkをcopy前に拒否する。評価の会話・fixture・モデル出力はadapterへstdinデータとして渡し、実行argvに混ぜない。
