> 作業を始める前に、workspace規約入口 `/Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/AGENTS.md` を読み、そこから指定される共通規約とこのrepository固有の規則を適用する。

# AGENTS.md

このrepositoryは、変更、commit、push、PR、mergeの権限とhuman gateをrepositoryのpolicyに従って適用する単一marketplaceである。

## 公開面は入口1つだけ

marketplaceへ公開するインストール対象は、package `agent-work-policy`（`./plugins/agent-work-policy`）1件だけにする。公開入口は `skills/agent-work-policy` 1つで、公開playbook `agent-work-policy` でもある。内部skill、内部plugin、他の作業pluginを追加しない。

| 面 | 実体 | 外部から |
|---|---|---|
| 公開入口 / 公開 playbook | `plugins/agent-work-policy/skills/agent-work-policy`（SKILL.md `name: agent-work-policy`） | 利用者が直接呼べる。別pluginは `steps[].playbook: agent-work-policy` で呼べる |
| 公開 entry | 同 `scripts/invoke.py` | 契約入力objectを標準入力で受け、契約出力objectを返す |
| 内部 script | 同 `scripts/control.py` | **呼べない** |

外部pluginへ公開するのは、[CONTRACT.md](plugins/agent-work-policy/skills/agent-work-policy/CONTRACT.md)が定める入口・入力・出力・保証だけである。次は公開しない。文書にも書かない。

- `control.py` の引数、サブコマンド名、exit code
- policy設定の schema・キー（利用者向けの公開契約であって、消費側 plugin が触る面ではない）
- `references/` の文書とその節

消費側が必要とする値（base branch、remote、draft設定、作業branch、worktree）は、公開出力の `workspace` として毎回返す。**消費側にこのpackageの設定を読ませない。**

## policy設定は repository 1層

policy設定は `<repo>/.harness-plugins/agent-work-policy.config.yml` だけを読む。公開入口の手順が呼ぶ設定読み取りは `scripts/config.py check|read --repo <path>` だけで、schemaの契約定義は `control.py` の `POLICY_SCHEMA` / `validate_policy` である。個人設定、端末固有設定、同梱既定へのfallback、設定解決runtime（`prepare.sh` / `resolve.sh` / `run-config.py`）を置かない。記入例は `assets/policy.example.yml` で、既定値として読まれない。`SKILL.md`、`references/`、`playbook.yml` に `${.` マクロ、同期block、環境変数によるroot解決を書かない。

## 契約を変えるとき

1. `plugins/agent-work-policy/.claude-plugin/plugin.json` と `.codex-plugin/plugin.json` の `metadata.harness` を**両方同時に**変える。両者は完全一致でなければならない。
2. `implements[0].actions` と `playbook.yml` の `contract.actions` を同じ集合に保つ。action は kebab-case。
3. `CONTRACT.md` の入口・入力・出力・保証・利用者設定・非契約を更新する。契約の版は 1 固定である。§5.1 の schema、`assets/policy.example.yml`、`control.py` の `POLICY_SCHEMA` は同じキー集合を持つ。
4. 1 呼び出し 1 action を崩さない。

## 共通実装

保守tool（root契約の構造検査、回帰検査、消費側lint、release、eval）の基準資料は兄弟checkout `../harness-tools/` であり、このrepositoryは複製を持たない。`scripts/validate.sh` は `../harness-tools/tools` の実在を確認してから呼び、無ければ止まる。

## 変更後

```bash
bash scripts/validate.sh
bash /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/scripts/validate.sh /Users/naoya-nakamoriq/Documents/Github/harness-pluginsv2/agent-work-policy-plugins
```
