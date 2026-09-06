---
name: work-with-policy
description: Git repositoryでAIエージェントの変更作業を開始し、設定に従ってworktreeまたはbranchを作り、検証、commit、push、PR作成、merge、merge後のworktree削除をpermission・human gate・review条件で制御する。「このissueを実装してPRまで」「worktreeで作業して」「承認後にmergeして」と依頼されたとき、またrepositoryのAGENTS.mdで利用を必須にしているときに使う。
---

# agent-work-policy

**Git作業の1操作を、repositoryのpolicyに従って実行する。** 設定はsystem、利用者、実行環境の権限を増やさない。素の`git`や`gh`で内部制御を迂回しない。

公開する入力・出力・保証は[契約](CONTRACT.md)が正本である。呼び出し元が渡した入力に無い操作を、気を利かせて足さない。

## 0. プラグイン root を決める

<!-- BEGIN shared:skill-entry/root-block -->
```bash
BUNDLE_ROOT="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/this/plugin}"
if [ -d "${BUNDLE_ROOT}/playbooks/automation/agent-work-policy" ]; then
  PLUGIN_ROOT="${BUNDLE_ROOT}/playbooks/automation/agent-work-policy"
else
  PLUGIN_ROOT="${BUNDLE_ROOT}"
fi
```

`PLUGIN_ROOT`は配布物rootの絶対パスである。単一skill pluginではこの`SKILL.md`があるdirectory、複数skill pluginでは`skills/<skill>/`の2つ上に当たる。Claude Codeでは`${CLAUDE_PLUGIN_ROOT}`が自動展開される。
<!-- END shared:skill-entry/root-block -->

## 1. 入力と工程を解決する

**呼び出し元が解決済みYAMLのpathを渡してきたなら、prepareを再実行しない。** 段取りの入れ子で
prepareを重ねると、入口が決めた scope と束縛lockが捨てられ、別の実行設定が二重に作られ、
後始末の持ち主も分からなくなる。**自分でprepareするのは、自分が入口のとき（単独起動）だけである。**
そのときは呼び出し元が渡した入力YAMLの絶対pathを`--input`で渡す。

<!-- BEGIN shared:skill-entry/config-load -->
```bash
if [ -n "${CFG_FILE:-}" ] && [ -f "$CFG_FILE" ]; then
  : # 呼び出し元がE1で解決済み。prepareを再実行しない（後始末は最後にこちらが行う）
else
  CFG_FILE=$(bash "${PLUGIN_ROOT}/scripts/prepare.sh" "$(pwd)" --input="$INPUT_FILE") || exit 2
fi
printf '%s\n' "$CFG_FILE"
```

**このコマンドは説明例ではない。必ず実行する。** 解決済みYAMLが空なら先へ進まない。設定ファイルを直接読んで代用しない。

本文中の `${...}` は解決済みYAMLのプロパティである。使用時に `yq -er` で読み、欠落または `null` なら停止する。
<!-- END shared:skill-entry/config-load -->

呼び出し元が段取りとしてこれを呼ぶときは、**自分の `prepare.sh --input=<abs> --scope=<dir> --bindings=<lock>` が返した解決済みYAMLのpathをそのまま渡す**（[契約](CONTRACT.md) §1 E1）。こちらはそれを `CFG_FILE` として使う。

利用者が直接この skill を呼んだ場合は入力YAMLが無い。そのときは依頼から`action`と`repo`を決め、[契約](CONTRACT.md)の入力schemaに従うYAMLを一時領域へ書いてから`--input`で渡す。**入力を作らずに操作へ進まない。**

最初に `${.instructions.execution.directive}` と `${.instructions.output.directive}` に従う。

## 2. 入力を検査する

`${.input}` から読み、次を満たさなければ何も実行せず`invalid_input`で停止する。

- `${.input.contract}` が `agent-work-policy/agent-work-policy`、`${.input.version}` が `1`
- `${.input.action}` が `${.playbook.contract.actions}` に含まれる**1つ**の値
- `${.input.repo}` と `${.input.output_to}` が絶対path
- その action の必須入力（[契約](CONTRACT.md) §2）が揃っている

**入力に無い action を実行しない。** `commit`を頼まれて`push`まで進めない。承認を得ていないのに`${.input.approved}`を真として扱わない。

## 3. 1つのactionだけを実行する

`${.playbook.steps[0]}` の工程を、`${.input.action}` に対応する1操作として実行する。

```bash
yq -o=json '.' "$CFG_FILE" | python3 "${PLUGIN_ROOT}/scripts/resolve-dependency.py" --check-steps apply || exit 2
```

工程は `${.deps["work-policy-control"].skills["apply-work-policy"]}` の SKILL.md に従って実行する。渡すのは `${.input.action}`、`${.input.repo}`、`${.input.approved}`、その action の追加入力だけである。**この工程を呼ぶときは `--scope=${.resolution.scope_root}` を必ず渡す。**

工程からは、実行結果に加えて次の3つを必ず受け取る。

1. permission と gate の判定（許可された／承認待ち／拒否された）
2. 承認待ちなら、**何を承認するのか**が分かる対象（変更規模、送り先、詳細の全文path）
3. 作業場所の値（base branch、remote、draft設定、作業branch、worktree）

**exit 2 で止まったら先へ進まない。** 部分的に実行した操作を成功として報告しない。

## 4. 公開出力を書く

工程の結果を[契約](CONTRACT.md) §3 の出力schemaへ写し、`${.input.output_to}` の絶対pathへYAMLで書く。

- `status`、`gate_state`、`workspace` は**必ず**書く。`workspace`は成功・承認待ち・失敗のどれでも書く
- 承認待ちなら `gate_context` を書く。承認対象が分からない出力にしない
- 成功したときだけ `result` を書く。実行していない操作、取得できなかったPR状態、失敗した削除を成功として書かない
- 失敗したら `reason` を §3.4 の語彙から1つ選んで書く

**内部の状態名・exit code・script名を出力へ漏らさない。** 呼び出し元が読むのは契約の語彙だけである。

## 5. 報告する

`action`、判定（許可／承認待ち／拒否）、実行した操作の結果、`workspace`、出力を書いたpath、停止したならその理由を報告する。承認待ちのときは、承認対象と「承認を得たら同じactionを`approved: true`で呼び直す」ことを示す。

## 実行設定の寿命

**受け取ったCFG_FILEも、後始末するのはこちらである（AP8）。** それは呼び出し元が E1 で**この段取りの `prepare.sh`** を呼んで作らせたものであり、この実行のための設定だからである。

prepareが返した絶対pathを実行記録へ保持する。別shellではそのpathを`CFG_FILE`へ明示して読み、shell変数の継承を前提にしない。完了時と失敗停止時のどちらも、最後の設定利用後に`python3 "${PLUGIN_ROOT}/scripts/run-config.py" cleanup --config "$CFG_FILE"`を実行する。他runの設定やdirectoryを削除しない。**呼び出し元にこの後始末を代行させない。**
