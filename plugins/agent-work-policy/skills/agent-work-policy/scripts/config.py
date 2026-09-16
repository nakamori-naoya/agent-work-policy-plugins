#!/usr/bin/env python3
"""agent-work-policy のpolicy設定fileを検査して読む唯一の入口。呼び手はpathを選ばない。

  python3 scripts/config.py check --repo <repository_path>
  python3 scripts/config.py read --repo <repository_path>

設定fileは <repositoryのgit root>/.harness-plugins/agent-work-policy.config.yml に固定する（1層・fallback無し）。stdinは使わない。

check: schema検査だけ。exit 0、標準出力に {"status":"ok","config":"<絶対path>"}
read : schema検査後、exit 0、標準出力に {"config":"<絶対path>","values":{設定fileのtop-level keyと値をそのまま}}
失敗 : exit 2、標準出力に {"error":"<診断>","config":"<絶対path>"|null,"reason":"policy_missing"|"schema_violation"|"not_a_git_repository"}
  policy_missing        fileが無い（symlinkも無いものとして扱う）
  schema_violation      keyの過不足・型違い・許容外の値・yqで読めないfile（detailを error に含める）
  not_a_git_repository  --repo が git repository ではない（設定fileのpathを決められないので config は JSON の null）

schemaの正本は同じdirectoryの control.py（POLICY_SCHEMA / validate_policy）で、このtoolはそれを共有する。invoke.py も同じ検査を内部で行う。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import control  # noqa: E402  同じ入口のtool。POLICY_FILE と validate_policy だけを使う


class ConfigError(Exception):
    def __init__(self, reason: str, message: str, config: str | None = None):
        super().__init__(message)
        self.reason = reason
        self.config = config


def resolve(repo: str) -> Path:
    env = dict(os.environ, LC_ALL="C")
    try:
        result = subprocess.run(["git", "-C", repo, "rev-parse", "--show-toplevel"],
                                capture_output=True, text=True, timeout=10, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ConfigError("not_a_git_repository", f"git を実行できない: {exc}")
    if result.returncode or not result.stdout.strip():
        raise ConfigError("not_a_git_repository", f"--repo が git repository ではない: {repo}")
    return Path(result.stdout.strip()).resolve() / control.POLICY_FILE


def read(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ConfigError("policy_missing", f"policy設定fileが無い: {path}", str(path))
    try:
        result = subprocess.run(["yq", "-o=json", "-I=0", ".", str(path)], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ConfigError("schema_violation", f"policy設定を読めない: {path} ({exc})", str(path))
    if result.returncode:
        raise ConfigError("schema_violation", f"policy設定を読めない: {path} ({result.stderr.strip()})", str(path))
    try:
        cfg = json.loads(result.stdout)
    except ValueError as exc:
        raise ConfigError("schema_violation", f"policy設定を読めない: {path} ({exc})", str(path))
    original = control.emit

    def raise_schema_violation(payload, code=0):
        detail = {k: v for k, v in payload.items() if k not in ("error", "config")}
        message = payload.get("error", "policy設定がschemaに合わない")
        if detail:
            message = f"{message}: {json.dumps(detail, ensure_ascii=False)}"
        raise ConfigError("schema_violation", message, str(path))

    control.emit = raise_schema_violation
    try:
        control.validate_policy(cfg, str(path))
    except SystemExit as exc:
        raise ConfigError("schema_violation", f"schema検査が exit {exc.code} で終わった", str(path))
    finally:
        control.emit = original
    return cfg


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="config.py", description="agent-work-policy のpolicy設定fileを検査して読む")
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("check", "read"):
        sub.add_parser(action).add_argument("--repo", required=True, help="repository 配下の任意のpath（git rootを解決する）")
    args = parser.parse_args(argv)
    config_path = None
    try:
        path = resolve(args.repo)
        config_path = str(path)
        cfg = read(path)
    except ConfigError as exc:
        print(json.dumps({"error": str(exc), "config": exc.config if exc.config is not None else config_path, "reason": exc.reason}, ensure_ascii=False))
        return 2
    if args.action == "check":
        print(json.dumps({"status": "ok", "config": config_path}, ensure_ascii=False))
    else:
        print(json.dumps({"config": config_path, "values": cfg}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
