#!/usr/bin/env python3
"""Invoke the public agent-work-policy contract with JSON object input/output.

  python3 scripts/invoke.py < input.json

入力: CONTRACT.md §2 のJSON objectを標準入力から1つ受け取る。
policy: 対象repository root の .harness-plugins/agent-work-policy.config.yml（1層・必須・fallback無し）。
出力: CONTRACT.md §3 のJSON objectを標準出力へ1行で返す。
exit: 0 = completed、2 = 入力不備または policy 不備（Git操作前に停止）、3 = 承認待ち・拒否・操作失敗。

承認は `approval` object（actions・対象・期限・利用者の原文）で受け、今回のactionと対象と時刻が範囲に入るときだけ
gateを通す。範囲に入らなければgateで止まり、外れた要素を approval_target に添える。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


CONTRACT = "agent-work-policy/agent-work-policy"
ACTIONS = {
    "inspect": (), "plan": ("branch",), "start": ("branch",),
    "commit": ("paths", "message"), "push": (), "update-branch": ("pr",),
    "pull-request": ("title", "body_file"),
    "ready-for-review": ("pr",), "merge-readiness": ("pr",),
    "merge": ("pr",), "cleanup": ("pr",),
}
GATED = {"commit", "push", "pull-request", "merge"}
POLICY_FILE = Path(".harness-plugins/agent-work-policy.config.yml")
PUBLIC_REASONS = {
    "permission_denied", "not_ready", "verification_failed", "no_changes",
    "invalid_input", "policy_missing", "merge_partial", "merge_failed", "cleanup_failed", "conflicts", "error",
}
APPROVAL_KEYS = {"actions", "pull_requests", "branches", "until", "quote"}
SUCCESS_STATUSES = {
    "inspect": {"inspected"}, "plan": {"ready"}, "start": {"created"},
    "commit": {"committed"}, "push": {"pushed"}, "update-branch": {"updated"}, "pull-request": {"created"},
    "ready-for-review": {"ready"}, "merge-readiness": {"ready", "not_ready"},
    "merge": {"merged"}, "cleanup": {"cleaned"},
}


def emit(payload: dict, code: int) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    raise SystemExit(code)


def failed(action: object, reason: str, detail: object = None, code: int = 2) -> None:
    payload = {
        "contract": CONTRACT, "version": 1, "action": action,
        "status": "failed", "gate_state": "denied",
        "operation_result": {},
        "workspace": {
            "base_branch": None, "remote": None, "draft": None,
            "branch": None, "worktree": None,
        },
        "reason": reason,
    }
    if detail is not None:
        payload["detail"] = detail
    emit(payload, code)


def validate(payload: object) -> dict:
    if not isinstance(payload, dict):
        failed(None, "invalid_input", "input must be an object")
    action = payload.get("action")
    if payload.get("contract") != CONTRACT or type(payload.get("version")) is not int or payload["version"] != 1:
        failed(action, "invalid_input", "contract or version mismatch")
    if not isinstance(action, str) or action not in ACTIONS:
        failed(action, "invalid_input", "unknown action")
    required = {"contract", "version", "action", "repo", *ACTIONS[action]}
    allowed = required | ({"approval"} if action in GATED else set())
    if set(payload) != allowed and not (set(payload) == required and action in GATED):
        failed(action, "invalid_input", {"unexpected": sorted(set(payload) - allowed), "missing": sorted(required - set(payload))})
    repo = payload.get("repo")
    if not isinstance(repo, str) or not Path(repo).is_absolute() or not Path(os.path.realpath(repo)).is_dir():
        failed(action, "invalid_input", "repo must be an existing absolute directory")
    if "approval" in payload:
        problem = approval_shape_problem(payload["approval"])
        if problem:
            failed(action, "invalid_input", f"approval {problem}")
    for key in ("branch", "message", "title"):
        if key in payload and (not isinstance(payload[key], str) or not payload[key].strip() or "\n" in payload[key]):
            failed(action, "invalid_input", f"{key} must be non-empty single-line text")
    if "pr" in payload and (type(payload["pr"]) is not int or payload["pr"] <= 0):
        failed(action, "invalid_input", "pr must be a positive integer")
    if "body_file" in payload:
        body = payload["body_file"]
        if not isinstance(body, str) or not Path(body).is_absolute() or not Path(os.path.realpath(body)).is_file():
            failed(action, "invalid_input", "body_file must be an existing absolute file")
    if "paths" in payload:
        paths = payload["paths"]
        if (not isinstance(paths, list) or not paths
                or any(not isinstance(item, str) for item in paths)
                or len(paths) != len(set(paths))
                or any(not item or item.splitlines() != [item] or item != item.strip()
                       or Path(item).is_absolute() or ".." in Path(item).parts for item in paths)):
            failed(
                action,
                "invalid_input",
                "paths must be unique exact repository-relative single-line paths without surrounding whitespace",
            )
    return payload


def parse_until(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def approval_shape_problem(approval: object) -> str | None:
    """承認範囲の形を検査する。列挙できない範囲（「危険でない限り」など）はこの形に入らない。"""
    if not isinstance(approval, dict) or not set(approval) <= APPROVAL_KEYS:
        return "must be an object with actions, pull_requests or branches, until, quote"
    actions = approval.get("actions")
    if not isinstance(actions, list) or not actions or any(item not in GATED for item in actions) or len(actions) != len(set(actions)):
        return "actions must be unique gated actions"
    if "pull_requests" not in approval and "branches" not in approval:
        return "must enumerate pull_requests or branches"
    prs = approval.get("pull_requests", [])
    if not isinstance(prs, list) or any(type(item) is not int or item <= 0 for item in prs):
        return "pull_requests must be positive integers"
    branches = approval.get("branches", [])
    if not isinstance(branches, list) or any(not isinstance(item, str) or not item.strip() for item in branches):
        return "branches must be non-empty strings"
    if parse_until(approval.get("until")) is None:
        return "until must be an ISO 8601 time with a UTC offset"
    quote = approval.get("quote")
    if not isinstance(quote, list) or not quote or any(not isinstance(item, str) or not item.strip() for item in quote):
        return "quote must list the user's own words verbatim"
    return None


def approval_policy_problem(approval: dict, cfg: dict) -> str | None:
    """承認範囲がpolicyの作業branchの外（base branchなど）へ広がっていないかを検査する。"""
    workspace = cfg.get("workspace") or {}
    prefix, base = workspace.get("branch_prefix"), workspace.get("base_branch")
    for entry in approval.get("branches", []):
        if entry == base or not isinstance(prefix, str) or not entry.startswith(prefix):
            return f"branches entry {entry!r} must be a work branch or prefix under {prefix!r}"
    return None


def branch_in_scope(branch: str | None, entries: list[str]) -> bool:
    """末尾が / の要素はprefixとして、それ以外は名前の完全一致で照合する。"""
    return branch is not None and any(
        branch.startswith(entry) if entry.endswith("/") else branch == entry for entry in entries
    )


def approval_mismatch(approval: dict, action: str, pr: int | None, branch: str | None, now: datetime) -> list[str]:
    """今回の実行が承認範囲に入らない要素を返す。空なら範囲内。mergeの対象はPR、それ以外は作業branch。"""
    outside = []
    if action not in approval["actions"]:
        outside.append("action")
    if action == "merge":
        if pr not in approval.get("pull_requests", []):
            outside.append("pull_request")
    elif not branch_in_scope(branch, approval.get("branches", [])):
        outside.append("branch")
    if not now < parse_until(approval["until"]):
        outside.append("until")
    return outside


def read_json(command: list[str], **kwargs) -> tuple[int, dict]:
    result = subprocess.run(command, text=True, capture_output=True, **kwargs)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return 3, {"status": "failed", "reason": "invalid_internal_result"}
    if not isinstance(value, dict):
        return 3, {"status": "failed", "reason": "invalid_internal_result"}
    return result.returncode, value


def normalize_internal_operation(code: int, value: dict) -> tuple[int, dict]:
    """Require control.py's result discriminator before public status handling."""
    status = value.get("status")
    if not isinstance(status, str) or not status:
        if code == 2 and isinstance(value.get("error"), str):
            # control.py が Git 操作前に止めた診断（policy schema、引数、repository）。語彙は error のまま、診断だけを添える。
            return 3, {"status": "failed", "reason": "error", "detail": value}
        return 3, {"status": "failed", "reason": "invalid_internal_result"}
    return code, value


