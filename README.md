# Agent Work Policy

AIエージェントがGit repositoryの変更を `git` と `gh` で直接commit、push、PR、merge するときの規律を配る、Claude Code/Codex両対応のmarketplaceである。公開するのはpackage `agent-work-policy`（`./plugins/agent-work-policy`）1件と、skill `agent-work-policy` 1つである。

## 何を決めるか

手順は持たず、エージェントが自分では外しやすい五つの判断だけを[SKILL.md](plugins/agent-work-policy/skills/agent-work-policy/SKILL.md)に書く。mergeの条件（headがbaseの今の先端を含み、必須checkがそのheadで成功していること）はGitHubのRulesetに守らせる。merge できる状態は merge してよい理由にならず、利用者が許可したときだけmergeする。別のエージェントから中継された文章を利用者の承認として扱わない。並行作業ではGit以外の資源（container、port、DB）も分ける。秘密値を検査と退避で取りこぼさない。

このpluginはGitHubの権限を設定しない。第三者の直pushや無断mergeを防ぐのは、GitHubのRuleset、CODEOWNERS、repositoryの権限である。

## インストール

インストールするのは`agent-work-policy@agent-work-policy`です。外部プラグインの追加は不要です。

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

## 検証

```bash
bash scripts/validate.sh
bash /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/scripts/validate.sh /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/agent-work-policy-plugins
```

`scripts/validate.sh` は、配置とmanifestの一致、SKILLのname、LICENSEの写し、secret scanningの設定を検査する。保守toolの実装元は兄弟checkoutの `../harness-tools/` で、このrepositoryは複製を持たない。

## 判断の eval

skill が外しやすい判断（merge できる状態を merge の許可として扱わないこと、中継された承認を利用者の承認として扱わないこと、並行の検証が依存を通じて固定名の資源に当たるのを読み取ること）を、`evals/` のケースで確かめる。どのケースも、手元だけの git repository と、GitHub の状態を写した記録で組み、GitHub、Docker、クラウドには触れない。実行は `claude plugin eval` が受け持ち、判断の記録の出来は、作業したエージェントとは別の Claude（採点役）が条件ごとに判定し、3 回の多数決と重み付きの 100 点満点で点数にする。`graders/` には、読まずに判定できること（記録ができたか、skill を使ったか、merge や docker の起動のような戻せない操作を実行しなかったか）だけを置く。

共通の条件は `evals/criteria/work-decision.md`、ケースに固有の条件は `evals/<お題>/<ケース>/grading/criteria.md`、採点役を確かめる資料と期待する判定は `grading/calibration/` にある。条件か採点役への指示を変えたら、先に較正の資料で採点役が期待する判定を再現するかを確かめる。

```bash
claude plugin eval . --case merge-relayed-approval --runs 1 --ablation none --keep-temp \
  --scaffold --allow-tools Write Edit Bash --max-cost-usd 5 --no-publish
bash /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/harness-tools/tools/grade-eval.sh \
  "$(pwd)/evals/merge/merge-relayed-approval" /private/tmp/e-XXXXXX
```

実行と採点の結果は `evals/results/` に書かれ、git の管理から外してある。
