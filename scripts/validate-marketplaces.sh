#!/usr/bin/env bash
set -uo pipefail

agents_marketplace=${1:?agents marketplace path is required}
claude_marketplace=${2:?Claude marketplace path is required}

jq -e --slurpfile claude "$claude_marketplace" '
  .plugins as $agents |
  ($claude[0].plugins) as $claude_plugins |
  ($agents | length) == ($claude_plugins | length) and
  all($agents[]; . as $agent |
    any($claude_plugins[];
      .name == $agent.name and
      .version == $agent.version and
      .source == $agent.source.path
    )
  )
' "$agents_marketplace" >/dev/null || exit 1

marketplace_root=$(cd "$(dirname "$agents_marketplace")/../.." && pwd) || exit 1
while IFS='|' read -r source name version; do
  case "$source" in
    ./plugins/skills/*) plugin_root="$marketplace_root/${source#./}" ;;
    *) exit 1 ;;
  esac
  case "/${source#./}/" in */../*|*/./*) exit 1 ;; esac
  current="$marketplace_root"
  old_ifs=$IFS
  IFS=/
  for component in ${source#./}; do
    current="$current/$component"
    [ ! -L "$current" ] || exit 1
  done
  IFS=$old_ifs
  [ -d "$plugin_root" ] && [ ! -L "$plugin_root" ] || exit 1
  [ -f "$plugin_root/SKILL.md" ] && [ ! -L "$plugin_root/SKILL.md" ] || exit 1
  case "$plugin_root" in "$marketplace_root"/plugins/skills/*) ;; *) exit 1 ;; esac
  jq -e --arg name "$name" --arg version "$version" '
    .name == $name and .version == $version and
    .skills == "./skills" and
    (.interface.capabilities | type == "array" and index("Skills") != null)
  ' "$plugin_root/.codex-plugin/plugin.json" >/dev/null || exit 1
  jq -e --arg name "$name" --arg version "$version" '
    .name == $name and .version == $version and .skills == "./skills"
  ' "$plugin_root/.claude-plugin/plugin.json" >/dev/null || exit 1
done < <(jq -r '.plugins[] | [.source.path,.name,.version] | join("|")' "$agents_marketplace")
