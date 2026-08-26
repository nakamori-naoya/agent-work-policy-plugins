---
name: work-with-policy
description: Git repositoryでAIエージェントの変更作業を開始し、設定に従ってworktreeまたはbranchを作り、検証、commit、push、PR作成、merge、merge後のworktree削除をpermission・human gate・review条件で制御する。「このissueを実装してPRまで」「worktreeで作業して」「承認後にmergeして」と依頼されたとき、またrepositoryのAGENTS.mdで利用を必須にしているときに使う。
---

# work-with-policy

このentryは配布形式を中立化する薄い入口である。次を実行してplugin rootを検証し、root直下の正本`SKILL.md`を全文読んで、その手順に従う。

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/this/plugin}"
bash "${PLUGIN_ROOT}/scripts/prepare.sh" --root-only >/dev/null || exit 2
cat "${PLUGIN_ROOT}/SKILL.md"
```