def map_completed_operation(action: str, operation: dict, cfg: dict) -> dict:
    """Map internal results to the stable public result schema; never pass through implicitly."""
    if action == "inspect":
        pr = operation.get("pull_request")
        if isinstance(pr, dict):
            pr = pr.get("number")
        result = {
            "mode": operation.get("mode"), "clean": operation.get("clean"),
            "base_branch_exists": operation.get("base_branch_exists"), "pull_request": pr,
        }
    elif action == "plan":
        result = {
            "mode": operation.get("mode"), "branch": operation.get("branch"),
            "base_branch": operation.get("base_branch"), "clean": not operation.get("source_dirty", False),
        }
    elif action == "start":
        result = {"mode": operation.get("mode"), "branch": operation.get("branch"), "worktree": operation.get("worktree")}
    elif action == "commit":
        result = {key: operation.get(key) for key in ("branch", "sha", "paths")}
    elif action == "push":
        result = {key: operation.get(key) for key in ("branch", "sha", "remote")}
    elif action == "update-branch":
        result = {"pull_request": operation.get("pr"), "changed": operation.get("changed"), "sha": operation.get("sha")}
    elif action == "pull-request":
        url = operation.get("url")
        match = re.search(r"/pull/(\d+)/?$", url) if isinstance(url, str) else None
        if match is None:
            raise ValueError("pull-request result has no public PR identity")
        result = {"pull_request": int(match.group(1)), "url": url, "draft": cfg.get("pull_request", {}).get("draft")}
    elif action == "ready-for-review":
        result = {"pull_request": operation.get("pr"), "changed": operation.get("changed")}
    elif action == "merge-readiness":
        result = {
            "pull_request": operation.get("pr"),
            "ready": operation.get("status") == "ready",
            "unmet": operation.get("reasons", []),
        }
    elif action == "merge":
        result = {
            "pull_request": operation.get("pr"), "merged": operation.get("status") == "merged",
            "method": operation.get("method"), "sha": operation.get("merge_sha"),
        }
    elif action == "cleanup":
        worktree = operation.get("worktree_cleanup") or {}
        result = {
            "pull_request": operation.get("pr"), "branch_deleted": operation.get("branch_deleted"),
            "worktree_deleted": worktree.get("deleted"),
        }
    else:
        raise ValueError("unknown action")

    text = lambda value: isinstance(value, str) and bool(value)
    integer = lambda value: type(value) is int and value > 0
    boolean = lambda value: type(value) is bool
    validators = {
        "inspect": lambda r: text(r["mode"]) and boolean(r["clean"]) and boolean(r["base_branch_exists"])
            and (r["pull_request"] is None or integer(r["pull_request"])),
        "plan": lambda r: text(r["mode"]) and text(r["branch"]) and text(r["base_branch"]) and boolean(r["clean"]),
        "start": lambda r: text(r["mode"]) and text(r["branch"]) and text(r["worktree"]),
        "commit": lambda r: text(r["branch"]) and text(r["sha"]) and isinstance(r["paths"], list)
            and all(text(item) for item in r["paths"]),
        "push": lambda r: all(text(r[key]) for key in ("branch", "sha", "remote")),
        "update-branch": lambda r: integer(r["pull_request"]) and boolean(r["changed"]) and text(r["sha"]),
        "pull-request": lambda r: integer(r["pull_request"]) and text(r["url"]) and boolean(r["draft"]),
        "ready-for-review": lambda r: integer(r["pull_request"]) and boolean(r["changed"]),
        "merge-readiness": lambda r: integer(r["pull_request"]) and boolean(r["ready"])
            and isinstance(r["unmet"], list) and all(text(item) for item in r["unmet"]),
        "merge": lambda r: integer(r["pull_request"]) and boolean(r["merged"])
            and text(r["method"]) and text(r["sha"]),
        "cleanup": lambda r: integer(r["pull_request"]) and boolean(r["branch_deleted"])
            and boolean(r["worktree_deleted"]),
    }
    if not validators[action](result):
        raise ValueError("internal result does not satisfy public schema")
    return result


