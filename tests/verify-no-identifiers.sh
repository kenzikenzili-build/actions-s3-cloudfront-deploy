#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify-no-identifiers.sh — audit gate for the "no proprietary identifiers"
#                            constraint of this extraction.
#
# This repository is a generic building block. It must never contain an account
# id, a distribution id, a bucket name, a hostname or an organisation name that
# belongs to whoever operates the pipeline. All of those are inputs.
#
# Two classes of pattern are checked:
#
#   1. GENERIC SHAPES, defined in this file and safe to publish: anything shaped
#      like a credential (a static AWS access key, a private-key block) or like
#      an AWS ARN / bare 12-digit account id that is not a documented placeholder.
#
#   2. THE OPERATOR'S OWN VALUES. These are deliberately **not** in this file. A
#      scanner that ships the values it forbids publishes exactly what it is meant
#      to protect — so the list is supplied out-of-band, in `label|extended-regex`
#      form, one entry per line (`#` comments and blank lines allowed), from
#      whichever source is present:
#
#        * $PROPRIETARY_IDENTIFIERS        — use this in CI, backed by a repository
#                                            secret so the list is encrypted at
#                                            rest and never committed;
#        * $PROPRIETARY_IDENTIFIERS_FILE   — a local file; default
#                                            tests/proprietary-identifiers.local
#                                            (git-ignored). See
#                                            tests/proprietary-identifiers.example
#                                            for the format.
#
#      An entry with no `|` is treated as a literal string to look for. Matched
#      values from this list are NOT echoed, so a public CI log cannot become the
#      leak either.
#
# When no list is configured, the generic shapes still run in full and the skip is
# announced loudly in the output. Set REQUIRE_PROPRIETARY_LIST=1 to make a missing
# list a hard failure (exit 2) instead; CI does that wherever the secret exists, so
# the gate cannot quietly degrade to "generic shapes only".
#
# Placeholders such as 111122223333 (AWS's own documentation account) and
# 000000000000 are allowlisted for the generic shapes, so the README and the
# example list can show realistic values. This file is scanned like any other, and
# contains no real value.
#
# Usage: tests/verify-no-identifiers.sh [extra path ...]
# Exit codes: 0 clean · 1 findings · 2 environment error
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

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
  while IFS= read -r -d '' f; do FILES+=("$f"); done < <(git ls-files -z)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "verify-no-identifiers: no files to scan"
  exit 0
fi

# ── Generic, publishable pattern shapes ──────────────────────────────────────
# label|extended-regex
PATTERNS=(
  'aws-account-id-in-arn|arn:aws:[a-z0-9-]*::[0-9]{12}:'
  'aws-account-id-bare|[^0-9][0-9]{12}[^0-9]'
  'aws-static-access-key|(AKIA|ASIA|AROA|AIDA)[0-9A-Z]{12,}'
  'private-key-block|-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----'
)

# Values that are deliberately public placeholders.
ALLOWLIST='000000000000|111122223333|123456789012|EXAMPLE|PLACEHOLDER|REDACTED|your-|dummy|CHANGEME'

# ── The operator's own values, supplied out-of-band ──────────────────────────
# Nothing proprietary is stored in this repository: the list arrives from a CI
# secret or from a git-ignored file. See the header for the rationale.
PROPRIETARY_LIST_FILE="${PROPRIETARY_IDENTIFIERS_FILE:-${REPO_ROOT}/tests/proprietary-identifiers.local}"
PROPRIETARY_SOURCE=""
PROPRIETARY_RAW=""

if [ -n "${PROPRIETARY_IDENTIFIERS:-}" ]; then
  PROPRIETARY_SOURCE="the PROPRIETARY_IDENTIFIERS environment variable"
  PROPRIETARY_RAW="$PROPRIETARY_IDENTIFIERS"
elif [ -s "$PROPRIETARY_LIST_FILE" ]; then
  PROPRIETARY_SOURCE="file ${PROPRIETARY_LIST_FILE}"
  PROPRIETARY_RAW="$(cat "$PROPRIETARY_LIST_FILE")"
fi

PROPRIETARY_PATTERNS=()
if [ -n "$PROPRIETARY_SOURCE" ]; then
  while IFS= read -r entry; do
    entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$entry" ] || continue
    case "$entry" in \#*) continue ;; esac
    case "$entry" in
      *'|'*) PROPRIETARY_PATTERNS+=("$entry") ;;
      *)     PROPRIETARY_PATTERNS+=("proprietary-identifier|${entry}") ;;
    esac
  done <<< "$PROPRIETARY_RAW"
fi

REQUIRE_PROPRIETARY_LIST="${REQUIRE_PROPRIETARY_LIST:-0}"

if [ "${#PROPRIETARY_PATTERNS[@]}" -eq 0 ] && [ "$REQUIRE_PROPRIETARY_LIST" = "1" ]; then
  echo "verify-no-identifiers: ❌ no proprietary identifier list is configured." >&2
  echo "  Supply it through PROPRIETARY_IDENTIFIERS (CI secret) or ${PROPRIETARY_LIST_FILE}," >&2
  echo "  or set REQUIRE_PROPRIETARY_LIST=0 to check the generic shapes only." >&2
  exit 2
fi

FINDINGS=0

scan_patterns() { # scan_patterns <generic|proprietary> <entry...>
  # generic     — skip allowlisted documentation placeholders, echo the match
  # proprietary — never skip, never echo the match (it may be a real value and a
  #               public CI log must not become the leak)
  local mode="$1"; shift
  local entry label regex hit file lineno line match

  for entry in "$@"; do
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
        if [ "$mode" = "generic" ] && printf '%s' "$match" | grep -qE "$ALLOWLIST"; then
          continue
        fi
        FINDINGS=$((FINDINGS + 1))
        if [ "$mode" = "proprietary" ]; then
          printf '  ❌ [%s] %s:%s → <redacted: the matched value is not echoed>\n' "$label" "$file" "$lineno"
        else
          printf '  ❌ [%s] %s:%s → %s\n' "$label" "$file" "$lineno" "$match"
        fi
      done < <(printf '%s' "$line" | grep -oE "$regex")
    done < <(grep -nHIE "$regex" "${FILES[@]}" 2>/dev/null)
  done
}

echo "verify-no-identifiers: scanning ${#FILES[@]} file(s) …"
scan_patterns "generic" "${PATTERNS[@]}"

if [ "${#PROPRIETARY_PATTERNS[@]}" -gt 0 ]; then
  echo "verify-no-identifiers: ${#PROPRIETARY_PATTERNS[@]} operator pattern(s) loaded from ${PROPRIETARY_SOURCE} (matches are redacted)"
  scan_patterns "proprietary" "${PROPRIETARY_PATTERNS[@]}"
else
  echo "verify-no-identifiers: ⚠️  NO proprietary identifier list is configured — checked the"
  echo "                     PROPRIETARY_IDENTIFIERS variable and ${PROPRIETARY_LIST_FILE}."
  echo "                     Only generic credential/ARN shapes were verified. Configure the list"
  echo "                     to enforce your account ids, orgs, distribution ids and hostnames."
fi

echo
if [ "$FINDINGS" -gt 0 ]; then
  printf 'verify-no-identifiers: ❌ %s finding(s) — this repository must stay generic.\n' "$FINDINGS"
  echo "  Replace the value with an input/parameter, or move it to the caller repo."
  exit 1
fi

echo "verify-no-identifiers: ✅ clean — no proprietary identifiers, no credential shapes."
exit 0
