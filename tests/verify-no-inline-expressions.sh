#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify-no-inline-expressions.sh — audit gate for GitHub Actions script injection.
#
# A `${{ ... }}` expression placed inside a `run:` block is expanded by the
# workflow runtime and then handed to the shell as source text. Any caller-supplied
# value (a workflow input, an event field such as a branch name or a PR title) can
# therefore carry `$(...)`, backticks or `;` and execute inside the job — with the
# job's OIDC token. This repository publishes a reusable workflow that other
# repositories trust with production credentials, so it must not contain a single
# inline expression in a shell body.
#
# The correct pattern, used throughout this repository, is a step-level `env:`
# entry: the runtime hands the value to the shell as data in the environment, where
# no expansion takes place.
#
# Reads every workflow YAML and every example, and fails on any expression found in
# a `run:` body. Expressions are still allowed everywhere else (`with:`, `env:`,
# `if:`, `concurrency:`) — that is where they belong.
#
# Requires python3 + PyYAML. A missing parser is an environment error (exit 2);
# this check must never report success without having read anything.
#
# Usage: tests/verify-no-inline-expressions.sh
# Exit codes: 0 clean · 1 findings · 2 environment error
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

if ! command -v python3 >/dev/null 2>&1; then
  echo "verify-no-inline-expressions: python3 is required." >&2
  exit 2
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "verify-no-inline-expressions: python3 with PyYAML is required." >&2
  echo "  install it with: python3 -m pip install pyyaml" >&2
  exit 2
fi

python3 - <<'PY'
import glob
import sys

import yaml

PATHS = sorted(glob.glob(".github/workflows/*.yml")) + sorted(glob.glob("examples/*.yml"))

if not PATHS:
    print("verify-no-inline-expressions: ❌ no workflow YAML found to scan", file=sys.stderr)
    sys.exit(2)

findings = 0
run_blocks = 0

for path in PATHS:
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    for job_name, job in (doc.get("jobs") or {}).items():
        for step in (job or {}).get("steps") or []:
            body = step.get("run")
            if not body:
                continue
            run_blocks += 1
            step_name = step.get("name") or "<unnamed>"
            for lineno, line in enumerate(body.splitlines(), start=1):
                if "${{" not in line:
                    continue
                findings += 1
                print(
                    f"  ❌ {path}: job '{job_name}', step '{step_name}', "
                    f"run line {lineno} → {line.strip()}"
                )

print()
print(
    f"verify-no-inline-expressions: scanned {run_blocks} run block(s) "
    f"across {len(PATHS)} YAML file(s)."
)

if run_blocks == 0:
    print("verify-no-inline-expressions: ❌ no run block was scanned", file=sys.stderr)
    sys.exit(2)

if findings > 0:
    print(f"verify-no-inline-expressions: ❌ {findings} inline expression(s) in run bodies.")
    print("  Move each value to a step-level env: entry and read it as \"$VAR\".")
    sys.exit(1)

print("verify-no-inline-expressions: ✅ clean — no expression is interpolated into a run body.")
PY
