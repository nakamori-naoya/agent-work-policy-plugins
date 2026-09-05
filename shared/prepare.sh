#!/usr/bin/env bash
# skill / playbook 共通入口。配布物rootを検証し、解決済みYAMLの一時pathを返す。
#
#   prepare.sh --root-only
#   prepare.sh [repo] [--scope=<dir>] [--override=<path>=<value> ...]
#
# --scope は**呼び出し元の段取りだけが渡す**。単体で使うときは付かないので、
# scope設定はそれを渡した実行の中でしか読まれない。
# --override は依頼で明示されたprompt層の上書き。resolve.sh（skill側）へそのまま
# 転送するだけで、ここでは検証しない。playbook側のresolve.shはこの引数を知らず
# 無視するので、playbookへ渡しても害はない。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PLUGIN_ROOT/playbook.yml" ]; then
  kind=playbook
elif [ -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ] || [ -f "$PLUGIN_ROOT/.codex-plugin/plugin.json" ]; then
  kind=skill
else
  echo "[error] skill / playbook rootではない: $PLUGIN_ROOT" >&2
  exit 2
fi

USAGE="usage: prepare.sh --root-only | [repo] [--scope=<dir>] [--override=<path>=<value> ...]"
if [ "${1:-}" = "--root-only" ]; then
  [ "$#" -eq 1 ] || { echo "$USAGE" >&2; exit 2; }
  printf '%s\n' "$PLUGIN_ROOT"
  exit 0
fi

# --scope は**呼び出し元だけが渡す**。単体で使うときは付かないので、
# scope設定はそれを渡した呼び出しの中でしか読まれない。
# overrides は配列で持つ。空配列を set -u 下で展開すると bash 3.2 で
# unbound variable になるため、展開は必ず ${overrides[@]+"${overrides[@]}"} の形にする。
repo=""; scope_arg=""; overrides=()
for a in "$@"; do
  case "$a" in
    --scope=*) scope_arg="$a" ;;
    --override=*) overrides+=("$a") ;;
    -*) echo "$USAGE" >&2; exit 2 ;;
    *) [ -z "$repo" ] || { echo "$USAGE" >&2; exit 2; }; repo="$a" ;;
  esac
done
repo="${repo:-$PWD}"
[ -d "$repo" ] || { echo "[error] repo directoryが無い: $repo" >&2; exit 2; }
[ -x "$PLUGIN_ROOT/scripts/resolve.sh" ] || { echo "[error] resolverが無い: $PLUGIN_ROOT/scripts/resolve.sh" >&2; exit 2; }

exec python3 "$SCRIPT_DIR/run-config.py" create --root "$PLUGIN_ROOT" -- "$repo" --explain ${scope_arg:+"$scope_arg"} \
  ${overrides[@]+"${overrides[@]}"}
