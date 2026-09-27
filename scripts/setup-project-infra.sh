#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-project-infra.sh — idempotent, least-privilege AWS bootstrap for the
#                          keyless S3 + CloudFront deploy pipeline.
#
# Creates (or reconciles) exactly three things, and nothing else:
#
#   1. an S3 bucket for the site artefacts,
#   2. an IAM role whose trust policy only accepts GitHub Actions OIDC tokens
#      from the exact repository and refs you name, and
#   3. an inline policy that grants that role write access to that one bucket
#      plus CloudFront invalidation.
#
# The trust policy is deliberately narrow: `sub` is matched with **StringEquals**
# against an explicit list of refs (`refs/heads/main`, `refs/heads/dev` by
# default) for one named repository. Wildcards are rejected outright, so a token
# minted for another branch, another tag, another repository, or a pull request
# from a fork cannot assume the role. There is no default owner and no default
# repository: both are mandatory flags.
#
# There are no long-lived AWS credentials anywhere in this design. The role is
# assumed with a short-lived OIDC token, so there is no key to leak, rotate or
# exfiltrate from CI.
#
# Idempotency: every action is "create if absent, reconcile if present". Running
# the script twice against the same target produces the same end state and
# mutates nothing on the second run.
#
# Nothing about a specific account, bucket or distribution is baked in: every
# identifier arrives through an argument.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROGRAM="$(basename "$0")"

# Documentation placeholder account id (AWS's own example). It is only used when
# --dry-run runs without usable AWS credentials, so that the generated payloads
# can be inspected offline. It is deliberately NOT a real account id.
PLACEHOLDER_ACCOUNT_ID="111122223333"

