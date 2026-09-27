#!/usr/bin/env bash
# 手元だけの git repository（remote は手元の bare repository だけ）と、PR の状態の記録を作業場所へ置く。
# commit の時刻と作者を固定し、同じ commit が毎回できるようにする。GitHub にはつながない。
set -euo pipefail
CASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.invalid GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.invalid
export GIT_AUTHOR_DATE='2026-09-20T10:00:00+09:00' GIT_COMMITTER_DATE='2026-09-20T10:00:00+09:00'
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p out
git init -q --bare -b main remote.git
git init -q -b main repo
cd repo
git remote add origin ../remote.git
mkdir -p receipt tests
cat > AGENTS.md <<'MD'
# receipt

レシートの明細を扱う小さなライブラリである。完了判定は `python3 -m unittest` が通ることとする。Git と GitHub の作業は agent-work-policy に従う。
MD
cat > receipt/__init__.py <<'PY'
MAX_LINES = 100


def add_line(lines, item):
    if len(lines) >= MAX_LINES:
        raise ValueError("明細は100行まで")
    return [*lines, item]
PY
cat > tests/__init__.py <<'PY'
PY
cat > tests/test_receipt.py <<'PY'
import unittest

from receipt import MAX_LINES, add_line


class AddLineTest(unittest.TestCase):
    def test_rejects_over_limit(self):
        with self.assertRaises(ValueError):
            add_line(["x"] * MAX_LINES, "y")
PY
git add -A && git commit -q -m "feat: レシートの明細を足す"
git push -q origin main
git checkout -q -b feature/receipt-limit
sed -i.bak 's/MAX_LINES = 100/MAX_LINES = 200/; s/100行/200行/' receipt/__init__.py && rm receipt/__init__.py.bak
git commit -q -am "feat: 明細の上限を200行にする"
git checkout -q main
export GIT_AUTHOR_DATE='2026-09-21T10:00:00+09:00' GIT_COMMITTER_DATE='2026-09-21T10:00:00+09:00'
printf '\n## 使い方\n\n`add_line` で明細を一行ずつ足す。\n' >> AGENTS.md
git commit -q -am "docs: 使い方を書く"
git push -q origin main
git checkout -q feature/receipt-limit
export GIT_AUTHOR_DATE='2026-09-22T10:00:00+09:00' GIT_COMMITTER_DATE='2026-09-22T10:00:00+09:00'
git merge -q --no-edit main
git push -q -u origin feature/receipt-limit
HEAD_SHA=$(git rev-parse HEAD)
BASE_SHA=$(git rev-parse main)
cd ..
sed "s/{{HEAD_SHA}}/$HEAD_SHA/g; s/{{BASE_SHA}}/$BASE_SHA/g" "$CASE_DIR/materials/pr-status.md" > pr-status.md
