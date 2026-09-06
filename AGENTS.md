# AGENTS.md

このrepositoryは、変更、commit、push、PR、mergeの権限とhuman gateを解決する単一marketplaceである。

## 公開面はPlaybook 1枚だけ

marketplaceへ公開するインストール対象は、Playbook package `agent-work-policy`（`./plugins`）1件だけにする。内部処理や管理者判定を別entryへ分解せず、他の作業pluginを追加しない。

| 面 | 実体 | 外部から |
|---|---|---|
| 公開 playbook | `plugins/playbooks/automation/agent-work-policy` | `steps[].playbook: agent-work-policy` で呼べる |
| 利用者導線の skill | 同 `SKILL.md` の frontmatter `name: work-with-policy` | 利用者が直接呼べる |
| 内部 plugin | `plugins/skills/automation/work-policy-control`（skill `apply-work-policy`） | **呼べない** |

外部pluginへ公開するのは、[CONTRACT.md](plugins/playbooks/automation/agent-work-policy/CONTRACT.md)が定める入口・入力・出力・保証だけである。次は公開しない。文書にも書かない。

- `control.py` / `prepare.sh` / `run-config.py` の存在、引数、サブコマンド名、exit code
- 設定ファイルの名前・場所・schema・キー
- 内部 plugin 名（`work-policy-control`）と内部 skill 名（`apply-work-policy`）
- `references/` の文書とその節

消費側が必要とする値（base branch、remote、draft設定、作業branch、worktree）は、公開出力の `workspace` として毎回返す。**消費側にこのpackageの設定を読ませない。**

## 契約を変えるとき

1. `plugins/.claude-plugin/plugin.json` と `plugins/.codex-plugin/plugin.json` の `metadata.harness` を**両方同時に**変える。両者は完全一致でなければならない。
2. `implements[0].actions` と `playbook.yml` の `contract.actions` を同じ集合に保つ。action は kebab-case。
3. `CONTRACT.md` の入口・入力・出力・保証・非契約を更新する。契約の版は 1 固定である。
4. 1 呼び出し 1 action を崩さない。工程は `apply-work-policy` の1件だけにする。

## 共通実装

`shared/playbook/`、`shared/prepare.sh`、`shared/skill/` と配布物内の複製は、Product Planning repositoryの`shared/runtime-source`が正本である。個別に編集せず、`python3 scripts/sync-runtime.py --source <正本checkout>` で取り込む。

## 変更後

```bash
bash scripts/validate.sh
```
