#!/usr/bin/env bash
set -euo pipefail

ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
exec python3 "$ROOT/scripts/validate-distribution.py" "$ROOT"
