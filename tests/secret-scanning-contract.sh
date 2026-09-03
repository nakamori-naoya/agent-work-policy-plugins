#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/secret-scanning.yml"
FAIL=0

if [ "$(yq -r '.jobs.gitleaks.runs-on' "$WORKFLOW")" = ubuntu-24.04 ] && [ "$(yq -r '.jobs.trufflehog.runs-on' "$WORKFLOW")" = ubuntu-24.04 ]; then
  echo '  ok: secret scanning jobs use ubuntu-24.04'
else
  echo '  NG: secret scanning runner is not pinned to ubuntu-24.04' >&2
  FAIL=1
fi

trufflehog_run=$(yq -r '.jobs.trufflehog.steps[-1].run' "$WORKFLOW")
case "$trufflehog_run" in
  *'--github-actions --results=verified,unknown --fail --fail-on-scan-errors --no-update git file:///repo'*)
    echo '  ok: TruffleHog uses GitHub Actions output with enforced verified and unknown results' ;;
  *)
    echo '  NG: TruffleHog hardening flags are incomplete or out of order' >&2
    FAIL=1 ;;
esac

credential_uri=$(bash "$ROOT/tests/fixtures/fake-credential-uri.sh")
expected_uri=$(printf '%s%s%s' 'https://fixture-user:' 'fixture-password' '@example.invalid/private.git')
if [ "$credential_uri" = "$expected_uri" ]; then
  echo '  ok: fake credential URI fixture is assembled at runtime'
else
  echo '  NG: fake credential URI fixture is invalid' >&2
  FAIL=1
fi

exit "$FAIL"
