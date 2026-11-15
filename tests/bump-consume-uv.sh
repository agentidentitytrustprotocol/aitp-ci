#!/usr/bin/env bash
# Runs bump-consume.yml's "Resolve versions", "Apply bump" and "Open PR" step
# text, as written in the workflow, for ecosystem uv. Fixture: a pyproject.toml
# pinned to aitp-sdk>=0.24.0,<0.25 (aitp-playground before 733017b) with its
# uv.lock at 0.24.1. Before the fix, Apply only ran `uv lock --upgrade-package`,
# which never leaves the range, so 0.25.1 left the tree unchanged and the
# commit failed (aitp-playground runs 41353750612, 41348689651).
#
# `uv` is a shim that records its arguments. With a real uv on PATH, the
# out-of-range case also re-locks for real (queries PyPI) and checks uv.lock.
set -euo pipefail
cd "$(dirname "$0")/.."
WF=.github/workflows/bump-consume.yml
step() {
  local s; s=$(yq ".jobs.bump.steps[] | select(.name == \"$1\") | .run" "$WF")
  [ -n "$s" ] && [ "$s" != null ] || { echo "step '$1' not found" >&2; exit 1; }
  printf '%s' "$s"
}
RESOLVE=$(step 'Resolve versions')
APPLY=$(step 'Apply bump (manifest + lockfile)')
OPENPR=$(step 'Open PR + arm auto-merge')
FIX=$PWD/tests/fixtures/uv/out-of-range
REAL_UV=$(command -v uv || true)

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Fake HOME: the Apply step prepends $HOME/.local/bin to PATH, so the uv shim
# lives there; `curl` (the uv installer download) is a no-op.
mkdir -p "$TMP/home/.local/bin" "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/curl"
cat > "$TMP/home/.local/bin/uv" <<EOF
#!/bin/sh
echo "\$*" >> "\$UV_LOG"
if [ -n "\${USE_REAL_UV:-}" ]; then exec "$REAL_UV" "\$@"; fi
EOF
chmod +x "$TMP/bin/curl" "$TMP/home/.local/bin/uv"

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; printf '     %s\n' "$@"; fail=1; }
fresh() { rm -rf "$TMP/w"; mkdir "$TMP/w"; cp "$FIX/pyproject.toml" "$FIX/uv.lock" "$TMP/w/"; }

