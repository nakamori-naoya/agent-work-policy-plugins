#!/usr/bin/env python3
"""Strict, resumable playbook state stored outside the target repository."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile


def die(message: str, code: int = 2) -> None:
    print(f"[error] {message}", file=sys.stderr)
    raise SystemExit(code)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def lock_entries(path: str | None, contracts: set) -> dict | None:
    """束縛lockのうち**自分のrequiresに対応する契約だけ**をidentityへ含める。

    lockは同じrunの入れ子で共有し、子が初めて解決した外部依存を追記する。
    lock全体をidentityへ入れると、子の正常な追記で親のhashが変わり、
    親の次の状態操作が「開始時から変わった」と拒否される。"""
    if not path:
        return None
    location = pathlib.Path(path)
    if location.is_symlink() or any(part.is_symlink() for part in location.parents):
        die("束縛lockのpathにsymlinkは使えない: " + path)
    try:
        data = json.loads(location.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        die(f"束縛lockを読めない: {path} ({exc})")
    entries = data.get("entries")
    if not isinstance(entries, dict):
        die("束縛lockのentriesが壊れている: " + path)
    return {
        contract: {key: entry.get(key) for key in ("marketplace", "plugin", "content_hash")}
        for contract, entry in sorted(entries.items()) if contract in contracts
    }


def load_config(path: str) -> tuple[dict, str]:
    try:
        raw = subprocess.run(
            ["yq", "-o=json", "-I=0", ".", path], check=True,
            text=True, capture_output=True,
        ).stdout
        config = json.loads(raw)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        die(f"解決済みplaybookを読めない: {path} ({exc})")
    if config.get("deps"):
        resolver = pathlib.Path(__file__).with_name("resolve-dependency.py")
        result = subprocess.run([sys.executable, str(resolver), "--check-steps"], input=json.dumps(config), text=True, capture_output=True)
        if result.returncode:
            die("依存実体の再検査に失敗: " + result.stderr.strip())
    playbook = config.get("playbook", config)
    identity = {
        "playbook": playbook,
        "deps": config.get("deps", {}),
        "repo_root": config.get("repo_root"),
        "bindings": lock_entries(
            config.get("resolution", {}).get("bindings_lock"),
            {dep.get("contract") for dep in (config.get("deps") or {}).values() if dep.get("contract")},
        ),
    }
    canonical = json.dumps(identity, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return playbook, hashlib.sha256(canonical.encode()).hexdigest()


def state_root() -> pathlib.Path:
    base = os.environ.get("XDG_STATE_HOME")
    if not base:
        base = str(pathlib.Path.home() / ".local" / "state")
    return pathlib.Path(base).expanduser().resolve() / "harness-plugins" / "playbooks"


def safe(value: str, label: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) or ".." in value:
        die(f"{label}に使えない文字がある: {value}")
    return value


def state_path(playbook: dict, run_id: str) -> pathlib.Path:
    root = state_root()
    path = root / safe(playbook["name"], "playbook名") / f"{safe(run_id, 'run-id')}.json"
    current = root.parent.parent
    for part in path.relative_to(current).parts:
        current /= part
        if current.is_symlink():
            die("状態pathの祖先またはfileにsymlinkは使えない: " + str(current))
    return path


def read_state(path: pathlib.Path) -> dict:
    try:
        state = json.loads(path.read_text())
        if not isinstance(state, dict) or state.get("version") != 2 or not isinstance(state.get("steps"), list) or not isinstance(state.get("artifacts"), dict):
            die("実行状態schemaが壊れている")
        if state.get("status") not in {"running", "failed", "completed"}:
            die("実行状態statusが壊れている")
        ids = []
        running = []
        for step in state["steps"]:
            if not isinstance(step, dict) or not isinstance(step.get("id"), str) or step.get("status") not in {"pending", "running", "failed", "completed", "skipped"} or type(step.get("attempts")) is not int:
                die("工程状態が壊れている")
            ids.append(step["id"])
            if step["status"] == "running":
                running.append(step["id"])
        if len(ids) != len(set(ids)) or running != ([state["current_step"]] if state.get("current_step") else []):
            die("工程状態の整合性が壊れている")
        return state
    except FileNotFoundError:
        die(f"実行状態が無い: {path}")
    except json.JSONDecodeError:
        die(f"実行状態が壊れている: {path}")



def validate_state(state: dict, playbook: dict) -> None:
    records = state["steps"]
    specs = playbook["steps"]
    if [s["id"] for s in records] != [s["id"] for s in specs]:
        die("状態の工程集合が設定と一致しない")
    statuses = [s["status"] for s in records]
    if state["status"] == "completed" and any(status not in {"completed", "skipped"} for status in statuses):
        die("完了状態と工程状態が一致しない")
    if state["status"] == "failed" and statuses.count("failed") != 1:
        die("失敗状態と工程状態が一致しない")
    if state["status"] == "running" and ("failed" in statuses or all(status in {"completed", "skipped"} for status in statuses)):
        die("実行状態と工程状態が一致しない")
    expected = set()
    incomplete = False
    for record, spec in zip(records, specs):
        if record["status"] == "completed":
            if incomplete or record["attempts"] < 1:
                die("工程の完了順序が壊れている")
            expected.update(spec.get("provides", []))
        elif record["status"] == "skipped":
            # 条件付き工程だけを飛ばせる。飛ばした工程の成果物は無い。
            if incomplete or spec.get("when") is None:
                die("条件の無い工程が飛ばされている")
        else:
            if incomplete and record["status"] != "pending":
                die("後続工程が先に開始されている")
            incomplete = True
    if set(state["artifacts"]) != expected or any(not isinstance(v, str) or not v for v in state["artifacts"].values()):
        die("完了工程と成果物集合が一致しない")

def write_state(path: pathlib.Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    state["updated_at"] = now()
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(state, out, ensure_ascii=False, indent=2)
            out.write("\n")
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def checked(args: argparse.Namespace) -> tuple[dict, str, pathlib.Path, dict]:
    playbook, digest = load_config(args.config)
    path = state_path(playbook, args.run_id)
    state = read_state(path)
    validate_state(state, playbook)
    if state.get("config_hash") != digest:
        die("playbook設定または依存identityが開始時から変わったため再開できない")
    if args.repo and state.get("repo_root") != str(pathlib.Path(args.repo).resolve()):
        die("対象repositoryが開始時と異なる")
    if [step["id"] for step in state["steps"]] != [step["id"] for step in playbook["steps"]]:
        die("工程状態と設定が一致しない")
    return playbook, digest, path, state


def command_init(args: argparse.Namespace) -> None:
    playbook, digest = load_config(args.config)
    path = state_path(playbook, args.run_id)
    if path.exists():
        state = read_state(path)
        validate_state(state, playbook)
        if state.get("config_hash") != digest:
            die("同じrun-idのplaybook設定または依存identityが変わっている")
        if state.get("repo_root") != str(pathlib.Path(args.repo or os.getcwd()).resolve()):
            die("同じrun-idは別repositoryで再利用できない")
        status = "needs_retry" if state["status"] == "failed" else ("completed" if state["status"] == "completed" else "resumed")
        print(json.dumps({"status": status, "state": str(path), "run_id": args.run_id}))
        return
    created = now()
    state = {
        "version": 2, "playbook": playbook["name"], "run_id": args.run_id,
        "config_hash": digest, "repo_root": str(pathlib.Path(args.repo or os.getcwd()).resolve()),
        "status": "running", "current_step": None, "artifacts": {},
        "created_at": created, "updated_at": created,
        "steps": [{"id": step["id"], "status": "pending", "attempts": 0,
                   "started_at": None, "completed_at": None, "error": None}
                  for step in playbook["steps"]],
    }
    write_state(path, state)
    print(json.dumps({"status": "initialized", "state": str(path), "run_id": args.run_id}))


def command_start(args: argparse.Namespace) -> None:
    playbook, _, path, state = checked(args)
    if state["status"] != "running" or state["current_step"] is not None:
        die("別の工程が実行中、またはplaybookが停止済み")
    pending = next((s for s in state["steps"] if s["status"] == "pending"), None)
    if not pending or pending["id"] != args.step:
        die(f"次に開始できる工程は {pending['id'] if pending else '無し'}")
    spec = next(s for s in playbook["steps"] if s["id"] == args.step)
    missing = [key for key in spec.get("needs", []) if key not in state["artifacts"]]
    if missing:
        die(f"開始条件を満たさない（不足: {', '.join(missing)}）")
    pending["status"] = "running"
    pending["attempts"] += 1
    pending["started_at"] = now()
    state["current_step"] = args.step
    write_state(path, state)
    print(json.dumps({"status": "running", "step": args.step, "attempt": pending["attempts"]}))


def provisions(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in values:
        if "=" not in item:
            die(f"--provideはkey=valueで渡す: {item}")
        key, value = item.split("=", 1)
        safe(key, "成果物名")
        if not value or key in result:
            die(f"成果物が空または重複: {key}")
        result[key] = value
    return result


def command_complete(args: argparse.Namespace) -> None:
    playbook, _, path, state = checked(args)
    if state["current_step"] != args.step:
        die(f"実行中の工程ではない: {args.step}")
    spec = next(s for s in playbook["steps"] if s["id"] == args.step)
    supplied = provisions(args.provide)
    expected = set(spec.get("provides", []))
    if set(supplied) != expected:
        die(f"完了成果物が一致しない（必要: {', '.join(sorted(expected))}）")
    for key in spec.get("file_artifacts", ["path"] if "path" in expected else []):
        artifact = pathlib.Path(supplied[key])
        if not artifact.is_absolute() or not artifact.is_file() or artifact.is_symlink():
            die(f"file成果物が実在する通常ファイルではない: {key}")
    record = next(s for s in state["steps"] if s["id"] == args.step)
    record["status"] = "completed"
    record["completed_at"] = now()
    state["artifacts"].update(supplied)
    state["current_step"] = None
    if all(s["status"] in {"completed", "skipped"} for s in state["steps"]):
        state["status"] = "completed"
    write_state(path, state)
    print(json.dumps({"status": record["status"], "step": args.step, "playbook_status": state["status"]}))


def command_skip(args: argparse.Namespace) -> None:
    playbook, _, path, state = checked(args)
    if state["status"] != "running" or state["current_step"] is not None:
        die("別の工程が実行中、またはplaybookが停止済み")
    pending = next((s for s in state["steps"] if s["status"] == "pending"), None)
    if not pending or pending["id"] != args.step:
        die(f"次に開始できる工程は {pending['id'] if pending else '無し'}")
    spec = next(s for s in playbook["steps"] if s["id"] == args.step)
    if spec.get("when") is None:
        die(f"条件（when）の無い工程は飛ばせない: {args.step}")
    pending["status"] = "skipped"
    pending["completed_at"] = now()
    pending["error"] = args.reason
    if all(s["status"] in {"completed", "skipped"} for s in state["steps"]):
        state["status"] = "completed"
    write_state(path, state)
    print(json.dumps({"status": "skipped", "step": args.step, "when": spec["when"], "reason": args.reason}))


def command_fail(args: argparse.Namespace) -> None:
    _, _, path, state = checked(args)
    if state["current_step"] != args.step:
        die(f"実行中の工程ではない: {args.step}")
    record = next(s for s in state["steps"] if s["id"] == args.step)
    record["status"] = "failed"
    record["error"] = args.reason
    state["current_step"] = None
    state["status"] = "failed"
    write_state(path, state)
    print(json.dumps({"status": "failed", "step": args.step, "reason": args.reason}))



def command_retry(args: argparse.Namespace) -> None:
    _, _, path, state = checked(args)
    failed = [step for step in state["steps"] if step["status"] == "failed"]
    if state["status"] != "failed" or len(failed) != 1:
        die("retry対象の失敗工程が無い")
    failed[0]["status"] = "pending"
    failed[0]["error"] = None
    state["status"] = "running"
    write_state(path, state)
    print(json.dumps({"status": "retry_ready", "step": failed[0]["id"]}))

def command_status(args: argparse.Namespace) -> None:
    _, _, path, state = checked(args)
    print(json.dumps({"state": str(path), **state}, ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("init", "start", "complete", "fail", "skip", "status", "retry"))
    parser.add_argument("--config", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--repo")
    parser.add_argument("--step")
    parser.add_argument("--provide", action="append", default=[])
    parser.add_argument("--reason", default="unspecified")
    args = parser.parse_args()
    if args.command in {"start", "complete", "fail", "skip"} and not args.step:
        die(f"{args.command}には--stepが要る")
    playbook, _ = load_config(args.config)
    path = state_path(playbook, args.run_id)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = path.with_suffix(".lock")
    if path.is_symlink() or lock_path.is_symlink():
        die("状態pathにsymlinkは使えない")
    with open(lock_path, "a") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        globals()[f"command_{args.command}"](args)


if __name__ == "__main__":
    main()
