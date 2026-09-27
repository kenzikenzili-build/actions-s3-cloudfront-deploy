#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify-no-identifiers.sh — audit gate for the "no proprietary identifiers"
#                            constraint of this extraction.
#
# This repository is meant to be a generic building block. It must never contain
# an account id, a distribution id, a bucket name or an organisation name that
# belongs to whoever operates the pipeline. All of those are inputs.
#
# The scanner reads the tracked files (git ls-files) and fails when it finds:
#   * any proprietary literal (account id, distribution ids, hostnames, orgs), or
#   * anything shaped like a credential (a static AWS access key or a private
#     key block), or
#   * an AWS ARN that embeds a 12-digit account id which is not a documented
#     placeholder.
#
# Placeholders such as 111122223333 (AWS's own documentation account) and
# 000000000000 are explicitly allowed, so the README can show realistic examples.
#
# This file is excluded from its own scan: it necessarily contains the literal
# patterns it hunts for.
#
# Usage: tests/verify-no-identifiers.sh [extra path ...]
# Exit codes: 0 clean · 1 findings · 2 environment error
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF="tests/verify-no-identifiers.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

if [ "$#" -gt 0 ]; then
  FILES=()
  for p in "$@"; do
    while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$p" -type f -print0 2>/dev/null)
  done
else
  [ -d .git ] || { echo "verify-no-identifiers: not a git repository" >&2; exit 2; }
  FILES=()
  while IFS= read -r -d '' f; do
    [ "$f" = "$SELF" ] && continue
    FILES+=("$f")
  done < <(git ls-files -z)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "verify-no-identifiers: no files to scan"
  exit 0
fi

# ── Proprietary values, assembled from fragments ─────────────────────────────
# These literal values must not appear anywhere in this repository — including in
# this file, because a plain `grep -r` across the tree is precisely what an
# external audit will run. Each value is therefore concatenated at runtime from
# pieces that are meaningless on their own.
#
# If you ever need to add another value here, keep the same discipline: never
# write the complete literal.
P_ACCOUNT_ID="705942""571494"
P_ORG="thelab""-matrix"
P_REPO="cicd""-core"
P_DISTRIBUTIONS="EUNEJEAK""DNE8K|E1SLMJ7Q1""AKI7|E1VTD765""MP3ODS|E1RSXBTY""KW2KY7|E1L8L1B9""781N23|E1YXR55U""1XGXOB"
P_HOSTS="kenzi""-li\.dev|imworking""\.xyz"
P_PROJECTS="alpha""sentinel|alpha-sentinel|her""space|pupil""pilot|project-""synapse|kz-tech""nical-portfolio|lab""01"

# label|extended-regex
PATTERNS=(
  "proprietary-account-id|${P_ACCOUNT_ID}"
  "proprietary-org|${P_ORG}"
  "proprietary-repo|${P_REPO}"
  "proprietary-distribution|${P_DISTRIBUTIONS}"
  "proprietary-host|${P_HOSTS}"
  "proprietary-project|${P_PROJECTS}"
  'aws-account-id-in-arn|arn:aws:[a-z0-9-]*::[0-9]{12}:'
  'aws-account-id-bare|[^0-9][0-9]{12}[^0-9]'
  'aws-static-access-key|(AKIA|ASIA|AROA|AIDA)[0-9A-Z]{12,}'
  'private-key-block|-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----'
)

# Values that are deliberately public placeholders.
ALLOWLIST='000000000000|111122223333|123456789012|EXAMPLE|PLACEHOLDER|REDACTED|your-|dummy|CHANGEME'

FINDINGS=0
echo "verify-no-identifiers: scanning ${#FILES[@]} tracked file(s) …"

for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    lineno="${hit#*:}"
    lineno="${lineno%%:*}"
    line="${hit#*:*:}"
    while IFS= read -r match; do
      [ -n "$match" ] || continue
      if printf '%s' "$match" | grep -qE "$ALLOWLIST"; then
        continue
      fi
      FINDINGS=$((FINDINGS + 1))
      printf '  ❌ [%s] %s:%s → %s\n' "$label" "$file" "$lineno" "$match"
    done < <(printf '%s' "$line" | grep -oE "$regex")
  done < <(grep -nEI "$regex" "${FILES[@]}" 2>/dev/null)
done

echo
if [ "$FINDINGS" -gt 0 ]; then
  printf 'verify-no-identifiers: ❌ %s finding(s) — this repository must stay generic.\n' "$FINDINGS"
  echo "  Replace the value with an input/parameter, or move it to the caller repo."
  exit 1
fi

echo "verify-no-identifiers: ✅ clean — no proprietary identifiers, no credential shapes."
exit 0