# --- Resolve versions -------------------------------------------------------
# resolve <name> <event version> <expected key=value>...
resolve() {
  local name=$1 ev=$2 out; shift 2
  fresh; : > "$TMP/out"
  out=$(cd "$TMP/w" && ECO=uv PKG=aitp-sdk MANUAL='' EVENT="$ev" GITHUB_OUTPUT="$TMP/out" bash -c "$RESOLVE" 2>&1) \
    || { bad "resolve $name" "exit $?" "$out"; return; }
  local miss=()
  for kv in "$@"; do grep -qxF -- "$kv" "$TMP/out" || miss+=("missing $kv"); done
  if [ ${#miss[@]} = 0 ]; then ok "resolve $name"; else bad "resolve $name" "${miss[@]}" "$(cat "$TMP/out")"; fi
}
resolve 'rc tag -> PEP 440'      1.0.0-rc.1   target=1.0.0rc1 branch=deps/aitp-1.0.0rc1 current=0.24.1 changed=true breaking=true
resolve 'v-prefixed rc tag'      v1.0.0-rc.1  target=1.0.0rc1
resolve 'already PEP 440'        1.0.0rc1     target=1.0.0rc1
resolve 'alpha'                  1.0.0-alpha.2 target=1.0.0a2
resolve 'beta'                   1.0.0-beta.3 target=1.0.0b3
resolve 'stable unchanged'       0.25.10      target=0.25.10 breaking=true
resolve 'already at (v-prefix)'  v0.24.1      changed=false
resolve 'in-range patch'         0.24.2       changed=true breaking=false

# --- Apply bump -------------------------------------------------------------
# apply <name> <T> <expected requirement line> [real]
apply() {
  local name=$1 t=$2 want=$3 real=${4:-} out rc=0
  : > "$TMP/uv.log"
  out=$(cd "$TMP/w" && HOME="$TMP/home" PATH="$TMP/bin:$PATH" UV_LOG="$TMP/uv.log" USE_REAL_UV="$real" \
        ECO=uv PKG=aitp-sdk T="$t" bash -c "$APPLY" 2>&1) || rc=$?
  local errs=()
  [ "$rc" = 0 ] || errs+=("exit $rc" "$out")
  grep -qF -- "$want" "$TMP/w/pyproject.toml" || errs+=("pyproject lacks $want")
  # Only the requirement line changes; the comments that name the package stay.
  local changed; changed=$(diff "$TMP/before" "$TMP/w/pyproject.toml" | grep -c '^[<>]' || true)
  [ "$changed" = 2 ] || errs+=("expected exactly one changed line, diff has $changed")
  grep -qxF -- "lock --upgrade-package aitp-sdk==$t" "$TMP/uv.log" || errs+=("uv called as: $(cat "$TMP/uv.log")")
  if [ ${#errs[@]} = 0 ]; then ok "apply $name"; else bad "apply $name" "${errs[@]}"; fi
}

# Out-of-range minor: old <0.25 range, new 0.25.1 (the failed runs).
fresh; cp "$TMP/w/pyproject.toml" "$TMP/before"
if [ -n "$REAL_UV" ]; then
  apply 'out-of-range 0.24.1 -> 0.25.1 (real uv lock)' 0.25.1 '"aitp-sdk>=0.25.1,<0.26",' 1
  v=$(awk '$0=="name = \"aitp-sdk\""{f=1} f&&/^version = /{print;exit}' "$TMP/w/uv.lock")
  if [ "$v" = 'version = "0.25.1"' ]; then ok 'uv.lock moved to 0.25.1'; else bad 'uv.lock moved to 0.25.1' "got: $v"; fi
  if grep -qF 'specifier = ">=0.25.1,<0.26"' "$TMP/w/uv.lock"; then ok 'uv.lock records the new range'; else bad 'uv.lock records the new range'; fi
else
  echo "skip real uv lock (no uv on PATH)"
  apply 'out-of-range 0.24.1 -> 0.25.1' 0.25.1 '"aitp-sdk>=0.25.1,<0.26",'
fi

# In-range patch: from the 0.25.1 pin, 0.25.2 only raises the floor.
fresh; sed -i.bak 's/"aitp-sdk>=0.24.0,<0.25"/"aitp-sdk>=0.25.1,<0.26"/' "$TMP/w/pyproject.toml"
cp "$TMP/w/pyproject.toml" "$TMP/before"
apply 'in-range 0.25.1 -> 0.25.2' 0.25.2 '"aitp-sdk>=0.25.2,<0.26",'

# Pre-release across a major: the PEP 440 form, next-major upper bound.
fresh; cp "$TMP/w/pyproject.toml" "$TMP/before"
apply 'pre-release 1.0.0rc1' 1.0.0rc1 '"aitp-sdk>=1.0.0rc1,<2",'

# Extras survive.
fresh; sed -i.bak 's/"aitp-sdk>=0.24.0,<0.25"/"aitp-sdk[experimental] >= 0.24.0, <0.25"/' "$TMP/w/pyproject.toml"
cp "$TMP/w/pyproject.toml" "$TMP/before"
apply 'extras kept' 0.25.1 '"aitp-sdk[experimental]>=0.25.1,<0.26",'

# No requirement to rewrite: fail loudly instead of locking an unchanged range.
fresh; sed -i.bak '/"aitp-sdk>=/d' "$TMP/w/pyproject.toml"
rc=0; out=$(cd "$TMP/w" && HOME="$TMP/home" PATH="$TMP/bin:$PATH" UV_LOG="$TMP/uv.log" ECO=uv PKG=aitp-sdk T=0.25.1 bash -c "$APPLY" 2>&1) || rc=$?
if [ "$rc" = 1 ] && grep -qF 'no "aitp-sdk<specifier>" requirement' <<<"$out"; then ok 'apply missing requirement fails'; else bad 'apply missing requirement fails' "exit $rc" "$out"; fi

# --- Open PR: a clean tree exits 0 without committing ------------------------
fresh; (cd "$TMP/w" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init)
rc=0; out=$(cd "$TMP/w" && GH_TOKEN=x BR=deps/aitp-0.24.1 CUR=0.24.1 T=0.24.1 BREAKING=false ALLOW_MAJOR=false bash -c "$OPENPR" 2>&1) || rc=$?
if [ "$rc" = 0 ] && grep -qF 'Nothing to commit' <<<"$out" && [ "$(cd "$TMP/w" && git rev-parse --abbrev-ref HEAD)" != deps/aitp-0.24.1 ]; then
  ok 'open-pr clean tree exits 0'
else bad 'open-pr clean tree exits 0' "exit $rc" "$out"; fi

exit $fail
