#!/usr/bin/env bash
# agent-work-policy/agent-work-policy 契約 v1 の入力 schema を入口で検査する
# （共通resolverの任意hook）。
#
#   validate-input.sh <正規化済みの入力YAMLの絶対path>
#
# **共通resolverが見るのは contract / version / action / output_to だけである。**
# action ごとの必須キー・未知キーの拒否・値の形はここでしか見られない。
# **1呼び出し1action。** その action が使わないキーは未知キーとして拒否する。
# 「commitのつもりでtitleも書いた」入力を黙って受け取ると、実行側が別の操作を
# 推測する余地を残す。
#
# exit 0 で受理、非0で拒否。診断は stderr へ [error:input-schema] key=value の1行。
# **stdoutは使わない。** 呼び出し元は stdout を解決済みYAMLのpathに使う。
set -euo pipefail

reject() { echo "[error:input-schema] $*" >&2; exit 2; }

[ "$#" -eq 1 ] || reject 'reason=usage detail=validate-input.sh <input>'
input="$1"
[ -f "$input" ] || reject "path=${input} reason=not-file"

work=$(mktemp -d "${TMPDIR:-/tmp}/awp-input.XXXXXX") || reject 'reason=tmpdir-unavailable'
trap 'rm -rf "$work"' EXIT
yq -o=json -I=0 '.' "$input" > "$work/input.json" 2>/dev/null \
  || reject "path=${input} reason=yaml-parse"

python3 - "$work/input.json" <<'PY'
import json
import os
import sys
from pathlib import Path

CONTRACT = "agent-work-policy/agent-work-policy"
VERSION = 1
# 常に要る5キー。approved は gate のある action だけが持てる（CONTRACT.md §2 の対象action列）。
BASE_REQUIRED = ("contract", "version", "action", "repo", "output_to")
GATED = {"commit", "push", "pull-request", "merge"}
# actionごとの追加入力。ここに無いキーは、そのactionでは未知キーである。
PER_ACTION = {
    # inspect は read-only の照会。追加入力を取らず、gate も permission も持たない。
    "inspect": (),
    "plan": ("branch",),
    "start": ("branch",),
    "commit": ("paths", "message"),
    "push": (),
    "pull-request": ("title", "body_file"),
    "ready-for-review": ("pr",),
    "merge-readiness": ("pr",),
    "merge": ("pr",),
    "cleanup": ("pr",),
}


def reject(**fields):
    detail = " ".join("{}={}".format(k, v) for k, v in fields.items())
    print("[error:input-schema] " + detail, file=sys.stderr)
    raise SystemExit(2)


def nonempty_text(value, field):
    if not isinstance(value, str) or not value.strip() or any(ord(ch) < 32 for ch in value):
        reject(field=field, reason="non-empty-single-line-string")
    return value


payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    reject(reason="not-mapping")

if payload.get("contract") != CONTRACT:
    reject(field="contract", reason="fixed", expected=CONTRACT)
if type(payload.get("version")) is not int or payload["version"] != VERSION:
    reject(field="version", reason="fixed", expected=str(VERSION))

action = payload.get("action")
if action not in PER_ACTION:
    reject(field="action", reason="unknown-action", value=str(action))

extra = PER_ACTION[action]
allowed = set(BASE_REQUIRED) | set(extra) | ({"approved"} if action in GATED else set())
unknown = sorted(set(payload) - allowed)
if unknown:
    reject(action=action, reason="unknown-keys", keys=",".join(unknown))
missing = sorted((set(BASE_REQUIRED) | set(extra)) - set(payload))
if missing:
    reject(action=action, reason="missing-keys", keys=",".join(missing))

if "approved" in payload and type(payload["approved"]) is not bool:
    reject(field="approved", reason="boolean")

repo = payload["repo"]
if not isinstance(repo, str) or not repo or not Path(repo).is_absolute():
    reject(field="repo", reason="absolute-path")
if not Path(os.path.realpath(repo)).is_dir():
    reject(field="repo", reason="not-directory")

output_to = payload["output_to"]
if not isinstance(output_to, str) or not output_to or not Path(output_to).is_absolute() \
        or Path(output_to).name in {"", ".", ".."}:
    reject(field="output_to", reason="absolute-file-path")

if "branch" in payload:
    branch = nonempty_text(payload["branch"], "branch")
    if branch.startswith("-") or branch.endswith("/") or ".." in branch \
            or any(ch.isspace() for ch in branch) or branch.startswith("/"):
        reject(field="branch", reason="git-branch-name")

if "paths" in payload:
    paths = payload["paths"]
    if not isinstance(paths, list) or not paths:
        reject(field="paths", reason="non-empty-array")
    seen = set()
    for index, item in enumerate(paths):
        nonempty_text(item, "paths[{}]".format(index))
        if Path(item).is_absolute() or ".." in Path(item).parts:
            reject(field="paths[{}]".format(index), reason="relative-to-repo-root")
        if item in seen:
            reject(field="paths[{}]".format(index), reason="duplicate")
        seen.add(item)

for key in ("message", "title"):
    if key in payload:
        nonempty_text(payload[key], key)

if "body_file" in payload:
    body_file = payload["body_file"]
    if not isinstance(body_file, str) or not body_file or not Path(body_file).is_absolute():
        reject(field="body_file", reason="absolute-path")
    if not Path(os.path.realpath(body_file)).is_file():
        reject(field="body_file", reason="not-file")

if "pr" in payload:
    pr = payload["pr"]
    if type(pr) is not int or pr <= 0:
        reject(field="pr", reason="positive-integer")
PY
