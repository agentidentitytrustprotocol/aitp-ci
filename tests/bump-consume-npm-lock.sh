#!/usr/bin/env bash
# Runs bump-consume.yml's "Verify platform packages in the lockfile" step, as
# written in the workflow, against lockfile fixtures for aitp 0.24.0 (queries
# the npm registry). race-and-npm10 is the lock aitp-ui-console's bump bot wrote
# in 4147f72 (aitp-ci#6); npm10 is a lock re-written by npm 10.
set -euo pipefail
cd "$(dirname "$0")/.."
step=$(yq '.jobs.bump.steps[] | select(.name == "Verify platform packages in the lockfile") | .run' .github/workflows/bump-consume.yml)
[ -n "$step" ] && [ "$step" != null ] || { echo "guard step not found"; exit 1; }

fail=0
# expect <fixture> <exit code> [text the output must contain]...
expect() {
  local name=$1 want=$2 out rc=0; shift 2
  out=$(cd "tests/fixtures/npm-lock/$name" && PKG=@agentidentitytrustprotocol/aitp T=0.24.0 bash -c "$step" 2>&1) || rc=$?
  local ok=1; [ "$rc" = "$want" ] || ok=0
  for s in "$@"; do grep -qF -- "$s" <<<"$out" || ok=0; done
  if [ "$ok" = 1 ]; then echo "ok   $name (exit $rc)"; else echo "FAIL $name (exit $rc, want $want)"; echo "$out" | sed 's/^/     /'; fail=1; fi
}

expect ok 0 'locked with all 6 platform packages'
expect nested 0 'locked with all 6 platform packages'
expect race-and-npm10 1 \
  'aitp-darwin-x64 is missing' \
  'aitp-linux-x64-musl is missing' \
  'aitp-linux-x64-gnu libc undefined, published ["glibc"]'
expect npm10 1 \
  'aitp-linux-arm64-musl libc undefined, published ["musl"]'
exit $fail