def is_completed_result(action: str, status: object, code: int) -> bool:
    """Accept the documented negative query exit, never an arbitrary nonzero exit."""
    if not isinstance(status, str):
        return False
    negative_query = action == "merge-readiness" and status == "not_ready" and code == 3
    return (code == 0 or negative_query) and status in SUCCESS_STATUSES[action]


def main() -> None:
    try:
        payload = validate(json.load(sys.stdin))
    except (json.JSONDecodeError, UnicodeError) as exc:
        failed(None, "invalid_input", str(exc))

    control = Path(__file__).resolve().with_name("control.py")
    action = payload["action"]
    root = subprocess.run(["git", "-C", payload["repo"], "rev-parse", "--show-toplevel"], text=True, capture_output=True)
    if root.returncode != 0:
        failed(action, "invalid_input", "repo must be inside a git repository")
    config_path = Path(os.path.realpath(root.stdout.strip())) / POLICY_FILE
    if config_path.is_symlink() or not config_path.is_file():
        failed(action, "policy_missing", {"expected": str(config_path)}, code=3)
    cfg_code, cfg = read_json(["yq", "-o=json", ".", str(config_path)])
    if cfg_code != 0 or not isinstance(cfg, dict):
        failed(action, "error", {"policy": str(config_path), "detail": "policy file is not readable YAML"}, code=3)
    if "approval" in payload:
        problem = approval_policy_problem(payload["approval"], cfg)
        if problem:
            failed(action, "invalid_input", f"approval {problem}")
    command = [sys.executable, str(control), action, "--config", str(config_path), "--repo", payload["repo"]]
    paths_file = None
    try:
        if action in {"plan", "start"}:
            command += ["--branch", payload["branch"]]
        if action == "commit":
            handle, paths_file = tempfile.mkstemp(prefix="agent-work-policy-paths-", text=True)
            os.close(handle)
            Path(paths_file).write_text("\n".join(payload["paths"]) + "\n", encoding="utf-8")
            command += ["--paths-file", paths_file, "--message", payload["message"]]
        if action == "pull-request":
            command += ["--title", payload["title"], "--body-file", payload["body_file"]]
        if action in {"update-branch", "ready-for-review", "merge-readiness", "merge", "cleanup"}:
            command += ["--pr", str(payload["pr"])]
        mismatch = None
        if "approval" in payload:
            branch = subprocess.run(["git", "-C", payload["repo"], "branch", "--show-current"], text=True, capture_output=True)
            current = branch.stdout.strip() if branch.returncode == 0 and branch.stdout.strip() else None
            mismatch = approval_mismatch(payload["approval"], action, payload.get("pr"), current, datetime.now(timezone.utc))
            if not mismatch:
                command.append("--approved")
        code, operation = normalize_internal_operation(*read_json(command))
    finally:
        if paths_file:
            Path(paths_file).unlink(missing_ok=True)
    status_name = operation.get("status")
    waiting = status_name == "waiting_for_human"
    completed = is_completed_result(action, status_name, code)
    status = "completed" if completed else ("waiting_for_human" if waiting else "failed")
    gate_state = "allowed" if completed else ("waiting_for_human" if waiting else "denied")
    workspace = {
        "base_branch": cfg.get("workspace", {}).get("base_branch"),
        "remote": cfg.get("git", {}).get("remote"),
        "draft": cfg.get("pull_request", {}).get("draft"),
        "branch": operation.get("branch"),
        "worktree": operation.get("worktree"),
    }
    if completed:
        try:
            public_operation = map_completed_operation(action, operation, cfg)
        except (TypeError, ValueError):
            completed = False
            status = "failed"
            gate_state = "denied"
            operation = {"status": "failed", "reason": "invalid_internal_result"}
            status_name = "failed"
            public_operation = {}
    else:
        public_operation = {
            key: value for key, value in operation.items()
            if key not in {"status", "reason", "gate", "context", "exit_code", "stdout", "stderr", "detail"}
        }
    raw_reason = operation.get("reason") or status_name
    reason_aliases = {
        "forbidden": "permission_denied",
        "no_changes": "no_changes",
        "no_staged_changes": "no_changes",
        "verification_failed": "verification_failed",
        "merge_partial": "merge_partial",
        "merge_failed": "merge_failed",
        "conflicts": "conflicts",
        "merged_cleanup_failed": "cleanup_failed",
        "cleanup_failed": "cleanup_failed",
    }
    # 状態名が公開語彙へ写るときは、内部の詳細な理由より状態名を優先する（詳細は detail で返す）。
    public_reason = reason_aliases.get(status_name) or reason_aliases.get(raw_reason, raw_reason)
    if status == "failed" and public_reason not in PUBLIC_REASONS:
        public_reason = "error"
    result = {
        "contract": CONTRACT, "version": 1, "action": action,
        "status": status, "gate_state": gate_state,
        "operation_result": public_operation, "workspace": workspace,
        "reason": "" if status != "failed" else public_reason,
    }
    if waiting:
        result["approval_target"] = operation.get("context", {}) | {"gate": operation.get("gate")}
        if mismatch:
            result["approval_target"]["outside_approval"] = mismatch
    if status == "failed" and operation.get("detail") is not None:
        result["detail"] = operation["detail"]
    elif status == "failed" and raw_reason not in {public_reason, status_name}:
        result["detail"] = {"reason": raw_reason}
    result_code = 0 if completed else 3
    emit(result, result_code)


if __name__ == "__main__":
    main()
