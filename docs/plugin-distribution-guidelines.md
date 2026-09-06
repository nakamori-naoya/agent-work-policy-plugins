# プラグインの配布単位とインストール

このリポジトリ群では、利用者が仕事を依頼する公開パッケージをインストールする。文書の型選択やレビューなど、途中の処理は同じパッケージに含める。内部のスキル名はインストール対象ではない。

## 何をインストールするか

2026-09-06に各リポジトリのmainにある配布定義を確認した。10リポジトリから11パッケージを公開している。名前と配布元の組を使い、各READMEのコマンドで導入する。

| リポジトリ | 公開パッケージ | 外部の依存 |
|---|---|---|
| [agent-fleet-plugins](https://github.com/nakamori-naoya/agent-fleet-plugins#インストール) | `agent-fleet-core@agent-fleet`、`agent-fleet-herdr@agent-fleet` | `agent-roles@agent-roles` |
| [agent-roles-plugins](https://github.com/nakamori-naoya/agent-roles-plugins#インストール) | `agent-roles@agent-roles` | なし |
| [agent-work-policy-plugins](https://github.com/nakamori-naoya/agent-work-policy-plugins#インストール) | `agent-work-policy@agent-work-policy` | なし |
| [bdd-discovery-and-formulation-plugins](https://github.com/nakamori-naoya/bdd-discovery-and-formulation-plugins#インストール) | `bdd-discovery-and-formulation@bdd-discovery-and-formulation` | `grill@grill`、`write-doc@write-doc` |
| [collect-and-digest-plugins](https://github.com/nakamori-naoya/collect-and-digest-plugins#インストール) | `collect-and-digest@collect-and-digest` | `write-doc@write-doc` |
| [grill-plugins](https://github.com/nakamori-naoya/grill-plugins#インストール) | `grill@grill` | なし |
| [product-planning-plugins](https://github.com/nakamori-naoya/product-planning-plugins#インストール) | `product-planning@product-planning` | `grill@grill`、`write-doc@write-doc` |
| [pull-request-plugins](https://github.com/nakamori-naoya/pull-request-plugins#インストール) | `pull-request@pull-request` | `write-doc@write-doc`、`agent-work-policy@agent-work-policy` |
| [skill-authoring-plugins](https://github.com/nakamori-naoya/skill-authoring-plugins#インストール) | `skill-authoring@skill-authoring` | なし |
| [write-doc-plugins](https://github.com/nakamori-naoya/write-doc-plugins#インストール) | `write-doc@write-doc` | なし |

Agent FleetはCoreとHerdr連携を分ける。CoreだけならHerdrは不要で、役割を渡すHookはHerdrに含まれる。grillやagent-rolesなど単独の仕事を扱うパッケージもあるため、すべてのパッケージが複数工程のplaybookを持つわけではない。

## 文書作成を例に、配布範囲を追う

`write-doc@write-doc`をインストールすると、配布定義が指す`plugins/`が一つのパッケージとして取得される。公開入口はwrite-docで、型選択・執筆・図・保存・完成文書の確認はその内部でつながる。writing-rulesやreview-docを別々にインストールする必要はない。

一方、product-planningから資料作成を頼む場合、write-docは別リポジトリの公開パッケージである。product-planningの内部へ複製せず、外部依存として別途インストールする。この違いは、機能の数ではなくパッケージの境界で決まる。

## 配布定義をどこで確かめるか

| 確認したいこと | 読む場所 | 判断すること |
|---|---|---|
| インストール対象の名前と範囲 | `.agents/plugins/marketplace.json`、`.claude-plugin/marketplace.json` | 公開名とsourceの指すパッケージ |
| 利用者へ見せる入口 | パッケージ直下の両`plugin.json`の`skills` | 公開スキルの所在 |
| 同梱する工程と内部処理 | `metadata.harness.playbooks`、`internalPlugins` | 公開入口から使う同梱機能 |
| 外部へ依頼する処理 | 各`playbook.yml`の依存宣言 | 別途必要な公開パッケージ |
| 配布の整合性 | `scripts/validate.sh` | 両環境の配布定義とリポジトリ固有の検証 |

配布定義のsourceが`./plugins`なら、その配下をまとめて配布する。単一機能やFleetのsourceが個別のディレクトリを指す場合は、その範囲を配布する。フォルダ名がskillsやplaybooksであることだけで、個別インストール対象と判断しない。

リポジトリ直下のREADME、AGENTS.md、開発用scripts、tests、sharedは、パッケージの外にある開発資産である。実行時に必要なコードや資料は配布範囲に置き、インストール先からリポジトリ直下を参照しない。

## 内部処理を追加するとき

同じ仕事を完了するための処理なら、パッケージ内へ追加して公開入口から呼ぶ。内部の配布定義を揃え、公開スキル一覧へ機械的に追加しない。別リポジトリが所有する仕事なら、その公開パッケージへ依存する。

CodexとClaude Codeの配布名・バージョン・sourceを一致させ、変更したリポジトリの検証を実行する。配布内容を変える場合はリリースのバージョンも更新する。READMEだけの修正と、利用者へ届くパッケージの変更は区別する。

Git操作の許可・検証・公開はagent-work-policyの公開playbookが担当する。他のパッケージへ判断や公開操作を複製せず、`steps[].playbook: agent-work-policy`で呼ぶ。公開packageのscriptを外部から直接実行しない。

## 導入と更新の確認範囲

具体的なコマンドは各READMEを使う。marketplaceの取得、パッケージの導入、外部依存の導入、新しい会話での入口確認までを一続きで確認する。更新は導入時と同じ設定環境・適用範囲で行う。

リポジトリの自動検証が成功しても、利用者の実環境へのインストールや外部サービスとの接続を確認したことにはならない。実行した検証と、未確認の範囲は分けて報告する。
