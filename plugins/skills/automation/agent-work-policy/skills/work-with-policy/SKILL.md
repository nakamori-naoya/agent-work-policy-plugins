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
printf '%s\n' "$CFG_FILE"
```

**このコマンドは説明例ではない。必ず実行する。** 解決済みYAMLが空なら先へ進まない。設定ファイルを直接読んで代用しない。

本文中の `${...}` は解決済みYAMLのプロパティである。使用時に `yq -er` で読み、欠落または `null` なら停止する。
<!-- END shared:skill-entry/config-load -->

[設定値](../../references/settings.md)を解決済みYAMLから読み、[操作契約](../../references/operation-contract.md)を全操作へ適用する。

## 下流pluginから公開操作を委譲する

下流pluginは解決済み設定と対象repositoryを`control.py`へ渡す。

```bash
POLICY_ROOT="/absolute/path/to/agent-work-policy"
TARGET_REPO="/absolute/path/to/repository-being-published"
CFG_FILE=$(bash "$POLICY_ROOT/scripts/prepare.sh" "$TARGET_REPO") || exit 2
printf '%s\n' "$CFG_FILE"

python3 "$POLICY_ROOT/scripts/control.py" permission --config "$CFG_FILE" --action pull_request
python3 "$POLICY_ROOT/scripts/control.py" pull-request --config "$CFG_FILE" --repo "$TARGET_REPO" \
  --title '<title>' --body-file '<body-file>'
python3 "$POLICY_ROOT/scripts/control.py" ready-for-review --config "$CFG_FILE" --repo "$TARGET_REPO" --pr <number>
```

入力、順序、stdout、exit、境界時の扱いは[公開委譲契約](../../references/operation-contract.md#下流plugin向けcli契約)を正本にする。

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

内部レビューが完了し、作成時のdraft設定によりPRが下書きなら、merge readinessの前にだけ次を呼ぶ。すでに公開済みなら外部変更なしで成功する。

```bash
python3 "${PLUGIN_ROOT}/scripts/control.py" ready-for-review --config "$CFG_FILE" --repo "$WORKTREE" --pr <number>
```

```bash
python3 "${PLUGIN_ROOT}/scripts/control.py" merge-readiness --config "$CFG_FILE" --repo "$WORKTREE" --pr <number>
python3 "${PLUGIN_ROOT}/scripts/control.py" merge --config "$CFG_FILE" --repo "$WORKTREE" --pr <number> [--approved]
```

`merge_partial`ではbase更新を再実行しない。GitHub上のPR状態を確認し、merge済みならcleanupだけを再開する。

required checkがGitHub Appへ固定されている場合、同名の別Appやlegacy StatusContextを成功へ読み替えない。readiness取得不能や100件を超えて完全取得できない場合も停止する。

必要承認数0でGitHubが`BLOCKED`を返した場合は、対象branchへ適用中のRuleset、許可merge method、現在利用者のPR bypass権限を検査する。全条件が確認できたときだけ承認不足を許容し、required checkと未解決threadは通常どおり要求する。

fast-forwardではprotection、checks、thread取得後にPRを最終再取得し、最初のsnapshotとのhead/base一致を含めて再評価する。公開対象はrepository identityから確定した`nameWithOwner`へ固定し、`GH_REPO`などで変更しない。

pushとPR作成は実行時のrepository identity、単一push URL、local/remote head SHAを照合する。`merge_partial`はref更新の成否を否定できない状態なのでmergeを再実行しない。

```bash
python3 "${PLUGIN_ROOT}/scripts/control.py" cleanup --config "$CFG_FILE" --repo "$WORKTREE" --pr <number>
```

## 7. 結果を報告する

mode、branch、worktree、検証、commit、push先、PR、readiness、merge、worktree削除、停止理由、未実行操作を報告する。削除失敗をmerge成功だけで隠さない。repository全体への[有効化](../../references/activation.md)は別途行う。

## 実行設定の寿命

prepareが返した絶対pathを実行記録へ保持する。別shellではそのpathを`CFG_FILE`へ明示して読み、shell変数の継承を前提にしない。完了時と失敗停止時のどちらも、最後の設定利用後に`python3 "${PLUGIN_ROOT}/scripts/run-config.py" cleanup --config "$CFG_FILE"`を実行する。他runの設定やdirectoryを削除しない。
