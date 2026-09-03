#!/usr/bin/env bash
set -uo pipefail

root_license=${1:?root LICENSE path is required}
plugin_license=${2:?plugin LICENSE path is required}

[ -f "$root_license" ] &&
  [ ! -L "$root_license" ] &&
  [ -f "$plugin_license" ] &&
  [ ! -L "$plugin_license" ] &&
  cmp -s "$root_license" "$plugin_license"
