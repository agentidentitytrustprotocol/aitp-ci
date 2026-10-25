#!/usr/bin/env bash
# standardize.sh — apply the uniform delivery guardrails to every aitp-* repo.
#
# Idempotent. For each repo it: enables "Allow auto-merge", turns on squash +
# delete-branch-on-merge, and sets branch protection on the default branch with
# that repo's CI jobs as REQUIRED status checks (so auto-merge has something to
# wait on). Required-check names are per-repo (they must match each repo's real
# check-run names exactly) — declared in checks_for() below, verified against
# actual check-runs so a required check can never hang a PR.
#
# Portable to macOS's stock bash 3.2 (no associative arrays).
#
# Excluded on purpose:
#   aitp-rs — already protected with its own (richer) config; do not clobber.
#
# aitp-website is PRIVATE; branch protection there needs a paid org plan. The
# script attempts it and continues gracefully if the API rejects it.
#
# Prereqs: gh auth with admin:org. Org secrets (App id/key) are set separately.
# Usage: ./standardize.sh [repo ...]   (default: all repos below)
set -euo pipefail

ORG=agentidentitytrustprotocol
ALL_REPOS="aitp-control-plane aitp-playground aitp-verifier-py aitp-verifier-ts aitp-ui-console aitp-website agentidentitytrustprotocol"

# Emits one required check-name per line for the given repo (non-zero if unknown).
checks_for() {
  case "$1" in
    aitp-control-plane)
      printf '%s\n' "Build, typecheck, lint, test" "Dependency audit (prod, high+)" "Docker build check (PR)" ;;
    aitp-playground)
      printf '%s\n' "Lint (ruff)" "Tests (Python 3.11)" "Tests (Python 3.13)" "Integration (agent subprocess e2e)" ;;
    aitp-verifier-py)
      printf '%s\n' "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" ;;
    aitp-verifier-ts)
      printf '%s\n' "spec pin + generated files" "tests (node 20)" "tests (node 22)" "tests (deno)" "conformance (aitp-conformance)" "mint (aitp-rs) -> verify" "build aitp-rs tools" ;;
    aitp-ui-console)
      printf '%s\n' "typecheck · lint · test · build" ;;
    aitp-website)
      printf '%s\n' "build" ;;
    agentidentitytrustprotocol)  # the spec/RFC repo
      printf '%s\n' "Validate Schemas, Examples, and Conformance Fixtures" ;;
    *) return 1 ;;
  esac
}

if [ "$#" -gt 0 ]; then repos="$*"; else repos="$ALL_REPOS"; fi

for repo in $repos; do
  if ! lines=$(checks_for "$repo"); then
    echo "!! $repo: not in the standard set (excluded/unknown) — skipping"; continue
  fi
  contexts_json=$(printf '%s' "$lines" | jq -R . | jq -sc .)
  branch=$(gh api "repos/$ORG/$repo" --jq .default_branch)
  echo "== $repo (@$branch) =="

  gh api -X PATCH "repos/$ORG/$repo" \
    -F allow_auto_merge=true -F allow_squash_merge=true -F delete_branch_on_merge=true \
    --jq '"  auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete-branch=\(.delete_branch_on_merge)"'

  jq -nc --argjson ctx "$contexts_json" '{
    required_status_checks: { strict: true, contexts: $ctx },
    enforce_admins: false,
    required_pull_request_reviews: null,
    restrictions: null
  }' | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - \
      --jq '"  required checks: \(.required_status_checks.contexts | join(", "))"' \
    || echo "  (branch protection not applied — private repo may need a paid plan; skipping)"
done
echo "done."
