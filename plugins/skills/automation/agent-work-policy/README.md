# agent-work-policy

AIエージェントのGit作業を、repositoryごとの設定に従って開始・公開する。worktreeかbranchか、各操作を許すか、人間の承認をいつ求めるか、PRをいつmerge可能とみなすかを分けて扱う。

## できること

- worktreeまたは現在checkout内の専用branchで作業を開始する
- commit、push、PR作成、mergeを個別に禁止できる
- 下書きPRを、内部レビュー完了後に冪等にready for reviewへ切り替える
- 許可された操作でも、直前のhuman gateを必須にできる
- review Approve数、checks、未解決threadからmerge readinessを判定する
- merge成功後、設定に従ってcleanな副worktreeを削除する
- commit対象をpath単位に限定し、設定された検証を通す

**設定は実行環境の権限を増やさない。** permissionがfalseなら承認で上書きせず、hostや利用者が禁止する操作を設定で許可することもできない。

## 設定

repository設定は `<repo>/.harness-plugins/agent-work-policy.config.yml`。scopeが渡されたときだけscopeを先頭に、local、repository、personal、同梱既定の順で最上位の1ファイルだけを選び、マージしない。

```yaml
version: 1
workspace:
  use_worktree: false
  require_clean_start: true
  base_branch: main
  branch_prefix: agent/
  worktree_root: ""             # 空ならOSの一時directory
git:
  remote: origin
permissions:
  commit: true
  push: true
  pull_request: true
  merge: false
gates:
  before_commit: true
  before_push: true
  before_pull_request: true
  before_merge: true
verification:
  commands: ["git diff --check"]
pull_request:
  draft: true
merge:
  method: squash               # squash | merge | rebase | fast-forward
  delete_branch: false
  delete_worktree: false       # trueならmerge後にcleanな副worktreeを削除
  readiness:
    min_approvals: 1
    require_checks_passed: true
    require_no_unresolved_threads: true
instructions:
  execution:
    directive: permissionを承認で上書きせず、readinessを満たしてからhuman gateを提示し、許された操作だけを実行する
```

permissionは「してよいか」、gateは「直前に依頼者の承認が要るか」である。GitHub reviewのApproveは依頼者の承認ではなく、merge readinessの条件である。

`fast-forward`はGitHubにmerge commitを作らせず、GraphQL `updateRefs`で検査済みPR headをbaseへ進める。
`beforeOid`と`force:false`を使い、base更新と同一repositoryのhead no-op CASを1つのatomic mutationにする。head branchはGitHubのindirect merge反映を確認した後に、別のCAS mutationで削除する。
required checkにGitHub App IDが指定されている場合は、head commitのCheckRun名とApp database IDをともに照合する。merge直前の再readiness後は追加のnetwork照会を挟まずCASを送信する。
local・PR・remoteのhead SHA、PR・remoteのbase SHA、祖先関係、branch protectionのrequired checksを照合し、
更新後にGitHub上のPRがindirect mergeとして反映されたことまで確認する。

既定ではcommit・push・PR作成を許すが、各操作の直前に承認を求める。mergeは既定で禁止し、worktreeやbranchは自動削除しない。`delete_worktree: true`はworktree modeでだけ設定でき、PRのhead branchをcheckoutしたcleanな副worktreeだけを削除する。

## 適用範囲

インストールしただけでは、他skillや素のgit操作を横取りしない。すべての変更作業へ適用する場合は、repositoryの `AGENTS.md` / `CLAUDE.md` から `work-with-policy` の利用を必須にする。

## 他pluginへの公開操作API

下流pluginは、対象repositoryの解決済み設定を`control.py`へ渡して公開操作を呼び出す。

```bash
CFG_FILE=$(bash "$POLICY_ROOT/scripts/prepare.sh" "$TARGET_REPO") || exit 2
python3 "$POLICY_ROOT/scripts/control.py" permission --config "$CFG_FILE" --action pull_request
python3 "$POLICY_ROOT/scripts/control.py" pull-request --config "$CFG_FILE" --repo "$TARGET_REPO" \
  --title '<title>' --body-file '<body-file>'
python3 "$POLICY_ROOT/scripts/control.py" ready-for-review --config "$CFG_FILE" --repo "$TARGET_REPO" --pr <number>
```

入力、順序、stdout、exit、境界時の扱いは[公開操作契約](references/operation-contract.md#下流plugin向けcli契約)を正本にする。

PR作成時の設定がdraftであれば、内部レビュー完了後かつ`merge-readiness`の前に`ready-for-review`を呼ぶ。これは既存PRのレビュー受付状態を変える同じ`pull_request` permission内の遷移であり、新しい公開先やmergeを生まないため追加gateを持たない。すでに公開済みのPRは外部変更なしで成功する。

## 配布文書

| 文書 | 責務 |
|---|---|
| `SKILL.md` | 設定解決からworkspace、変更、公開、merge、報告までの順序 |
| `references/settings.md` | 全設定値の意味と作業への反映箇所 |
| `references/operation-contract.md` | permission、gate、readiness、exit contract |
| `references/activation.md` | repository全体へpolicyを有効化する方法 |

## 必要なcommand

| command | 用途 |
|---|---|
| `bash` / `jq` / `yq` v4 | 設定解決 |
| `python3` | policy、workspace、公開操作の実行 |
| `git` | branch、worktree、commit、push |
| `gh` | PR作成、review状態取得、merge |

## 安全側の固定規則

- force pushしない
- base branchへ直接pushしない
- merge readiness未充足なら承認を求めない
- 同名branch/worktreeを再利用しない
- merge前、primary worktree、dirtyなworktreeは削除しない
- worktreeとremote branchの削除は設定に従い、失敗をmerge成功として隠さない
- 実行していない操作を成功として報告しない
