#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke-workflow-sync.sh — offline test of the destructive step's real body.
#
# The data-safety guarantee is the reason this repository exists, so it is not
# asserted by duplicating the shell logic here: the script extracts the `run:`
# bodies of the "Sync artefacts to S3" and "Invalidate CloudFront cache" steps
# straight out of deploy-s3-cloudfront.yml and executes them against a stub
# `aws` binary. If someone drops the exclusion array from one of the passes,
# moves it before the cache-tier filters, removes `--size-only`, or removes the
# pass-2 exclusion mask that stops the no-cache downgrade, this test fails.
#
# Requires python3 + PyYAML to read the workflow. Both are mandatory: a test that
# exits 0 when its parser is missing is a test that silently never runs, so a
# missing dependency is an environment error (exit 2) here.
#
# Usage: tests/smoke-workflow-sync.sh
# Exit codes: 0 pass · 1 failure · 2 environment error
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/deploy-s3-cloudfront.yml"

[ -f "$WORKFLOW" ] || { echo "smoke-workflow-sync: cannot find ${WORKFLOW}" >&2; exit 2; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "smoke-workflow-sync: python3 is required to read the workflow." >&2
  exit 2
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "smoke-workflow-sync: python3 with PyYAML is required to read the workflow." >&2
  echo "  install it with: python3 -m pip install pyyaml" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
CALLS="${WORKDIR}/aws-calls.log"
FAKE_BIN="${WORKDIR}/bin"
mkdir -p "$FAKE_BIN" "${WORKDIR}/dist"
echo '<html></html>' > "${WORKDIR}/dist/index.html"
echo 'body{}' > "${WORKDIR}/dist/app.js"

cat > "${FAKE_BIN}/aws" <<'STUB'
#!/usr/bin/env bash
# One line per invocation so argument order can be asserted.
printf '%s\n' "$*" >> "${FAKE_AWS_LOG}"
exit 0
STUB
chmod +x "${FAKE_BIN}/aws"

# Extract a step's run: body into a file.
extract_step() { # extract_step <step-name> <out-file>
  python3 - "$1" "$2" <<'PY'
import sys, yaml
step_name, out_path = sys.argv[1], sys.argv[2]
with open(".github/workflows/deploy-s3-cloudfront.yml") as fh:
    doc = yaml.safe_load(fh)
for step in doc["jobs"]["deploy"]["steps"]:
    if step.get("name") == step_name:
        if "run" not in step:
            sys.exit(f"step '{step_name}' has no run: body")
        with open(out_path, "w") as out:
            out.write(step["run"])
        break
else:
    sys.exit(f"step '{step_name}' not found")
PY
}

cd "$REPO_ROOT" || exit 2
SYNC_STEP="${WORKDIR}/sync-step.sh"
INVALIDATE_STEP="${WORKDIR}/invalidate-step.sh"
extract_step "Sync artefacts to S3" "$SYNC_STEP" || exit 2
extract_step "Invalidate CloudFront cache" "$INVALIDATE_STEP" || exit 2

PASS=0
FAIL=0
check() {
  if [ "$2" -eq 0 ]; then
    printf '  ✅ %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}
contains() { grep -qF -- "$2" "$1"; }
missing()  { ! grep -qF -- "$2" "$1"; }

run_sync() { # run_sync <out-file> <sync_exclude_paths> <tiered> <immutable_excludes> <revalidate_includes>
  local out="$1" excludes="$2" tiered="$3" imm_excl="$4" rev_incl="$5"
  : > "$CALLS"
  FAKE_AWS_LOG="$CALLS" PATH="${FAKE_BIN}:${PATH}" \
  ARTIFACT_PATH="${WORKDIR}/dist" \
  TARGET_BUCKET="octo-site-prod" \
  SYNC_EXCLUDE_PATHS="$excludes" \
  TIERED_CACHE_CONTROL="$tiered" \
  IMMUTABLE_CACHE_CONTROL="public, max-age=31536000, immutable" \
  REVALIDATE_CACHE_CONTROL="no-cache, no-store, must-revalidate" \
  IMMUTABLE_EXCLUDE_PATTERNS="$imm_excl" \
  REVALIDATE_INCLUDE_PATTERNS="$rev_incl" \
    bash "$SYNC_STEP" > "$out" 2>&1
}

DEFAULT_IMM_EXCL=$'*.html\n*.xml\n*.webmanifest\nmanifest.json\nsw.js\nservice-worker.js'
DEFAULT_REV_INCL="$DEFAULT_IMM_EXCL"

# ── Case 1: guard active, tiered caching on ──────────────────────────────────
echo "case 1 — exclusions reach both passes, in last position"
OUT1="${WORKDIR}/case1.out"
run_sync "$OUT1" $'data/*\ntelemetry.json' "true" "$DEFAULT_IMM_EXCL" "$DEFAULT_REV_INCL"
check "step exits 0" "$?"

SYNC_CALLS=$(grep -c '^s3 sync ' "$CALLS")
check "exactly two sync passes ran (got ${SYNC_CALLS})" "$([ "$SYNC_CALLS" -eq 2 ] && echo 0 || echo 1)"

PASS1=$(grep '^s3 sync ' "$CALLS" | sed -n '1p')
PASS2=$(grep '^s3 sync ' "$CALLS" | sed -n '2p')

printf '%s\n' "$PASS1" | grep -qF -- '--exclude data/*'
check "pass 1 protects data/*" "$?"
printf '%s\n' "$PASS1" | grep -qF -- '--exclude telemetry.json'
check "pass 1 protects telemetry.json" "$?"
printf '%s\n' "$PASS2" | grep -qF -- '--exclude data/*'
check "pass 2 protects data/*" "$?"
printf '%s\n' "$PASS2" | grep -qF -- '--exclude telemetry.json'
check "pass 2 protects telemetry.json" "$?"

printf '%s\n' "$PASS1" | grep -qF -- '--delete'
check "pass 1 runs with --delete" "$?"
printf '%s\n' "$PASS2" | grep -qF -- '--delete'
check "pass 2 runs with --delete" "$?"

printf '%s\n' "$PASS1" | grep -qF -- '--cache-control public, max-age=31536000, immutable'
check "pass 1 uploads immutable assets" "$?"
printf '%s\n' "$PASS1" | grep -qF -- '--exclude *.html'
check "pass 1 hands entry points to pass 2" "$?"
printf '%s\n' "$PASS2" | grep -qF -- '--cache-control no-cache, no-store, must-revalidate'
check "pass 2 uploads revalidated entry points" "$?"
printf '%s\n' "$PASS2" | grep -qF -- '--include *.html'
check "pass 2 selects entry points" "$?"

# ── Finding 2.3: the silent Cache-Control downgrade ──────────────────────────
# `aws s3 sync` compares size *and* modification time by default. When a
# destination object's LastModified looks older than the artefact (clock skew,
# artefacts restored with original mtimes), pass 2 re-uploads it carrying the
# revalidate header — an immutable asset quietly becomes `no-cache`. `--size-only`
# removes the timestamp from the decision, and the explicit `--exclude '*'` mask
# removes every non-entry-point object from pass 2's source set altogether.
printf '%s\n' "$PASS1" | grep -qF -- '--size-only'
check "pass 1 compares on size only (no timestamp skew)" "$?"

printf '%s\n' "$PASS2" | grep -qF -- '--size-only'
check "pass 2 compares on size only (no timestamp skew)" "$?"

printf '%s\n' "$PASS2" | grep -qE -- '--exclude \*([[:space:]]|$)'
check "pass 2 masks everything before re-including entry points" "$?"

if printf '%s\n' "$PASS1" | grep -qE -- '--exclude \*([[:space:]]|$)'; then
  check "pass 1 has no blanket mask (it uploads every non-entry-point asset)" 1
else
  check "pass 1 has no blanket mask (it uploads every non-entry-point asset)" 0
fi

pos_mask=$(printf '%s\n' "$PASS2" | grep -bo -- '--exclude \*' | head -n1 | cut -d: -f1)
pos_inc=$(printf '%s\n' "$PASS2" | grep -bo -- '--include \*.html' | head -n1 | cut -d: -f1)
check "the mask precedes the include list in pass 2 (mask=${pos_mask:-?} include=${pos_inc:-?})" \
  "$([ -n "$pos_mask" ] && [ -n "$pos_inc" ] && [ "$pos_mask" -lt "$pos_inc" ] && echo 0 || echo 1)"

# Last-match-wins: the guard must be the final filter in each invocation.
pos_guard=$(printf '%s\n' "$PASS1" | grep -bo 'data/\*' | head -n1 | cut -d: -f1)
pos_tier=$(printf '%s\n' "$PASS1" | grep -bo '\*.html' | head -n1 | cut -d: -f1)
check "guard filter follows the tier filter in pass 1 (guard=${pos_guard:-?} tier=${pos_tier:-?})" \
  "$([ -n "$pos_guard" ] && [ -n "$pos_tier" ] && [ "$pos_guard" -gt "$pos_tier" ] && echo 0 || echo 1)"

pos_guard2=$(printf '%s\n' "$PASS2" | grep -bo 'data/\*' | head -n1 | cut -d: -f1)
pos_tier2=$(printf '%s\n' "$PASS2" | grep -bo '\*.html' | head -n1 | cut -d: -f1)
check "guard filter follows the tier filter in pass 2 (guard=${pos_guard2:-?} tier=${pos_tier2:-?})" \
  "$([ -n "$pos_guard2" ] && [ -n "$pos_tier2" ] && [ "$pos_guard2" -gt "$pos_tier2" ] && echo 0 || echo 1)"

contains "$OUT1" 'Data-safety guard active'
check "the run reports the guard as active" "$?"

# ── Case 2: guard absent — single-parameter regression check ─────────────────
echo "case 2 — no guard configured (warning, legacy single-pass filters unchanged)"
OUT2="${WORKDIR}/case2.out"
run_sync "$OUT2" "" "true" "$DEFAULT_IMM_EXCL" "$DEFAULT_REV_INCL"
check "step exits 0" "$?"

contains "$OUT2" '::warning title=No data-safety guard::'
check "empty guard raises a visible warning" "$?"

grep -q '^s3 sync ' "$CALLS" && grep -qF -- '--exclude *.html' "$CALLS"
check "cache tiers still applied without a guard" "$?"

# ── Case 3: tiered caching disabled ──────────────────────────────────────────
echo "case 3 — tiered_cache_control=false"
OUT3="${WORKDIR}/case3.out"
run_sync "$OUT3" $'data/*' "false" "$DEFAULT_IMM_EXCL" "$DEFAULT_REV_INCL"
check "step exits 0" "$?"

SYNC_CALLS3=$(grep -c '^s3 sync ' "$CALLS")
check "exactly one sync pass ran (got ${SYNC_CALLS3})" "$([ "$SYNC_CALLS3" -eq 1 ] && echo 0 || echo 1)"
missing "$CALLS" '--cache-control'
check "no Cache-Control override in the single-pass mode" "$?"
contains "$CALLS" '--exclude data/*'
check "the data-safety guard survives the single-pass mode" "$?"
contains "$CALLS" '--size-only'
check "the single pass still compares on size only" "$?"

# ── Case 4: a bare prefix must not fail open ─────────────────────────────────
# `data` is a literal string to fnmatch: it matches only the exact key "data" and
# would leave `data/telemetry.json` exposed to both the upload and the delete
# phase. The step normalises it to the subtree.
echo "case 4 — bare prefix guard is normalised"
OUT4="${WORKDIR}/case4.out"
run_sync "$OUT4" "data" "true" "$DEFAULT_IMM_EXCL" "$DEFAULT_REV_INCL"
check "step exits 0" "$?"

contains "$OUT4" 'Guard pattern normalised'
check "the normalisation is reported in the log" "$?"

P1=$(grep '^s3 sync ' "$CALLS" | sed -n '1p')
P2=$(grep '^s3 sync ' "$CALLS" | sed -n '2p')

printf '%s\n' "$P1" | grep -qE -- '--exclude data/\*([[:space:]]|$)'
check "pass 1 protects the data/ subtree" "$?"
printf '%s\n' "$P1" | grep -qE -- '--exclude data([[:space:]]|$)'
check "pass 1 also protects the bare key 'data'" "$?"
printf '%s\n' "$P2" | grep -qE -- '--exclude data/\*([[:space:]]|$)'
check "pass 2 protects the data/ subtree" "$?"
printf '%s\n' "$P2" | grep -qE -- '--exclude data([[:space:]]|$)'
check "pass 2 also protects the bare key 'data'" "$?"

# ── Case 5: CloudFront invalidation step ────────────────────────────────────
echo "case 5 — invalidation paths"
run_invalidate() { # run_invalidate <paths>
  : > "$CALLS"
  FAKE_AWS_LOG="$CALLS" PATH="${FAKE_BIN}:${PATH}" \
  DISTRIBUTION_ID="ABCD1234EFGH" \
  INVALIDATION_PATHS="$1" \
    bash "$INVALIDATE_STEP" > "${WORKDIR}/inv.out" 2>&1
}
run_invalidate "/*"
check "invalidates the default path" "$?"
contains "$CALLS" 'cloudfront create-invalidation --distribution-id ABCD1234EFGH --paths /*'
check "passes distribution id and paths to the CLI" "$?"

run_invalidate $'/index.html\n/assets/*'
check "multi-line paths exit 0" "$?"
contains "$CALLS" '--paths /index.html /assets/*'
check "multi-line paths become separate arguments" "$?"

run_invalidate ""
check "empty paths fall back to /*" "$?"
contains "$CALLS" '--paths /*'
check "fallback path is /*" "$?"

# ── Result ───────────────────────────────────────────────────────────────────
echo
echo "smoke-workflow-sync: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

