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
#   aitp-ietf-draft — private, and branch protection on a private repo needs a
#     paid org plan.
#
# Prereqs: gh auth with admin:org. Org secrets (App id/key) are set separately.
# Usage:
#   ./standardize.sh [repo ...]          apply the standard (default: all repos)
#   ./standardize.sh --check [repo ...]  read-only: report drift from the
#                                        standard; exits 1 on any drift
# Any other flag is rejected (exit 2).
set -euo pipefail

ORG=agentidentitytrustprotocol
ALL_REPOS="aitp-control-plane aitp-playground aitp-verifier-py aitp-verifier-ts aitp-verifier-go aitp-ui-console aitp-website agentidentitytrustprotocol"

# Emits one required check-name per line for the given repo (non-zero if unknown).
checks_for() {
  case "$1" in
    aitp-control-plane)
      printf '%s\n' "Build, typecheck, lint, test" "Dependency audit (prod, high+)" "Docker build check (PR)" ;;
    aitp-playground)
      printf '%s\n' "Lint (ruff)" "Tests (Python 3.11)" "Tests (Python 3.13)" "Integration (agent subprocess e2e)" "docker-compose e2e" ;;
    aitp-verifier-py)
      printf '%s\n' "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)" \
        "declared floors install, pass, and carry no advisories" ;;
    aitp-verifier-ts)
      printf '%s\n' "spec pin + generated files" "tests (node 20)" "tests (node 22)" "tests (deno)" "conformance (aitp-conformance)" "mint (aitp-rs) -> verify" "build aitp-rs tools" \
        "package (pack, smoke test, publish dry run)" ;;
    aitp-verifier-go)
      printf '%s\n' "spec pin + generated files" "tests (go 1.26)" "tests (go 1.27)" "build aitp-rs tools" \
        "conformance (aitp-conformance)" "mint (aitp-rs) -> verify" ;;
    aitp-ui-console)
      printf '%s\n' "typecheck · lint · test · build" ;;
    aitp-website)
      printf '%s\n' "build" ;;
    agentidentitytrustprotocol)  # the spec/RFC repo
      printf '%s\n' "Validate Schemas, Examples, and Conformance Fixtures" \
        "Handoff scripts (shellcheck, syntax, read-only dry-run)" ;;
    *) return 1 ;;
  esac
}

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

check=0
repos=""
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "standardize.sh: unknown flag: $arg" >&2; usage >&2; exit 2 ;;
    *) repos="$repos $arg" ;;
  esac
done
[ -n "$repos" ] || repos="$ALL_REPOS"

# --check: compare live state with the standard; print each drift; no writes.
check_repo() {
  local repo=$1 want=$2 branch settings prot have drift=0
  branch=$(gh api "repos/$ORG/$repo" --jq .default_branch)
  settings=$(gh api "repos/$ORG/$repo" \
    --jq '"auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete-branch=\(.delete_branch_on_merge)"')
  if [ "$settings" != "auto-merge=true squash=true delete-branch=true" ]; then
    echo "  DRIFT settings: $settings"; drift=1
  fi
  if ! prot=$(gh api "repos/$ORG/$repo/branches/$branch/protection" 2>/dev/null); then
    echo "  DRIFT protection: none on $branch"; return 1
  fi
  have=$(printf '%s' "$prot" | jq -r '.required_status_checks.contexts // [] | .[]' | LC_ALL=C sort)
  if [ "$have" != "$(printf '%s\n' "$want" | LC_ALL=C sort)" ]; then
    echo "  DRIFT required checks:"
    diff <(printf '%s\n' "$want" | LC_ALL=C sort) <(printf '%s\n' "$have") \
      | sed -n 's/^< /    missing: /p; s/^> /    extra:   /p'
    drift=1
  fi
  if [ "$(printf '%s' "$prot" | jq -r '.required_status_checks.strict')" != true ]; then
    echo "  DRIFT strict: not true"; drift=1
  fi
  if [ "$(printf '%s' "$prot" | jq -r '.enforce_admins.enabled')" != false ]; then
    echo "  DRIFT enforce_admins: not false"; drift=1
  fi
  if [ "$(printf '%s' "$prot" | jq -r '.required_pull_request_reviews != null')" != false ]; then
    echo "  DRIFT required reviews: set"; drift=1
  fi
  [ "$drift" -eq 0 ] && echo "  ok: $settings strict=true checks=$(printf '%s\n' "$want" | wc -l | tr -d ' ')"
  return "$drift"
}

failed=0
for repo in $repos; do
  if ! lines=$(checks_for "$repo"); then
    echo "!! $repo: not in the standard set (excluded/unknown) — skipping"
    [ "$check" -eq 1 ] && failed=1
    continue
  fi

  if [ "$check" -eq 1 ]; then
    echo "== $repo (check) =="
    check_repo "$repo" "$lines" || failed=1
    continue
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
    || { echo "  (branch protection not applied — the API rejected it)"; failed=1; }
done

if [ "$check" -eq 1 ]; then
  [ "$failed" -eq 0 ] && echo "check: no drift." || echo "check: DRIFT found." >&2
else
  echo "done."
fi
exit "$failed"
