# Zero-Key AWS S3 + CloudFront Deployment Action

[![CI](https://github.com/kenzikenzili-build/actions-s3-cloudfront-deploy/actions/workflows/validate.yml/badge.svg)](https://github.com/kenzikenzili-build/actions-s3-cloudfront-deploy/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/tag/kenzikenzili-build/actions-s3-cloudfront-deploy?label=release)](https://github.com/kenzikenzili-build/actions-s3-cloudfront-deploy/tags)

A production-grade, enterprise-hardened reusable GitHub Actions workflow that deploys static
frontends and applications to **AWS S3 + CloudFront** without long-lived AWS keys, featuring
**data-loss prevention** against naive `--delete` syncs.

```yaml
uses: kenzikenzili-build/actions-s3-cloudfront-deploy/.github/workflows/deploy-s3-cloudfront.yml@v1.0.0
```

---

## The Critical Problem This Solves

### 1. The Naive `--delete` Disaster in Serverless Architectures

Most deployment pipelines use:

```bash
# ⚠️ DANGEROUS: deletes live telemetry, user uploads or runtime state stored in the bucket
aws s3 sync ./dist s3://my-bucket --delete
```

If your serverless application writes runtime data, health-check state or telemetry into
prefixes inside the same bucket (e.g. `data/telemetry.json`), a standard CI sync pipeline
silently wipes that data on **every single deployment** — and the deploy still reports
success, so the outage surfaces hours later as "the dashboard looks broken".

**Our fix:** `sync_exclude_paths` enforces a last-match exclusion mask that is appended to
*every* sync pass. `aws s3 sync` applies `--exclude` to the upload **and** the delete
decision, so your live telemetry and runtime assets are guarded from both re-upload and
destructive deletion. A bare prefix (`data`) is normalised to `data/*` so the guard cannot
fail open on nested keys.

### 2. Zero-Static-Key Security (Strict OIDC)

Say goodbye to storing `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in GitHub Secrets.
Nothing to rotate, nothing to leak.

- Uses GitHub's **OIDC token exchange with AWS STS** — credentials are minted per job and
  expire with it.
- Hardened against privilege escalation: the trust policy is pinned to **`StringEquals`**
  matching explicit repository branch refs, with no `StringLike` and no wildcard.
- **Wildcards and fork PRs are denied by construction**: a `repo:owner/repo:*` subject or a
  `:pull_request` subject is rejected before any AWS call is made.

### 3. Non-Destructive Two-Tier Caching

One `Cache-Control` header cannot be right for every file in a static build:

- **Hashed assets** (`assets/*.9f2.js`, `_next/static/*`): immutable, `max-age=31536000, immutable`.
- **Entry points** (`index.html`, `sw.js`, `manifest.json`): revalidated, `no-cache, no-store, must-revalidate`, so a stale service worker can never become a kill switch you cannot flip.

`--size-only` plus an explicit pass-2 exclusion mask prevent the subtle failure mode where
**timestamp skew** makes the second pass re-upload a freshly-immutable asset as `no-cache` —
a silent downgrade no run log reports. Deploys are also serialised per bucket
(`concurrency`, `cancel-in-progress: false`), so two runs can never interleave inside a
`sync --delete`.

---

## Quickstart

### 1. Provision IAM & Bucket (one command)

The bundled script is idempotent (create-if-absent, reconcile-if-present) and
least-privilege: one bucket, one role, one inline policy.

```bash
chmod +x scripts/setup-project-infra.sh
./scripts/setup-project-infra.sh \
  --repo-owner "YOUR_GITHUB_USER_OR_ORG" \
  --repo-name "YOUR_REPO" \
  --bucket "your-app-production-bucket" \
  --region "us-east-1" \
  --cloudfront-distribution-id "E1234567890ABC"
```

Inspect the plan and the generated IAM payloads first with `--dry-run` — nothing is created
or modified. If the account has no GitHub OIDC provider yet, the script stops and tells you
to opt in with `--create-oidc-provider`, because that is shared account-level infrastructure.
It prints the role ARN to paste into the caller workflow.

### 2. Caller workflow (`.github/workflows/deploy.yml`)

```yaml
name: Deploy

on:
  push:
    branches: [main]

permissions:
  id-token: write   # required for the keyless OIDC exchange
  contents: read

jobs:
  deploy:
    uses: kenzikenzili-build/actions-s3-cloudfront-deploy/.github/workflows/deploy-s3-cloudfront.yml@v1.0.0
    with:
      aws_region: 'us-east-1'
      role_to_assume: 'arn:aws:iam::111122223333:role/your-app-deploy-role'
      s3_bucket: 'your-app-production-bucket'
      artifact_path: './dist'
      cloudfront_distribution_id: 'E1234567890ABC'
      sync_exclude_paths: |
        data/*
        uploads/*
        runtime-state.json
    secrets: inherit
```

> **Reusable workflow, not a step.** This repository ships a `workflow_call` workflow, so it
> is referenced from a **job** (`jobs.<id>.uses`), not from a step. There is no `action.yml`
> here, so `- uses: owner/actions-s3-cloudfront-deploy@v1.0.0` inside `steps:` will fail.
>
> Building first? Upload your build output with `actions/upload-artifact`, then pass
> `artifact_name` and `artifact_path` — the workflow downloads the artefact instead of
> reading the checkout. See [`examples/caller-deploy.yml`](examples/caller-deploy.yml) for a
> build + deploy pair.

---

## Architecture Guarantees

- **No script injection** — every caller input reaches the shell through an isolated
  step-level `env:` block and is read as data. A `${{ … }}` expression is never interpolated
  into a `run:` body (not even in a comment, where the runner would still expand it), and a
  test fails the build if one reappears.
- **Data safety is tested, not asserted** — the smoke suite executes the *real* `run:` bodies
  extracted from the workflow file against a stubbed AWS CLI, so the guard cannot silently
  drift from the shipped pipeline.
- **Fail-fast verification** — the job aborts *before* mutating S3 if the artefact path is
  missing or empty, or if no role is configured for the OIDC exchange.
- **89 deterministic assertions** — 49 in the provisioning/trust-policy contract test and 40
  in the sync/delete smoke test, plus two repo-wide audit gates (proprietary identifiers, and
  expressions inside `run:` bodies). All offline: no AWS account, no credentials, no network.
- **The pipeline cannot leak its own infrastructure** — an audit gate fails the build if a
  real account id, organisation, hostname or distribution id appears anywhere in the tree,
  and the values it hunts for are supplied from a secret rather than committed.

**The fine print** — trade-offs, the exact AWS CLI filter semantics this relies on, and the
limitations (for example what `--size-only` deliberately ignores) are documented in
[`docs/DEEP-DIVE.md`](docs/DEEP-DIVE.md).

---

## License

MIT © 2026 kenzikenzili-build — see [`LICENSE`](LICENSE).

