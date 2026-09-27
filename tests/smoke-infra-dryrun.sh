#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke-infra-dryrun.sh — offline contract test for scripts/setup-project-infra.sh
#
# A stubbed `aws` binary is placed first in PATH, so the test never touches a
# real account. It asserts the two things that matter for an audit of this repo:
#
#   1. STRUCTURE — the generated trust policy trusts only the GitHub OIDC
#      provider with the requested subject pattern (no static principal, no
#      wildcard subject), and the deploy policy is least-privilege (one bucket
#      plus the named distributions) and valid JSON.
#
#   2. SAFETY — in --dry-run nothing is mutated: no create-role, no
#      create-bucket, no put-role-policy, no OIDC provider creation. The stub
#      records every call it receives and the test fails if a mutating call
#      appears.
#
# Usage: tests/smoke-infra-dryrun.sh
# Exit codes: 0 pass · 1 failure · 2 environment error
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/setup-project-infra.sh"

[ -f "$SCRIPT" ] || { echo "smoke: cannot find ${SCRIPT}" >&2; exit 2; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN="${WORKDIR}/bin"
mkdir -p "$FAKE_BIN"
CALLS="${WORKDIR}/aws-calls.log"

# ── Stub AWS CLI ─────────────────────────────────────────────────────────────
# Answers the three read-only calls the script makes and logs every invocation.
cat > "${FAKE_BIN}/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_AWS_LOG}"
case "$1 $2" in
  "sts get-caller-identity")
    printf '111122223333\tarn:aws:iam::111122223333:user/ci-provisioner\tAIDAEXAMPLEUSERID\n'
    ;;
  "iam list-open-id-connect-providers")
    printf 'arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com\n'
    ;;
  "s3api head-bucket")
    exit 0   # pretend the bucket already exists
    ;;
  "iam get-role")
    exit 0   # pretend the role already exists
    ;;
esac
exit 0
STUB
chmod +x "${FAKE_BIN}/aws"