usage() {
  cat <<USAGE
${PROGRAM} — bootstrap a private S3 + CloudFront deploy target and its OIDC role.

Usage:
  ${PROGRAM} --bucket <name> --repo-owner <owner> --repo-name <repo> [options]

Required:
  --bucket <name>
        S3 bucket that will receive the build artefacts. Created if absent.

  --repo-owner <owner>
  --repo-name <repo>
        Repository whose Actions runs may assume the role. Both are required:
        there is no default owner and no default repository. The trust policy is
        emitted as a StringEquals list of explicit refs, e.g.
          repo:<owner>/<repo>:ref:refs/heads/main
          repo:<owner>/<repo>:ref:refs/heads/dev
        You may pass --repo <owner>/<repo> as a shorthand for both flags.

Options:
  --region <region>                  Default: \$AWS_REGION, \$AWS_DEFAULT_REGION, us-east-1
  --repo <owner/repo>                Shorthand for --repo-owner + --repo-name.
  --branch <name>                    Repeatable. Trust only this branch's ref.
                                     Default: main and dev. A slash is allowed
                                     (release/1.x); globs and pull requests are not.
  --role-name <name>                 Default: <bucket>-deploy-role (max 64 chars)
  --policy-name <name>               Default: <role-name>-policy
  --cloudfront-distribution-id <id>  Repeatable. Scopes cloudfront:CreateInvalidation
                                     to that distribution's ARN (least privilege).
  --no-cloudfront                    Omit the CloudFront statement entirely.
  --create-oidc-provider             Create the GitHub OIDC provider when missing.
                                     Without this flag the script stops and tells
                                     you it is absent (account-level change: opt in).
  --block-public-access              Apply the S3 Block Public Access configuration.
  --dry-run                          Print the plan and the generated IAM payloads;
                                     change nothing and write nothing.
  -h, --help                         Show this help.

Examples:
  # Production bucket, main and dev only, scoped invalidation
  ${PROGRAM} --bucket octo-site-prod --region eu-west-1 \\
    --repo-owner octo-org --repo-name octo-site \\
    --cloudfront-distribution-id ABCDEF123456

  # A single release branch instead of the default main + dev pair
  ${PROGRAM} --bucket octo-site-prod --repo octo-org/octo-site --branch main

  # Inspect what would be created without touching AWS
  ${PROGRAM} --bucket octo-site-dev --repo octo-org/octo-site --dry-run

Trust policy guarantee:
  Both \`aud\` and \`sub\` are matched with StringEquals. A wildcard subject
  (\`repo:owner/repo:*\`) would trust every branch, every tag and every pull
  request in the repository, so this script refuses to emit one:
  \`--repo-pattern\` has been removed, and any glob character in an owner,
  repository or branch is rejected before an AWS call is made.

Exit codes: 0 success · 1 usage or validation error · 2 AWS precondition failure
USAGE
}

# ── Argument defaults ────────────────────────────────────────────────────────
BUCKET=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
REPO_OWNER=""
REPO_NAME=""
BRANCHES=()
ROLE_NAME=""
POLICY_NAME=""
CLOUDFRONT_IDS=()
DRY_RUN=0
CREATE_OIDC_PROVIDER=0
BLOCK_PUBLIC_ACCESS=0
NO_CLOUDFRONT=0

die() { echo "error: $*" >&2; exit 1; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket)                     [ $# -ge 2 ] || die "--bucket needs a value"; BUCKET="$2"; shift 2 ;;
    --region)                     [ $# -ge 2 ] || die "--region needs a value"; REGION="$2"; shift 2 ;;
    --repo-owner)                 [ $# -ge 2 ] || die "--repo-owner needs a value"; REPO_OWNER="$2"; shift 2 ;;
    --repo-name)                  [ $# -ge 2 ] || die "--repo-name needs a value"; REPO_NAME="$2"; shift 2 ;;
    --branch)                     [ $# -ge 2 ] || die "--branch needs a value"; BRANCHES+=("$2"); shift 2 ;;
    --repo)
                                  [ $# -ge 2 ] || die "--repo needs a value"
                                  case "$2" in
                                    */*) : ;;
                                    *) die "--repo expects <owner>/<repo> (got '$2'). Use --repo-owner and --repo-name separately for an unusual name." ;;
                                  esac
                                  REPO_OWNER="${2%%/*}"
                                  REPO_NAME="${2#*/}"
                                  shift 2
                                  ;;
    --repo-pattern)               die "--repo-pattern has been removed: a wildcard subject is not accepted. Use --repo-owner <owner> --repo-name <repo> (optionally --branch <name>) so the trust policy stays a StringEquals list of explicit refs." ;;
    --role-name)                  [ $# -ge 2 ] || die "--role-name needs a value"; ROLE_NAME="$2"; shift 2 ;;
    --policy-name)                [ $# -ge 2 ] || die "--policy-name needs a value"; POLICY_NAME="$2"; shift 2 ;;
    --cloudfront-distribution-id) [ $# -ge 2 ] || die "--cloudfront-distribution-id needs a value"; CLOUDFRONT_IDS+=("$2"); shift 2 ;;
    --no-cloudfront)              NO_CLOUDFRONT=1; shift ;;
    --create-oidc-provider)       CREATE_OIDC_PROVIDER=1; shift ;;
    --block-public-access)        BLOCK_PUBLIC_ACCESS=1; shift ;;
    --dry-run)                    DRY_RUN=1; shift ;;
    -h|--help)                    usage; exit 0 ;;
    *)                            usage >&2; die "unknown argument '$1'" ;;
  esac
done

# ── Validation (fail fast, before any AWS call) ──────────────────────────────
[ -n "$BUCKET" ] || { usage >&2; die "--bucket is required"; }
[ -n "$REPO_OWNER" ] || { usage >&2; die "--repo-owner is required (or pass --repo <owner>/<repo>). There is no default owner."; }
[ -n "$REPO_NAME" ] || { usage >&2; die "--repo-name is required (or pass --repo <owner>/<repo>). There is no default repository."; }

case "$BUCKET" in
  *[!a-z0-9.-]*|.*|*.-*|-*) die "--bucket '$BUCKET' is not a valid S3 bucket name (lowercase letters, digits, dots and hyphens only)" ;;
esac
bucket_len=${#BUCKET}
[ "$bucket_len" -ge 3 ] && [ "$bucket_len" -le 63 ] || die "--bucket must be 3-63 characters long (got ${bucket_len})"

# The trust policy decides *who* may assume the role, so it is the single most
# security-sensitive value in this script. Only explicit refs are accepted:
# a wildcard `sub` would trust every branch, every tag and every pull request in
# the repository, and a `:pull_request` subject would let a fork assume the role
# from a PR. Both are rejected here, before any AWS call is made.
assert_subject_token() { # assert_subject_token <label> <value> <allow-slash:yes|no>
  local label="$1" value="$2" allow_slash="$3"

  [ -n "$value" ] || die "${label} must not be empty"

  case "$value" in
    *'*'*|*'?'*|*'['*|*']'*)
      die "${label} '${value}' contains a glob character. Only explicit refs are supported: a wildcard subject trusts every branch, tag and pull request in the repository." ;;
    *pull_request*|*refs/pull*)
      die "${label} '${value}' refers to a pull request. Pull-request subjects are never trusted: a fork could otherwise assume the deploy role from a PR." ;;
  esac

  if [ "$allow_slash" = "yes" ]; then
    case "$value" in
      *[!A-Za-z0-9._/-]*) die "${label} '${value}' contains an invalid character (letters, digits, dot, underscore, hyphen and slash only)." ;;
    esac
  else
    case "$value" in
      */*|*[!A-Za-z0-9._-]*) die "${label} '${value}' contains an invalid character (letters, digits, dot, underscore and hyphen only)." ;;
    esac
  fi
}

assert_subject_token "repository owner (--repo-owner)" "$REPO_OWNER" "no"
assert_subject_token "repository name (--repo-name)"   "$REPO_NAME"  "no"

# Default trust boundary: the two long-lived branches. Anything else has to be
# asked for explicitly, one --branch at a time.
if [ "${#BRANCHES[@]}" -eq 0 ]; then
  BRANCHES=(main dev)
fi

TRUST_SUBJECTS=()
for branch in "${BRANCHES[@]}"; do
  assert_subject_token "--branch" "$branch" "yes"
  case "$branch" in
    refs/*|heads/*|*/heads/*) die "--branch '${branch}' looks like a full ref; pass the branch name only (e.g. 'main')." ;;
  esac
  TRUST_SUBJECTS+=("repo:${REPO_OWNER}/${REPO_NAME}:ref:refs/heads/${branch}")
done

[ -n "$ROLE_NAME" ] || ROLE_NAME="${BUCKET}-deploy-role"
role_len=${#ROLE_NAME}
[ "$role_len" -le 64 ] || die "--role-name '${ROLE_NAME}' is ${role_len} characters; IAM role names are limited to 64. Pass an explicit --role-name."

[ -n "$POLICY_NAME" ] || POLICY_NAME="${ROLE_NAME}-policy"

if [ "$NO_CLOUDFRONT" -eq 1 ] && [ "${#CLOUDFRONT_IDS[@]}" -gt 0 ]; then
  die "--no-cloudfront and --cloudfront-distribution-id are mutually exclusive"
fi

command -v aws >/dev/null 2>&1 || die "the AWS CLI ('aws') is required but was not found in PATH"

# ── Caller identity ──────────────────────────────────────────────────────────
# Read-only; still run during --dry-run so the plan shows the arns that would be
# written. Falls back to the documentation placeholder when credentials are not
# available in dry-run mode.
ACCOUNT_ID=""
CALLER_ARN=""
if CALLER_JSON="$(aws sts get-caller-identity --output text 2>/dev/null)"; then
  # `--output text` renders the structure as ONE tab-separated line:
  #   <account-id>\t<arn>\t<user-id>
  ACCOUNT_ID="$(printf '%s\n' "$CALLER_JSON" | awk 'NR==1 {print $1}')"
  CALLER_ARN="$(printf '%s\n' "$CALLER_JSON" | awk 'NR==1 {print $2}')"
fi

if [ -z "$ACCOUNT_ID" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    ACCOUNT_ID="$PLACEHOLDER_ACCOUNT_ID"
    CALLER_ARN="arn:aws:iam::${PLACEHOLDER_ACCOUNT_ID}:user/dry-run"
    echo "warning: no usable AWS credentials — dry-run uses the placeholder account ${PLACEHOLDER_ACCOUNT_ID}." >&2
  else
    die "unable to resolve the caller identity. Configure AWS credentials (env vars, SSO or profile) and retry."
  fi
fi

OIDC_HOST="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

echo "=== Provisioning plan ==="
echo "  AWS account  : ${ACCOUNT_ID}  (${CALLER_ARN})"
echo "  Region       : ${REGION}"
echo "  S3 bucket    : ${BUCKET}"
echo "  IAM role     : ${ROLE_NAME}"
echo "  IAM policy   : ${POLICY_NAME} (inline)"
echo "  OIDC provider: ${OIDC_ARN}"
echo "  Trust subs   : ${#TRUST_SUBJECTS[@]} explicit ref(s)"
printf '                 %s\n' "${TRUST_SUBJECTS[@]}"
if [ "$NO_CLOUDFRONT" -eq 0 ] && [ "${#CLOUDFRONT_IDS[@]}" -gt 0 ]; then
  echo "  CloudFront   : ${CLOUDFRONT_IDS[*]} (invalidation scoped to these distributions)"
elif [ "$NO_CLOUDFRONT" -eq 0 ]; then
  echo "  CloudFront   : NOT scoped — cloudfront:CreateInvalidation will be granted on \"*\" (see --cloudfront-distribution-id)"
else
  echo "  CloudFront   : omitted (--no-cloudfront)"
fi
[ "$DRY_RUN" -eq 1 ] && echo "  Mode         : DRY RUN — nothing will be created or modified"
echo

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ── 0. GitHub OIDC provider (must already exist unless opted in) ─────────────
echo "--- OIDC provider ---"
OIDC_EXISTS=0
for existing in $(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null || true); do
  if [ "$existing" = "$OIDC_ARN" ]; then
    OIDC_EXISTS=1
    break
  fi
done

if [ "$OIDC_EXISTS" -eq 1 ]; then
  echo "provider already present: ${OIDC_ARN}"
elif [ "$CREATE_OIDC_PROVIDER" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] aws iam create-open-id-connect-provider --url https://${OIDC_HOST} --client-id-list sts.amazonaws.com"
  else
    aws iam create-open-id-connect-provider \
      --url "https://${OIDC_HOST}" \
      --client-id-list "sts.amazonaws.com"
    echo "created OIDC provider: ${OIDC_ARN}"
  fi
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] provider absent; re-run with --create-oidc-provider to create it"
  else
    die "OIDC provider ${OIDC_ARN} is absent. It is account-level shared infrastructure — re-run with --create-oidc-provider to create it."
  fi
fi


# ── 1. S3 bucket (create if absent) ──────────────────────────────────────────
echo "--- S3 bucket ---"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "bucket already present: ${BUCKET} (left as is)"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$REGION" = "us-east-1" ]; then
      echo "[dry-run] aws s3api create-bucket --bucket ${BUCKET} --region ${REGION}"
    else
      echo "[dry-run] aws s3api create-bucket --bucket ${BUCKET} --region ${REGION} --create-bucket-configuration LocationConstraint=${REGION}"
    fi
  else
    # us-east-1 rejects an explicit LocationConstraint; every other region needs it.
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
    echo "created bucket: ${BUCKET} (${REGION})"
  fi
fi

if [ "$BLOCK_PUBLIC_ACCESS" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] aws s3api put-public-access-block --bucket ${BUCKET} --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  else
    aws s3api put-public-access-block --bucket "$BUCKET" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    echo "applied Block Public Access on ${BUCKET}"
  fi
fi

# ── 2. Trust policy (OIDC only, no static principals) ────────────────────────
# `sub` is a StringEquals list of explicit refs. A StringLike wildcard would
# trust every branch, every tag and every pull request in the repository; a
# `:pull_request` entry would let a fork assume this role from a PR.
TRUST_SUB_JSON=""
FIRST_SUBJECT=1
for subject in "${TRUST_SUBJECTS[@]}"; do
  if [ "$FIRST_SUBJECT" -eq 1 ]; then
    FIRST_SUBJECT=0
    TRUST_SUB_JSON="            \"${subject}\""
  else
    TRUST_SUB_JSON="${TRUST_SUB_JSON},
            \"${subject}\""
  fi
done

TRUST_POLICY="${WORKDIR}/trust-policy.json"
cat > "$TRUST_POLICY" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GitHubActionsOIDC",
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOST}:aud": "sts.amazonaws.com",
          "${OIDC_HOST}:sub": [
${TRUST_SUB_JSON}
          ]
        }
      }
    }
  ]
}
JSON

echo "--- IAM role ---"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "role already present: ${ROLE_NAME} — reconciling trust policy"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] aws iam update-assume-role-policy --role-name ${ROLE_NAME} --policy-document file://${TRUST_POLICY}"
  else
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
      --policy-document "file://${TRUST_POLICY}" >/dev/null
    echo "updated trust policy on ${ROLE_NAME}"
  fi
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] aws iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document file://${TRUST_POLICY} --description \"GitHub Actions OIDC deploy role for ${BUCKET}\""
  else
    aws iam create-role --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://${TRUST_POLICY}" \
      --description "GitHub Actions OIDC deploy role for ${BUCKET}" >/dev/null
    echo "created role: ${ROLE_NAME}"
  fi
fi

# ── 3. Inline deploy policy (least privilege, single bucket) ─────────────────
# CloudFront invalidation is scoped to the distributions you name. When none are
# named the statement falls back to "*", which is broader than necessary — the
# script says so out loud instead of hiding it.
CLOUDFRONT_RESOURCES=""
if [ "$NO_CLOUDFRONT" -eq 0 ]; then
  if [ "${#CLOUDFRONT_IDS[@]}" -gt 0 ]; then
    for dist in "${CLOUDFRONT_IDS[@]}"; do
      if [ -n "$CLOUDFRONT_RESOURCES" ]; then
        CLOUDFRONT_RESOURCES="${CLOUDFRONT_RESOURCES},
        \"arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${dist}\""
      else
        CLOUDFRONT_RESOURCES="\"arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${dist}\""
      fi
    done
  else
    CLOUDFRONT_RESOURCES="\"*\""
  fi
fi

DEPLOY_POLICY="${WORKDIR}/deploy-policy.json"
{
  cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ArtifactSync",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    }
JSON
  if [ -n "$CLOUDFRONT_RESOURCES" ]; then
    cat <<JSON
    ,{
      "Sid": "CloudFrontInvalidation",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateInvalidation"
      ],
      "Resource": [
        ${CLOUDFRONT_RESOURCES}
      ]
    }
JSON
  fi
  cat <<JSON
  ]
}
JSON
} > "$DEPLOY_POLICY"

echo "--- IAM inline policy ---"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] aws iam put-role-policy --role-name ${ROLE_NAME} --policy-name ${POLICY_NAME} --policy-document file://${DEPLOY_POLICY}"
else
  aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://${DEPLOY_POLICY}" >/dev/null
  echo "attached inline policy: ${POLICY_NAME}"
fi


if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "=== Generated payloads (not applied) ==="
  echo "--- assume-role trust policy ---"
  cat "$TRUST_POLICY"
  echo "--- inline deploy policy ---"
  cat "$DEPLOY_POLICY"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== Dry run complete — nothing was created or modified ==="
else
  echo "=== Deploy target ready ==="
fi
echo "  Bucket   : ${BUCKET} (${REGION})"
echo "  Role ARN : ${ROLE_ARN}"
if [ "$NO_CLOUDFRONT" -eq 1 ]; then
  echo "  CloudFront: not granted (--no-cloudfront)"
elif [ "${#CLOUDFRONT_IDS[@]}" -gt 0 ]; then
  echo "  CloudFront: create-invalidation on ${CLOUDFRONT_IDS[*]}"
else
  echo "  CloudFront: create-invalidation on * (pass --cloudfront-distribution-id to scope it)"
fi
echo
echo "Wire it up in the caller workflow:"
echo
cat <<YAML
  deploy:
    uses: <owner>/actions-s3-cloudfront-deploy/.github/workflows/deploy-s3-cloudfront.yml@main
    with:
      s3_bucket: "${BUCKET}"
      aws_region: "${REGION}"
      role_to_assume: "${ROLE_ARN}"
      sync_exclude_paths: |
        data/*
        telemetry.json
    secrets: inherit
YAML

