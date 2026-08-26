#!/usr/bin/env bash
# skill の設定を解決して YAML で stdout へ出す。
#
#   resolve.sh [repo_root] [--explain] [--scope=<dir>] [--override=<path>=<value> ...]
#
# **正本は shared/skill/resolve.sh。** 各 skill はその複製を自分の scripts/ に持つ。
# インストールで運ばれるのは配布物のディレクトリだけなので、
# リポジトリ root の共有ファイルは配布先へ届かない。lint が複製の一致を検査する。
#
# **設定の解決手順は全 skill で同一である。** だからこのファイルに手順は無く、
# 手順そのものがこのファイルである。候補を上から順に調べ、最初に在った1ファイルだけを選ぶ。
#
#   1. <scope>/<name>.config.yml                     呼び出し元が --scope を渡したときだけ
#   2. <repo>/.harness-plugins/<name>.local.yml      その端末だけ（commitしない）
#   3. <repo>/.harness-plugins/<name>.config.yml     そのリポジトリ
#   4. ~/.config/harness-plugins/<name>.config.yml   その利用者
#   5. <plugin>/config/defaults.yml                  同梱既定
#
# **層はマージしない。** 選んだ1ファイルが必須キーを全部持たなければ止まる。
# 半端に埋まった設定で走ると、指定したはずのものが効かないまま結果だけ出る。
#
# **prompt層（--override）は、この5層とは別の、直交する上書きである。**
# 依頼のたびに変わるべき値（探索の高さ・手法など）は、5層のどこにも実値の既定を
# 置かない。defaults.yml の `prompt_parameters.<key>` に type/enum/required だけを
# 宣言し、値は依頼から `--override=<key>=<value>` として都度渡す。
# 宣言の無いpathへの上書きはできない。leafだけを差し替え、兄弟プロパティは
# 選択済み1ファイルの値をそのまま引き継ぐ（layerのマージ禁止とは別の話）。
# 上書きが無く、宣言側 default も無いキーは値が無いまま出力される。それをどう
# 扱うか（推定する・聞く・止める）は呼び出し側の SKILL.md の判断であり、
# ここでは強制しない。
#
# 解決したあと、固有の検査と出す形の組み立てだけを scripts/finalize.sh が受け持つ。
# finalize は merged / root / PLUGIN_ROOT / resolve_path を見て、out へ最終JSONを入れる。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v yq >/dev/null 2>&1 || { echo "[error] yq が要る（設定ファイルを読めない）" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "[error] jq が要る" >&2; exit 2; }

# プラグイン名は .claude-plugin/plugin.json の name を正本にする。basename には
# 依存しない。git checkout の配布物ではディレクトリ名と一致して見分けが付かないが、
# インストール済みキャッシュ（例: ~/.claude/plugins/cache/<marketplace>/<name>/<version>/）
# はバージョン番号ディレクトリを1段挟むため、そこでは basename が版番号を指してしまい、
# リポジトリ設定ファイルが見つからず黙って同梱既定へフォールバックする事故になる。
# manifest省略時（CONTRIBUTINGが許すケース）だけ、従来どおりディレクトリ名へ倒す。
manifest="$PLUGIN_ROOT/.claude-plugin/plugin.json"
name=""
if [ -f "$manifest" ]; then
  name=$(jq -er '.name // empty' "$manifest" 2>/dev/null) || name=""
fi
[ -n "$name" ] || name=$(basename "$PLUGIN_ROOT")

# --explain は位置に依存させない。第2引数のときしか効かないと、
# repo を省いて --explain だけ渡した利用者に何も出ない。
# overrides は改行区切りの文字列で持つ。空配列を set -u 下で展開する事故を避けるため、
# bash の配列は使わない。
repo=""; explain=0; scope_root=""; overrides=""
for arg in "$@"; do
  case "$arg" in
    --explain) explain=1 ;;
    # 呼び出し元が「この実行の設定はここから採れ」と指すためのdirectory。
    # skillは渡してきたのが段取りかどうかも、その名前も知らない。
    --scope=*) scope_root="${arg#--scope=}" ;;
    # prompt層の上書き。<dot.path>=<value> の形で複数回渡せる。
    --override=*) overrides="${overrides}${arg#--override=}
" ;;
    --*) echo "[error] 未知のoption: $arg" >&2; exit 2 ;;
    *) [ -z "$repo" ] || { echo "[error] repoは1つだけ指定する" >&2; exit 2; }; repo="$arg" ;;
  esac
done
repo="${repo:-$PWD}"
[ -d "$repo" ] || { echo "[error] repo directory が無い: $repo" >&2; exit 2; }
root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || (cd "$repo" && pwd)) || exit 2
[ -n "$root" ] || { echo "[error] repo root を解決できない: $repo" >&2; exit 2; }

defaults="$PLUGIN_ROOT/config/defaults.yml"
[ -f "$defaults" ] || { echo "[error] 同梱既定が無い: $defaults" >&2; exit 2; }
personal="${XDG_CONFIG_HOME:-$HOME/.config}/harness-plugins/${name}.config.yml"
project="$root/.harness-plugins/${name}.config.yml"
local_cfg="$root/.harness-plugins/${name}.local.yml"

