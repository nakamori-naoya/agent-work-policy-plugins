#!/usr/bin/env bash
# playbook を解決して YAML で stdout へ出す。
#
#   resolve.sh [repo_root] [--explain] [--scope=<dir>] [--bindings=<lock|none>] [--input=<abs>]
#
# --input を受けたとき、scripts/validate-input.sh があれば
#   bash scripts/validate-input.sh <正規化済みの入力path>
# を実行する。非0なら [error:input-schema] で exit 2 する。
#
# --bindings は**入口の段取りだけが作る**。渡されなければ自分が入口なので、
# 3層（personal / project / scope）から dependencies.yml を1つ選び、run用のlockを作る。
# 渡されたら層探索をせず、そのlockの実体を使う（content_hash が食い違えば binding-drift）。
# --input は呼び出し元が渡す契約入力。検証して解決済みYAMLの .input へ載せる。
#
# --scope が無ければ、自分の名前から scope を決める（この段取りを入口とする実行の scope）。
# あれば、それは**入口の段取りが決めた scope** なので、作り直さずそのまま下段へ流す。
# だから scope 設定は、その入口を通る実行の中でしか効かない。
#
# **正本は shared/playbook/resolve.sh。** 各 playbook はその複製を自分の scripts/ に持つ。
# インストール時にコピーされるのは playbook のディレクトリだけなので、
# リポジトリ root の共有ファイルは配布先へ届かない。lint が複製の一致を検査する。
#
# playbook が持つのは**何を、どの順で呼ぶか**だけである。
# 各工程が中で何をするかは、その skill / script の領分で、ここは知らない。
# 順番も呼ぶ相手も同梱 playbook.yml に書く。利用者は
# <repo>/.harness-plugins/<name>.config.yml で上書きできる。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

repo=""; explain=0; scope_root=""; scope_given=0; bindings_arg=""; bindings_given=0; input_arg=""
for arg in "$@"; do
  case "$arg" in
    --explain) explain=1 ;;
    --scope=*) scope_root="${arg#--scope=}"; scope_given=1 ;;
    --bindings=*) bindings_arg="${arg#--bindings=}"; bindings_given=1 ;;
    --input=*) input_arg="${arg#--input=}" ;;
    *) [ -n "$repo" ] || repo="$arg" ;;
  esac
done
[ -n "$repo" ] || repo="$PWD"
[ -d "$repo" ] || { echo "[error] repo directory が無い: $repo" >&2; exit 2; }
root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || (cd "$repo" && pwd)) || exit 2
[ -n "$root" ] || { echo "[error] repo root を解決できない: $repo" >&2; exit 2; }

command -v yq >/dev/null 2>&1 || { echo "[error] yq が要る" >&2; exit 2; }

base="$PB_ROOT/playbook.yml"
[ -f "$base" ] || { echo "[error] playbook.yml が無い: ${base}" >&2; exit 2; }
bundled=$(yq -o=json -I=0 '.' "$base") || { echo "[error] 同梱の playbook.yml が壊れている" >&2; exit 2; }
name=$(jq -r '.name' <<<"$bundled")
personal="${XDG_CONFIG_HOME:-$HOME/.config}/harness-plugins/${name}.config.yml"
override="$root/.harness-plugins/${name}.config.yml"
# scope は入口の段取りが決める。入れ子で呼ばれた側は、渡されたものを作り直さない。
# 作り直すと「digest 経由のとき」の設定が、途中の write-doc の scope にすり替わる。
[ -n "$scope_root" ] || scope_root="$root/.harness-plugins/scopes/${name}"
# 置いたのに効かない事故を防ぐ。scope directory があるなら、中身は
# <プラグイン名>.config.yml だけに限る。綴り違いは黙って無視せず落とす。
if [ -d "$scope_root" ]; then
  for f in "$scope_root"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      *.config.yml|dependencies.yml) ;;
      *) echo "[error] scope設定の名前が不正: ${f}（<プラグイン名>.config.yml または dependencies.yml のみ）" >&2; exit 2 ;;
    esac
  done
