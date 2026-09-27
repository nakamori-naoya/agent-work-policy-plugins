#!/usr/bin/env bash
# migration を最初から当て直し、schema の差分が無いことを確かめる。
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f deploy/dev/compose.yml run --rm migrate reset
docker compose -f deploy/dev/compose.yml run --rm migrate diff --exit-code