selected="$defaults"; source="bundled"
[ ! -f "$personal" ] || { selected="$personal"; source="personal"; }
[ ! -f "$project" ] || { selected="$project"; source="project"; }
[ ! -f "$local_cfg" ] || { selected="$local_cfg"; source="local"; }
# 呼び出し元が scope を渡したときだけ、その1ファイルを最優先で選ぶ。
# **単体呼び出しでは --scope が渡らない。** だから scope 設定は、それを渡した
# 呼び出しの中でしか読まれない。他の経路へ漏れることが構造上ありえない。
scope_cfg=""
if [ -n "$scope_root" ]; then
  # 置いたのに効かない事故を防ぐ。scope directory があるなら、中身は
  # <プラグイン名>.config.yml だけに限る。綴り違いを黙って無視しない。
  if [ -d "$scope_root" ]; then
    for f in "$scope_root"/*; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        *.config.yml) ;;
        *) echo "[error] scope設定の名前が不正: ${f}（<プラグイン名>.config.yml のみ）" >&2; exit 2 ;;
      esac
    done
  fi
  scope_cfg="$scope_root/${name}.config.yml"
fi
[ -z "$scope_cfg" ] || [ ! -f "$scope_cfg" ] || { selected="$scope_cfg"; source="scope"; }

merged=$(yq -o=json -I=0 '.' "$selected" 2>/dev/null) \
  || { echo "[error] YAML が壊れている: $selected" >&2; exit 2; }
required=$(yq -o=json -I=0 '.' "$defaults") || exit 2
missing=$(jq -rn --argjson req "$required" --argjson got "$merged" '
  def required_paths($v;$p): if ($v|type)=="object" then [$v|to_entries[]|required_paths(.value;$p+[.key])[]] else [$p] end;
  [$req|required_paths(.;[])[] as $p|select($got|getpath($p)==null)|$p|map(tostring)|join(".")]|join(", ")')
[ -z "$missing" ] || { echo "[error] 選択した設定が自己完結していない: ${selected}（不足: ${missing}）" >&2; exit 2; }
# **同梱既定に無いキーは、どの深さにあっても受け取らない。**
# 廃止したキーも綴り違いも、名前を個別に覚えることなくここで落ちる。
# 配列の中身は利用者が並べるものなので、添字を含む経路は対象外にする。
unknown=$(jq -rn --argjson req "$required" --argjson got "$merged" '
  [ $got | paths ]
  | map(select(all(.[]; type=="string")))
  | map(. as $p | select($req | getpath($p) == null))
  | map(join("."))
  | join(", ")')
[ -z "$unknown" ] || { echo "[error] 同梱既定に無い設定: $unknown" >&2; exit 2; }

# --- prompt層: 依頼で明示された値を、検証済みの静的解決結果へ部分上書きする ---
# 指定できるpathは defaults.yml の prompt_parameters に宣言されたものだけ。
# 宣言に無いpath・enum外の値は、事故ではなく利用側の誤りとして止める。
sources='{}'
if [ -n "$overrides" ]; then
  while IFS= read -r ov; do
    [ -n "$ov" ] || continue
    path="${ov%%=*}"
    value="${ov#*=}"
    case "$path" in
      ''|*[!a-z0-9._-]*|.*|*.|*..*)
        echo "[error] --override のpathが不正: ${path}" >&2; exit 2 ;;
    esac
    spec=$(jq -c --arg p "$path" '($p | split(".")) as $s | getpath(["prompt_parameters"] + $s)' <<<"$required")
    [ "$spec" != "null" ] || {
      echo "[error] promptからの上書きが許可されていないpath: ${path}（defaults.ymlのprompt_parametersに宣言が無い）" >&2
      exit 2
    }
    enum=$(jq -c '.enum // empty' <<<"$spec")
    if [ -n "$enum" ]; then
      ok=$(jq -r --arg v "$value" '. as $e | ($e | index($v)) != null' <<<"$enum")
      [ "$ok" = "true" ] || {
        echo "[error] --override の値が許可値にない: ${path}=${value}（許可値: $(jq -r 'join(", ")' <<<"$enum")）" >&2
        exit 2
      }
    fi
    merged=$(jq -c --arg p "$path" --arg v "$value" '($p | split(".")) as $s | setpath($s; $v)' <<<"$merged")
    sources=$(jq -c --arg p "$path" '. + {($p): "prompt"}' <<<"$sources")
  done <<EOF
$overrides
EOF
fi
# $sources は動的値（prompt）だけをキーごとに持つ別変数のまま渡す。$merged へは
# 混ぜない。$merged の形を厳密検査する finalize.sh（keys の完全一致検査など）を
# 壊さないためで、静的解決の出所は既存の $source 変数がそのまま表す。
# 出所を出力へ含めたい finalize.sh は、$source / $sources を使って自分で組み立てる。

# 設定に書かれた相対pathはrepo rootから、~ はホームから解く。
resolve_path() {
  local p="$1"
  [ -n "$p" ] || { printf ''; return; }
  p="${p/#\~/$HOME}"
  case "$p" in /*) printf '%s' "$p" ;; *) printf '%s/%s' "$root" "$p" ;; esac
}

[ "$explain" = 0 ] || echo "# 選択した設定: $source ($selected)" >&2

# ここから先だけが skill ごとに違う。finalize は out へ最終JSONを入れる。
out="$merged"
finalize="$SCRIPT_DIR/finalize.sh"
[ -f "$finalize" ] || { echo "[error] finalize が無い: $finalize" >&2; exit 2; }
# shellcheck source=/dev/null
. "$finalize"

printf '%s\n' "$out" | yq -P
