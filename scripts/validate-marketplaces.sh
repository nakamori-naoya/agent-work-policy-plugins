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
' "$agents_marketplace" >/dev/null