fi
selected="$base"; source="bundled"
[ ! -f "$personal" ] || { selected="$personal"; source="personal"; }
[ ! -f "$override" ] || { selected="$override"; source="project"; }
# 入れ子で呼ばれたときだけ、入口が決めた scope の設定を最優先で選ぶ。
# 入口の段取り自身は通常の層で解決する（自分の scope に自分を置くのは自己参照になる）。
scope_cfg=""
[ "$scope_given" = "0" ] || scope_cfg="$scope_root/${name}.config.yml"
[ -z "$scope_cfg" ] || [ ! -f "$scope_cfg" ] || { selected="$scope_cfg"; source="scope"; }
pb=$(yq -o=json -I=0 '.' "$selected" 2>/dev/null) || { echo "[error] YAML が壊れている: $selected" >&2; exit 2; }
missing=$(jq -rn --argjson req "$bundled" --argjson got "$pb" 'def required_paths($v;$p): if ($v|type)=="object" then [$v|to_entries[]|required_paths(.value;$p+[.key])[]] else [$p] end;[$req|required_paths(.;[])[] as $p|select($got|getpath($p)==null)|$p|map(tostring)|join(".")]|join(", ")')
[ -z "$missing" ] || { echo "[error] 選択したplaybook設定が自己完結していない: ${selected}（不足: ${missing}）" >&2; exit 2; }
jq -e --arg expected "$name" --argjson bundled "$bundled" '
  .version==2 and .name==$expected and (.description|type=="string" and length>0) and
  (.instructions|type=="object" and all(.[]; type=="object" and (.directive|type=="string" and length>0))) and
  (.requires | type=="array" and length>0 and
    all(.[];
      type=="object" and
      ((keys|sort)==["marketplace","plugin"]) and
      (.plugin|type=="string" and test("^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$")) and
      (.marketplace|type=="string" and test("^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$"))) and
    ((map(.plugin)|length)==(map(.plugin)|unique|length))) and
  (.requires==$bundled.requires) and
  (.steps|type=="array" and length>0 and all(.[];
    type=="object" and (.id|type=="string" and test("^[A-Za-z0-9._-]+$")) and
    (.purpose|type=="string" and length>0) and
    ((.needs // [])|type=="array" and all(.[]; type=="string" and test("^[A-Za-z0-9._-]+$"))) and
    ((.provides // [])|type=="array" and all(.[]; type=="string" and test("^[A-Za-z0-9._-]+$"))) and
    ((.input // {})|type=="object") and (has("actions")|not) and
    ([.skill,.script,.playbook]|map(select(.!=null))|all(.[]; type=="string" and length>0)))) and
  ((keys - ($bundled|keys))|length==0)
' >/dev/null <<<"$pb" || { echo "[error] playbookのschema、name、未知キーのいずれかが不正: $selected" >&2; exit 2; }

# **同梱 playbook.yml に無いキーは、どの深さにあっても受け取らない。**
# 名前を個別に覚えることなく、廃止したキーも綴り違いもここで落ちる。
# steps などの配列の中身は利用者が並べるものなので、添字を含む経路は対象外にする。
deep_unknown=$(jq -rn --argjson req "$bundled" --argjson got "$pb" '
  [ $got | paths ]
  | map(select(all(.[]; type=="string")))
  | map(. as $p | select($req | getpath($p) == null))
  | map(join("."))
  | join(", ")')
[ -z "$deep_unknown" ] || { echo "[error] 同梱 playbook.yml に無い設定: $deep_unknown" >&2; exit 2; }

# 共通resolverは個別playbookのキーを知らない。各配布物が持つvalidatorへ委譲する。
# **ただし走らせるのは、依存解決と汎用の依存規則検査（--check-steps）を通した後である。**
# 固有validatorを先に走らせると、`skill: grill` のような規則違反が
# 配布物ごとの文言で落ち、汎用の [error:external-dependency-*] に到達しない。
# 規則は全 repository で同じ診断が出て初めて機械で強制できるので、汎用が先に立つ。
# 存在検査だけはここで済ませる（無い配布物を依存解決まで進めても得が無い）。
validator="$PB_ROOT/scripts/validate-config.sh"
[ -x "$validator" ] || { echo "[error] playbook固有validatorが無い: $validator" >&2; exit 2; }

n=$(jq '.steps | length' <<<"$pb")
[ "$n" -gt 0 ] || { echo "[error] steps が空: ${name}" >&2; exit 2; }
seen=""; i=0
while [ "$i" -lt "$n" ]; do
  id=$(jq -r --argjson i "$i" '.steps[$i].id // ""' <<<"$pb")
  [ -n "$id" ] || { echo "[error] steps[${i}] に id が無い" >&2; exit 2; }
  case " $seen " in *" $id "*) echo "[error] id が重複している: ${id}" >&2; exit 2 ;; esac
  seen="$seen $id"
  kinds=$(jq -r --argjson i "$i" '[.steps[$i] | (.skill//empty), (.script//empty), (.playbook//empty)] | length' <<<"$pb")
  [ "$kinds" = "1" ] || { echo "[error] steps[${i}] (${id}) は skill / script / playbook のどれか1つだけを指すこと" >&2; exit 2; }
  # needs が、前の工程の provides で満たされているか。順番の正しさを機械で見る。
  for nd in $(jq -r --argjson i "$i" '.steps[$i].needs[]?' <<<"$pb"); do
    ok=$(jq -r --argjson i "$i" --arg nd "$nd" '[.steps[:$i][] | .provides[]?] | index($nd) != null' <<<"$pb")
    [ "$ok" = "true" ] || { echo "[error] steps[${i}] (${id}) の needs「${nd}」を、前の工程が provides していない" >&2; exit 2; }
  done
  for nd in $(jq -r --argjson i "$i" '.steps[$i].conditional_needs[]?.needs[]?' <<<"$pb"); do
    ok=$(jq -r --argjson i "$i" --arg nd "$nd" '[.steps[:$i][] | .provides[]?] | index($nd) != null' <<<"$pb")
    [ "$ok" = "true" ] || { echo "[error] steps[${i}] (${id}) の conditional_needs「${nd}」を、前の工程が provides していない" >&2; exit 2; }
  done
  i=$((i + 1))
done

dependency_resolver="$PB_ROOT/scripts/resolve-dependency.py"
[ -f "$dependency_resolver" ] || { echo "[error:dependency-invalid] resolver-missing=$dependency_resolver" >&2; exit 2; }

# 束縛lock。入口だけが作り、子は渡されたものを使う。none は束縛機構そのものを止める試験用指定。
bindings_lock=""
if [ "$bindings_given" = "1" ]; then
  bindings_lock="$bindings_arg"
  [ -n "$bindings_lock" ] || { echo "[error:binding-file-missing] path=" >&2; exit 2; }
else
  lock_dir="${HARNESS_PLUGIN_RUN_DIR:-}"
  if [ -z "$lock_dir" ] || [ ! -d "$lock_dir" ]; then
    lock_dir=$(mktemp -d "${TMPDIR:-/tmp}/harness-bindings-XXXXXX") || exit 2
  fi
  # lock の path は正規形でなければならない（祖先の symlink を許さない検査に掛かる）。
  lock_dir=$(cd "$lock_dir" && pwd -P) || exit 2
  bindings_lock=$(python3 "$dependency_resolver" --create-lock --entry "$name" \
    --repo-root "$root" --scope-root "$scope_root" --lock "$lock_dir/bindings.lock.yml") || exit 2
fi

deps='{}'
while IFS=$'\t' read -r dep market; do
  candidate=$(python3 "$dependency_resolver" --plugin-root "$PB_ROOT" \
    --plugin "$dep" --marketplace "$market" \
    --logical "$dep" --contract "${market}/${dep}" \
    --bindings "$bindings_lock") || exit 2
  deps=$(jq -c --arg k "$dep" --argjson v "$candidate" '.[$k]=$v' <<<"$deps") || exit 2
done < <(jq -r '.requires[] | [.plugin,.marketplace] | @tsv' <<<"$pb")

# 呼び出し元が渡した契約入力。共通検査（契約ID・版・能力・output_to）を通してから
# .input へ載せる。契約固有のschema（必須キー・未知キー）は共通resolverには書けないので、
# 配布物が scripts/validate-input.sh を持っていればそこへ委譲する（任意hook）。
input_json='null'
if [ -n "$input_arg" ]; then
  input_checked=$(python3 "$dependency_resolver" --check-input --plugin-root "$PB_ROOT" --input "$input_arg") || exit 2
  input_json=$(jq -c '.input' <<<"$input_checked") || exit 2
  input_path=$(jq -r '.path' <<<"$input_checked") || exit 2
  input_validator="$PB_ROOT/scripts/validate-input.sh"
  if [ -f "$input_validator" ] && [ ! -L "$input_validator" ]; then
    bash "$input_validator" "$input_path" >&2 || {
      echo "[error:input-schema] validator=${input_validator} input=${input_path}" >&2; exit 2; }
  fi
fi

bindings_file=""; bindings_layer="none"
if [ "$bindings_lock" != "none" ] && [ -f "$bindings_lock" ]; then
  bindings_file=$(jq -r '.bindings_file // ""' "$bindings_lock") || exit 2
  bindings_layer=$(jq -r '.bindings_layer // "none"' "$bindings_lock") || exit 2
fi

out=$(jq -cn --argjson pb "$pb" --argjson d "$deps" --arg root "$root" --arg pr "$PB_ROOT" \
  --arg selected "$selected" --arg source "$source" --arg personal "$personal" --arg project "$override" --arg scope "$scope_root" \
  --argjson input "$input_json" --arg ifile "${input_path:-}" \
  --arg lock "$bindings_lock" --arg bfile "$bindings_file" --arg blayer "$bindings_layer" \
  '{playbook:$pb, deps:$d, repo_root:$root, playbook_root:$pr,
    instructions:($pb.instructions // {}),
    resolution:{schema:1, personal_config:$personal, project_config:$project, scope_root:$scope, selected_config:$selected, config_layer:$source,
                bindings_lock:(if $lock=="" or $lock=="none" then null else $lock end),
                bindings_file:(if $bfile=="" then null else $bfile end), bindings_layer:$blayer,
                input_file:(if $ifile=="" then null else $ifile end)}}
   | if $input==null then . else .input=$input end')
printf '%s\n' "$out" | python3 "$dependency_resolver" --check-steps || exit 2

# 汎用規則を通ってから、配布物固有のschemaを検査する。
pb_file=$(mktemp "${TMPDIR:-/tmp}/${name}.playbook.XXXXXX") || exit 2
trap 'rm -f "$pb_file"' EXIT
printf '%s\n' "$pb" > "$pb_file"
bash "$validator" "$pb_file" || exit 2

# 静的に解けた steps[].input を input_resolved として併記する（参照形の input は残す）。
out=$(printf '%s\n' "$out" | python3 "$dependency_resolver" --resolve-inputs) || exit 2
if [ "$explain" = "1" ]; then
  printf '%s\n' "$out" | python3 "$dependency_resolver" --explain-config >&2 || exit 2
  echo "# 選択した設定: ${source} (${selected})" >&2
  if [ -d "$scope_root" ]; then
    echo "# scope: ${scope_root}" >&2
    for f in "$scope_root"/*.config.yml; do [ -f "$f" ] && echo "  $f" >&2; done
  else
    echo "# scope: ${scope_root}（無し。各工程は通常の設定で解決する）" >&2
  fi
fi
printf '%s\n' "$out" | yq -P
