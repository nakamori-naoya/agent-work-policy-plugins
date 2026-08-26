#!/usr/bin/env python3
"""SKILL.mdの起動ボイラープレート（PLUGIN_ROOT確定・設定読込）を正本と同期・検査する。

正本は shared/skill-entry/{root-block,config-load,root-only}.md の3ファイル。
各SKILL.mdは対応する内容を

    <!-- BEGIN shared:skill-entry/<name> -->
    ...
    <!-- END shared:skill-entry/<name> -->

の境界マーカーで囲んで持つ。マーカー間の内容は正本とbyte一致する必要がある。
公開SKILL.mdは必ず (root-block と config-load の両方) か (root-only のみ) の
どちらか一方の組み合わせだけを持つ。

    --check   全SKILL.mdを検査する。ずれがあれば非0で終了する（lintから呼ぶ）。
    --write   正本の内容でマーカー内を上書きする（authoring・正本更新時に使う）。
"""
import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FRAGMENTS_DIR = REPO_ROOT / "shared" / "skill-entry"
FRAGMENT_NAMES = ["root-block", "config-load", "root-only"]

MARKER_RE = {
    name: re.compile(
        r"<!-- BEGIN shared:skill-entry/" + re.escape(name) + r" -->\n"
        r"(.*?)"
        r"<!-- END shared:skill-entry/" + re.escape(name) + r" -->\n",
        re.DOTALL,
    )
    for name in FRAGMENT_NAMES
}


def load_fragments():
    fragments = {}
    for name in FRAGMENT_NAMES:
        path = FRAGMENTS_DIR / f"{name}.md"
        if not path.is_file():
            print(f"[error] 正本が無い: {path}", file=sys.stderr)
            sys.exit(2)
        fragments[name] = path.read_text()
    return fragments


def find_skill_files():
    root_skills = REPO_ROOT.glob("plugins/*/*/*/SKILL.md")
    nested_skills = REPO_ROOT.glob("plugins/*/*/*/skills/*/SKILL.md")
    return sorted([*root_skills, *nested_skills])


def check(fragments):
    fail = False
    for skill_path in find_skill_files():
        rel = skill_path.relative_to(REPO_ROOT)
        text = skill_path.read_text()
        found = {}
        for name in FRAGMENT_NAMES:
            matches = MARKER_RE[name].findall(text)
            if len(matches) > 1:
                print(f"  NG: {rel} に shared:skill-entry/{name} が複数ある")
                fail = True
                continue
            if matches:
                found[name] = matches[0]

        has_configured = "root-block" in found or "config-load" in found
        has_root_only = "root-only" in found

        if has_configured and has_root_only:
            print(f"  NG: {rel} に configured と root-only が両方ある")
            fail = True
        elif has_configured:
            if not ("root-block" in found and "config-load" in found):
                print(f"  NG: {rel} は root-block と config-load の両方が必要（片方だけある）")
                fail = True
        elif has_root_only:
            pass
        else:
            print(f"  NG: {rel} に起動ボイラープレートのマーカーが無い")
            fail = True

        for name, content in found.items():
            if content != fragments[name]:
                print(f"  NG: {rel} の shared:skill-entry/{name} が正本とずれている")
                fail = True

    return not fail


def write(fragments):
    changed = 0
    for skill_path in find_skill_files():
        text = skill_path.read_text()
        new_text = text
        for name in FRAGMENT_NAMES:
            new_text = MARKER_RE[name].sub(
                lambda m, n=name: (
                    f"<!-- BEGIN shared:skill-entry/{n} -->\n"
                    f"{fragments[n]}"
                    f"<!-- END shared:skill-entry/{n} -->\n"
                ),
                new_text,
            )
        if new_text != text:
            skill_path.write_text(new_text)
            changed += 1
    print(f"[sync-skill-entry] {changed} 件を正本で上書きした")


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()

    fragments = load_fragments()
    skill_files = find_skill_files()
    if not skill_files:
        print("[error] 公開SKILL.mdが1件も見つからない", file=sys.stderr)
        sys.exit(2)

    if args.write:
        write(fragments)
        return

    if check(fragments):
        print(f"  ok（{len(skill_files)}件）")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
