#!/usr/bin/env bash
# 手元だけの git repository と、二つの worktree（wt-a、wt-b）を作業場所へ置く。Docker は起動しない。
set -euo pipefail
CASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.invalid GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.invalid
export GIT_AUTHOR_DATE='2026-09-20T10:00:00+09:00' GIT_COMMITTER_DATE='2026-09-20T10:00:00+09:00'
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p out
git init -q --bare -b main remote.git
cp -R "$CASE_DIR/materials/repo" repo
cd repo
git init -q -b main
git remote add origin ../remote.git
chmod +x tools/check-schema.sh
git add -A && git commit -q -m "feat: 注文の API を置く"
git push -q origin main
git worktree add -q -b feature/order-cancel ../wt-a main
git worktree add -q -b feature/order-export ../wt-b main