PASS=0
FAIL=0
check() { # check <description> <condition-exit-status>
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

run_script() { # run_script <out-file> <args...>
  local out="$1"; shift
  : > "$CALLS"
  FAKE_AWS_LOG="$CALLS" PATH="${FAKE_BIN}:${PATH}" \
    bash "$SCRIPT" "$@" > "$out" 2> "${out%.out}.err"
}

# ── Case 1: scoped distribution, explicit ref pattern ────────────────────────
echo "case 1 — scoped distribution + explicit refs (dry-run)"
OUT1="${WORKDIR}/case1.out"
run_script "$OUT1" --bucket octo-site-prod --region eu-west-1 \
  --repo-owner octo-org --repo-name octo-site \
  --cloudfront-distribution-id ABCD1234EFGH --dry-run
check "exits 0" "$?"

contains "$OUT1" 'arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com'
check "trusts the GitHub OIDC provider" "$?"

# The subject list must be a StringEquals array of explicit refs, never a
# StringLike wildcard: the latter trusts every branch, tag and pull request.
contains "$OUT1" '"token.actions.githubusercontent.com:sub": ['
check "sub is a list, not a single pattern" "$?"

contains "$OUT1" '"repo:octo-org/octo-site:ref:refs/heads/main",'
check "default trust includes refs/heads/main" "$?"

contains "$OUT1" '"repo:octo-org/octo-site:ref:refs/heads/dev"'
check "default trust includes refs/heads/dev" "$?"

missing "$OUT1" 'StringLike'
check "no StringLike condition anywhere in the trust policy" "$?"

missing "$OUT1" 'repo:octo-org/octo-site:*'
check "no wildcard subject is emitted" "$?"

missing "$OUT1" 'pull_request'
check "pull_request subjects are never trusted" "$?"

contains "$OUT1" '"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"'
check "audience is pinned to sts.amazonaws.com" "$?"

missing "$OUT1" '"AWS": "*"'
check "no wildcard static principal in the trust policy" "$?"

contains "$OUT1" 'arn:aws:s3:::octo-site-prod'
check "bucket ARN granted" "$?"

contains "$OUT1" 'arn:aws:s3:::octo-site-prod/*'
check "bucket object ARN granted" "$?"

contains "$OUT1" 'arn:aws:cloudfront::111122223333:distribution/ABCD1234EFGH'
check "cloudfront invalidation scoped to the named distribution" "$?"

contains "$OUT1" 'arn:aws:iam::111122223333:role/octo-site-prod-deploy-role'
check "role ARN reported for the caller workflow" "$?"

# Payloads must be valid JSON.
TRUST_JSON="${WORKDIR}/trust.json"
POLICY_JSON="${WORKDIR}/policy.json"
awk '/^--- assume-role trust policy ---$/{f=1;next} /^--- inline deploy policy ---$/{f=0} f' "$OUT1" > "$TRUST_JSON"
awk '/^--- inline deploy policy ---$/{f=1;next} /^=== /{f=0} f' "$OUT1" > "$POLICY_JSON"

if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TRUST_JSON" 2>/dev/null
  check "trust policy is valid JSON" "$?"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$POLICY_JSON" 2>/dev/null
  check "deploy policy is valid JSON" "$?"
else
  echo "  (skipped JSON validation: python3 not available)"
fi

# Nothing may be mutated in dry-run.
if grep -qE '^(s3api create-bucket|s3api put-public-access-block|iam create-role|iam update-assume-role-policy|iam put-role-policy|iam create-open-id-connect-provider)' "$CALLS"; then
  check "dry-run performed no mutating aws call" 1
else
  check "dry-run performed no mutating aws call" 0
fi

# Idempotency signal: because head-bucket and get-role succeeded, the script must
# reconcile rather than create.
contains "$OUT1" 'bucket already present: octo-site-prod'
check "reuses an existing bucket instead of recreating it" "$?"
contains "$OUT1" 'role already present: octo-site-prod-deploy-role'
check "reconciles an existing role instead of recreating it" "$?"


# ── Case 2: --repo shorthand, CloudFront omitted ─────────────────────────────
echo "case 2 — --repo shorthand with --no-cloudfront (dry-run)"
OUT2="${WORKDIR}/case2.out"
run_script "$OUT2" --bucket octo-site-dev --repo octo-org/octo-site --no-cloudfront --dry-run
check "exits 0" "$?"

contains "$OUT2" '"repo:octo-org/octo-site:ref:refs/heads/main",'
check "--repo shorthand trusts explicit refs, not a wildcard" "$?"

contains "$OUT2" '"repo:octo-org/octo-site:ref:refs/heads/dev"'
check "--repo shorthand trusts the default dev ref too" "$?"

missing "$OUT2" 'repo:octo-org/octo-site:*'
check "--repo shorthand never becomes repo:<owner>/<repo>:*" "$?"

missing "$OUT2" 'cloudfront:CreateInvalidation'
check "--no-cloudfront omits the CloudFront statement" "$?"

missing "$OUT2" 'arn:aws:cloudfront::'
check "no CloudFront ARN when the statement is omitted" "$?"

# ── Case 3: repeated distribution ids ────────────────────────────────────────
echo "case 3 — repeated --cloudfront-distribution-id scopes every distribution"
OUT3="${WORKDIR}/case3.out"
run_script "$OUT3" --bucket octo-site-prod2 \
  --repo octo-org/octo-site \
  --cloudfront-distribution-id AAAA1111BBBB \
  --cloudfront-distribution-id CCCC2222DDDD --dry-run
check "exits 0" "$?"

contains "$OUT3" 'arn:aws:cloudfront::111122223333:distribution/AAAA1111BBBB'
check "first distribution ARN present" "$?"

contains "$OUT3" 'arn:aws:cloudfront::111122223333:distribution/CCCC2222DDDD'
check "second distribution ARN present" "$?"

POLICY_JSON3="${WORKDIR}/policy3.json"
awk '/^--- inline deploy policy ---$/{f=1;next} /^=== /{f=0} f' "$OUT3" > "$POLICY_JSON3"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$POLICY_JSON3" 2>/dev/null
  check "multi-distribution policy is valid JSON" "$?"
fi


# ── Case 4: fail-fast on bad input ───────────────────────────────────────────
echo "case 4 — validation failures"

run_script "${WORKDIR}/case4a.out" --repo octo-org/octo-site --dry-run
RC=$?
check "missing --bucket is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

run_script "${WORKDIR}/case4b.out" --bucket Invalid_Bucket --repo octo-org/octo-site --dry-run
RC=$?
check "invalid bucket name is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

run_script "${WORKDIR}/case4c.out" --bucket octo-site-prod --repo-pattern 'repo:octo-org/octo-site:*' --dry-run
RC=$?
check "the removed --repo-pattern is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

contains "${WORKDIR}/case4c.err" 'wildcard subject is not accepted'
check "--repo-pattern fails with the hardening message" "$?"

run_script "${WORKDIR}/case4d.out" --bucket octo-site-prod --repo octo-org/octo-site --bogus-flag --dry-run
RC=$?
check "unknown argument is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

run_script "${WORKDIR}/case4e.out" --bucket octo-site-prod --repo-owner octo-org --dry-run
RC=$?
check "missing --repo-name is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

run_script "${WORKDIR}/case4f.out" --bucket octo-site-prod --repo-name octo-site --dry-run
RC=$?
check "missing --repo-owner is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

run_script "${WORKDIR}/case4g.out" --bucket octo-site-prod \
  --repo-owner octo-org --repo-name octo-site --branch 'release/*' --dry-run
RC=$?
check "a glob in --branch is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

run_script "${WORKDIR}/case4h.out" --bucket octo-site-prod \
  --repo-owner octo-org --repo-name octo-site --branch main --branch pull_request --dry-run
RC=$?
check "a pull_request subject is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

run_script "${WORKDIR}/case4i.out" --bucket octo-site-prod --repo octo-site --dry-run
RC=$?
check "--repo without <owner>/<name> is rejected (rc=${RC})" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

# Asserted while $CALLS still holds only the failing invocations above: validation
# must fail before the script reaches any AWS API, read-only ones included.
if grep -qE '^(sts|iam|s3api) ' "$CALLS"; then
  check "validation failures reached no aws call" 1
else
  check "validation failures reached no aws call" 0
fi

# ── Case 5: the trust boundary can be narrowed ───────────────────────────────
echo "case 5 — an explicit --branch replaces the default refs"
OUT5="${WORKDIR}/case5.out"
run_script "$OUT5" --bucket octo-site-prod \
  --repo-owner octo-org --repo-name octo-site --branch release/1.x --dry-run
RC=$?
check "an explicit --branch is accepted (rc=${RC})" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
contains "$OUT5" '"repo:octo-org/octo-site:ref:refs/heads/release/1.x"'
check "the explicit --branch is the trusted ref" "$?"
missing "$OUT5" 'refs/heads/main'
check "overriding --branch drops the default refs" "$?"
missing "$OUT5" 'StringLike'
check "narrowing still emits StringEquals, never StringLike" "$?"

# ── Case 6: --help ───────────────────────────────────────────────────────────
echo "case 6 — --help"
OUT6="${WORKDIR}/case6.out"
run_script "$OUT6" --help
check "--help exits 0" "$?"
contains "$OUT6" '--repo-owner'
check "documents --repo-owner" "$?"
contains "$OUT6" '--repo-name'
check "documents --repo-name" "$?"
contains "$OUT6" '--branch'
check "documents --branch" "$?"
contains "$OUT6" '--bucket'
check "documents --bucket" "$?"

# ── Result ───────────────────────────────────────────────────────────────────
echo
echo "smoke-infra-dryrun: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

