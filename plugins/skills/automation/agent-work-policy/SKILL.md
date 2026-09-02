---
name: work-with-policy
description: Git repositoryでAIエージェントの変更作業を開始し、設定に従ってworktreeまたはbranchを作り、検証、commit、push、PR作成、merge、merge後のworktree削除をpermission・human gate・review条件で制御する。「このissueを実装してPRまで」「worktreeで作業して」「承認後にmergeして」と依頼されたとき、またrepositoryのAGENTS.mdで利用を必須にしているときに使う。
---

# work-with-policy

設定はsystem、利用者、実行環境の権限を増やさない。次を順番どおりに実行し、`control.py`を素の`git`や`gh`で迂回しない。

## 1. プラグイン root と設定を読む

<!-- BEGIN shared:skill-entry/root-block -->
```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/this/plugin}"
```

`PLUGIN_ROOT`は配布物rootの絶対パスである。単一skill pluginではこの`SKILL.md`があるdirectory、複数skill pluginでは`skills/<skill>/`の2つ上に当たる。Claude Codeでは`${CLAUDE_PLUGIN_ROOT}`が自動展開される。
<!-- END shared:skill-entry/root-block -->

```bash
SOURCE_REPO="$(pwd)"
```

<!-- BEGIN shared:skill-entry/config-load -->
```bash
CFG_FILE=$(bash "${PLUGIN_ROOT}/scripts/prepare.sh" "$(pwd)") || exit 2
trap 'rm -f "$CFG_FILE"' EXIT
```

**このコマンドは説明例ではない。必ず実行する。** 解決済みYAMLが空なら先へ進まない。設定ファイルを直接読んで代用しない。

本文中の `${...}` は解決済みYAMLのプロパティである。使用時に `yq -er` で読み、欠落または `null` なら停止する。
<!-- END shared:skill-entry/config-load -->

[設定値](references/settings.md)を解決済みYAMLから読み、[操作契約](references/operation-contract.md)を全操作へ適用する。

## 下流pluginから公開操作を委譲する

下流pluginは解決済み設定と対象repositoryを`control.py`へ渡す。

```bash
POLICY_ROOT="/absolute/path/to/agent-work-policy"
TARGET_REPO="/absolute/path/to/repository-being-published"
CFG_FILE=$(bash "$POLICY_ROOT/scripts/prepare.sh" "$TARGET_REPO") || exit 2
trap 'rm -f "$CFG_FILE"' EXIT

python3 "$POLICY_ROOT/scripts/control.py" permission --config "$CFG_FILE" --action pull_request
python3 "$POLICY_ROOT/scripts/control.py" pull-request --config "$CFG_FILE" --repo "$TARGET_REPO" \
  --title '<title>' --body-file '<body-file>'
```

入力、順序、stdout、exit、境界時の扱いは[公開委譲契約](references/operation-contract.md#下流plugin向けcli契約)を正本にする。

## 2. planして作業場所を開始する

設定されたprefixにtask slugを足してbranchを決める。planの停止理由を解消してからstartし、返されたworktreeを以後の作業場所にする。

```bash
BRANCH="$(yq -er '.workspace.branch_prefix' "$CFG_FILE")<task-slug>"
python3 "${PLUGIN_ROOT}/scripts/control.py" plan --config "$CFG_FILE" --repo "$SOURCE_REPO" --branch "$BRANCH"
START_JSON=$(python3 "${PLUGIN_ROOT}/scripts/control.py" start --config "$CFG_FILE" --repo "$SOURCE_REPO" --branch "$BRANCH") || exit $?
WORKTREE=$(jq -er '.worktree' <<<"$START_JSON") || exit 2
```

## 3. 依頼範囲だけ変更して検証する

既存差分を自分の変更へ含めない。設定された検証commandを`WORKTREE`で記載順に全件成功させる。commitも同じ検証を直前に再実行する。

## 4. commitする

対象pathだけを`paths.txt`へ1行ずつ書き、操作契約に従って実行する。gateが必要な場合だけ、差分と検証結果を示して承認後に`--approved`を付ける。

```bash
python3 "${PLUGIN_ROOT}/scripts/control.py" commit --config "$CFG_FILE" --repo "$WORKTREE" --paths-file paths.txt --message '<message>' [--approved]
```

## 5. pushしてPRを作る

各操作のpermissionとgateを個別に適用する。PR本文を`body.md`へ用意し、scriptにdraft設定を反映させる。

```bash
python3 "${PLUGIN_ROOT}/scripts/control.py" push --config "$CFG_FILE" --repo "$WORKTREE" [--approved]
python3 "${PLUGIN_ROOT}/scripts/control.py" pull-request --config "$CFG_FILE" --repo "$WORKTREE" --title '<title>' --body-file body.md [--approved]
```

## 6. readinessをpollしてmerge・片付けする

readinessが未充足なら状態が変わるまで待って読み直す。readyになった後だけmerge permissionとgateを適用する。merge成功後は`${.merge.delete_worktree}`に従い、cleanな副worktreeだけを削除する。

```bash
python3 "${PLUGIN_ROOT}/scripts/control.py" merge-readiness --config "$CFG_FILE" --repo "$WORKTREE" --pr <number>
python3 "${PLUGIN_ROOT}/scripts/control.py" merge --config "$CFG_FILE" --repo "$WORKTREE" --pr <number> [--approved]
```

## 7. 結果を報告する

mode、branch、worktree、検証、commit、push先、PR、readiness、merge、worktree削除、停止理由、未実行操作を報告する。削除失敗をmerge成功だけで隠さない。repository全体への[有効化](references/activation.md)は別途行う。
