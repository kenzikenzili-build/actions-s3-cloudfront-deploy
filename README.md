# actions-s3-cloudfront-deploy

**A keyless, data-safe pipeline for shipping static sites to S3 behind CloudFront.**

Two lines of CI configuration replace what is usually a hand-rolled shell script that
runs in production with a long-lived AWS access key:

```yaml
uses: kenzikenzili-build/actions-s3-cloudfront-deploy/.github/workflows/deploy-s3-cloudfront.yml@dev
with:
  s3_bucket: my-site-prod
  role_to_assume: arn:aws:iam::111122223333:role/my-site-prod-deploy-role
```

Everything account-specific — bucket, region, role, distribution — is an **input**.
This repository contains no account ids, no distribution ids, no bucket names and no
organisation names. It is a generic building block, and a test proves it (see
[Verifying this repository](#verifying-this-repository)).

> **Branch policy.** Direct pushes to `main` are blocked by a repository guard, so the
> integration branch is **`dev`** and it is the default branch. Pin consumers to `@dev`
> while integrating; pin a tag or a commit SHA once a release is cut and reviewed.

| Property | How it is achieved |
|---|---|
| **Zero static keys** | The workflow exchanges a GitHub OIDC token for short-lived STS credentials. There is no `AWS_ACCESS_KEY_ID` anywhere in the design. |
| **Secrets cannot leak from this repo** | The repository is default-deny: `.gitignore` blocks credential shapes, and a test fails the build on any identifier or key-shaped string. |
| **`--delete` cannot wipe production data** | `sync_exclude_paths` is appended to the filters of *every* sync pass, and `aws s3 sync --exclude` governs the delete decision as well as the upload. |
| **Browsers never pin a stale shell** | Two-pass upload: fingerprinted assets are immutable for a year, entry points revalidate on every request. |
| **Least privilege, idempotent bootstrap** | `scripts/setup-project-infra.sh` creates one bucket and one OIDC-trust role, scoped to a single repository pattern and one bucket. Re-running it changes nothing. |
| **Auditable** | Both scripts run offline against a stubbed AWS CLI, so the trust policy and permission set they generate can be reviewed in CI without touching an account. |

---

## Table of contents

- [Why this exists](#why-this-exists)
- [1. Security: zero static keys](#1-security-zero-static-keys)
- [2. Data safety: the `--delete` trap](#2-data-safety-the---delete-trap)
- [3. Correctness: two-tier cache control](#3-correctness-two-tier-cache-control)
- [Quick start](#quick-start)
- [Inputs and secrets reference](#inputs-and-secrets-reference)
- [Provisioning AWS (`setup-project-infra.sh`)](#provisioning-aws-setup-project-infrash)
- [Repository layout](#repository-layout)
- [Verifying this repository](#verifying-this-repository)
- [Assumptions and limitations](#assumptions-and-limitations)

---

## Why this exists

A static deploy looks trivial: build, upload, invalidate. In production, the naive
version of that three-step script fails in three distinct and expensive ways, and the
failure is usually blamed on the site rather than on the pipeline.

1. **The credential is the liability.** Uploading from CI "just needs" an access key
   in repository secrets. That key is long-lived, shared by every workflow in the
   repository, and valid until someone remembers to rotate it. A compromised caller
   repository compromises the bucket.
2. **The sync eats live data.** The bucket that serves the site also holds objects the
   site's own backend writes at runtime — a telemetry blob, a JSON feed refreshed by a
   cron job, uploaded assets. The build artefact contains none of them, and
   `aws s3 sync --delete` treats "absent from the source" as "delete from the
   destination". A routine deploy silently removes production data.
3. **One cache header cannot be right for two kinds of file.** A hashed bundle wants
   `immutable`. An HTML entry point wants the opposite — cache it and users stay on the
   old build, or worse, on an old build that references bundles you just deleted.

This repository is the extraction of a pipeline that had to be fixed for all three,
with each fix made explicit, testable and documented rather than living in tribal
knowledge. It is intentionally small: a reusable workflow, a provisioning script, and
the tests that keep them honest.

---

## 1. Security: zero static keys

### The problem with static keys

```
repo secret: AWS_SECRET_ACCESS_KEY  ──valid until rotated──▶  bucket write + invalidation
     │
     └── readable by every workflow in the repository, for years,
         and useless to invalidate without a human doing the rotation
```

### What this pipeline does instead

```
GitHub Actions job
  │  permissions: id-token: write
  ▼
GitHub OIDC issuer ──signed JWT (sub = repo:OWNER/REPO:ref:refs/heads/main)──▶ AWS STS
                                                                                │
                                sts:AssumeRoleWithWebIdentity (trust policy matches sub)
                                                                                ▼
                                        ── temporary credentials, expire with the job ──▶ S3 + CloudFront
```

The token is minted per job and expires with it. There is **nothing to rotate, nothing
to leak and nothing stored at rest**. Even the role ARN travels as a workflow input
rather than a secret, because an ARN is an identifier: it is useless without a token
whose `sub` claim matches the role's trust policy.

### The trust policy is the real security boundary

`scripts/setup-project-infra.sh` writes a trust policy that pins both the audience and
the repository subject, and nothing else:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GitHubActionsOIDC",
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:ref:refs/heads/main" }
      }
    }
  ]
}
```

Three things to note:

- **`aud` is pinned.** Without this condition a token minted for a different audience
  could be replayed at STS.
- **`sub` is scoped to a repository and a ref.** Prefer the exact ref form
  (`ref:refs/heads/main`); a bare `repo:OWNER/REPO:*` trusts every branch, every tag
  and every pull request in that repository. The script accepts the wildcard form but
  warns about it out loud.
- **No `"AWS": "*"`.** Only the federated OIDC principal may assume the role, so the
  granted S3/CloudFront permissions are unreachable with a static key.

### Hardening the supply chain around it

- `permissions: id-token: write` + `contents: read` at workflow level. No
  `contents: write`, so the pipeline cannot push a commit with the credentials it holds.
- The reusable workflow validates its inputs before the destructive step: a missing
  artefact path or an empty output directory fails the job *before* any `--delete` runs.
- `.gitignore` is default-deny for anything credential-shaped, and
  `tests/verify-no-identifiers.sh` fails on AWS access-key shapes
  (`AKIA…` / `ASIA…`), private-key blocks, and hardcoded account ids in ARNs.


---

## 2. Data safety: the `--delete` trap

> **This is the single most important section in this repository.** The mechanism it
> describes is the difference between a deploy being a boring operation and a deploy
> being an incident.

### A bucket usually holds two kinds of object

| Kind | Written by | Present in the build artefact? |
|---|---|---|
| Build output (`index.html`, `assets/*.js`) | the CI build job | ✅ yes |
| Runtime data (`telemetry.json`, `data/*.json`, uploads) | a backend job, a cron job, a Lambda | ❌ no, by design |

Keeping runtime data out of the artefact is correct: a build snapshot must never
overwrite live data with a stale copy. That decision is what sets the trap.

### Why "absent from source" becomes "deleted from production"

`aws s3 sync <dir> s3://<bucket> --delete` makes the destination match the source. For
any destination key that has no counterpart in the source, the source of truth is
"this object should not exist", so it is deleted:

```
build artefact                 S3 bucket after `sync --delete`
──────────────                 ──────────────────────────────
index.html          ─────────▶ index.html          (replaced)
assets/app.9f2.js   ─────────▶ assets/app.9f2.js   (replaced)
                               telemetry.json      ── DELETED ──▶ 403
                               data/macro.json     ── DELETED ──▶ 403
                               data/editorial/…    ── DELETED ──▶ 403
```

The damage is worse than a stale page, because these objects are usually served *by
the same CloudFront distribution as the site*:

- the site starts returning **403 / 404** for paths that third-party clients, monitors
  or embedded widgets poll on a schedule;
- the outage lasts until the writer's next run — minutes for a frequent job, a full day
  for a nightly one;
- if the writer produces a *cumulative* file, the deleted copy may be the only
  consolidated snapshot;
- the deploy goes **green**. Nothing in the pipeline complains. The failure surfaces as
  "the dashboard looks broken", often hours later, on a machine that is not the deploy
  machine.

Observed in practice on this pipeline's ancestor: a routine production release removed a
telemetry object and an entire `data/` prefix within three minutes of the sync, and they
returned only on the next scheduled republish. Staging was unaffected, which is exactly
how the class of bug survives a release process — the environment you validate on is
often the one that sources those objects from a bucket no deploy targets.

### The fix: exclude at the sync level, not the copy level

`aws s3 sync` applies `--exclude` / `--include` filters to **both** the upload decision
and the delete decision. A key matched by an exclusion is therefore *invisible to the
sync*: it is not overwritten, and it is not deleted. That is the property this workflow
relies on.

```
sync_exclude_paths:   data/*        +  telemetry.json
                          │
                          ▼
aws s3 sync ./dist s3://my-site-prod --delete \
    --exclude "data/*" --exclude "telemetry.json"
                          │
        ┌─────────────────┴─────────────────┐
        ▼                                   ▼
   not uploaded                        not deleted
   (live data cannot be                (the object the backend
    overwritten by a stale              wrote survives the deploy)
    build snapshot)
```

### How the guard is plumbed into this workflow

```yaml
      - name: Sync artefacts to S3
        env:
          SYNC_EXCLUDE_PATHS: ${{ inputs.sync_exclude_paths }}
        run: |
          PROTECTED=()
          EXCLUDES=()
          while IFS= read -r pattern; do
            pattern="$(trim "$pattern")"
            if [ -n "$pattern" ]; then
              PROTECTED+=("$pattern")
              EXCLUDES+=(--exclude "$pattern")
            fi
          done <<< "$SYNC_EXCLUDE_PATHS"

          # pass 1 — immutable assets
          aws s3 sync "$ARTIFACT_PATH" "s3://$TARGET_BUCKET" --delete \
            --cache-control "$IMMUTABLE_CACHE_CONTROL" \
            "${IMMUTABLE_EXCLUDES[@]}" "${EXCLUDES[@]}"

          # pass 2 — revalidated entry points
          aws s3 sync "$ARTIFACT_PATH" "s3://$TARGET_BUCKET" --delete \
            --cache-control "$REVALIDATE_CACHE_CONTROL" \
            "${REVALIDATE_INCLUDES[@]}" "${EXCLUDES[@]}"
```

Two details matter for anyone reviewing this:

1. **`"${EXCLUDES[@]}"` is appended to every pass.** Both passes run with `--delete`,
   so a guard attached to only one of them would still lose the data. Any future pass
   added to this step must repeat the same array.
2. **It comes last.** `aws s3 sync` evaluates filters left to right and the **last
   match wins**, so appending the exclusions after the cache-tier filters guarantees a
   protected prefix stays protected even if a tier pattern would have included it.

### Using it

```yaml
      sync_exclude_paths: |
        data/*
        telemetry.json
        uploads/*
```

Rules of thumb:

- **Copy the list from the writer, not from the artefact.** Enumerate the prefixes
  whose contents are produced by something other than your build.
- **Prefer directory patterns** (`data/*`) over naming a single file; a writer that adds
  a sibling file tomorrow is already covered.
- **Leave it empty only if you are certain** the bucket is build output only. The
  workflow emits a run warning and a summary note when the guard is absent, precisely so
  that the choice is visible in the run log instead of implicit.
- **The default is deliberately backwards compatible**: no `sync_exclude_paths` means
  the historic bare-`--delete` behaviour, so adopting this workflow does not silently
  change what an existing pipeline does.


---

## 3. Correctness: two-tier cache control

One `Cache-Control` header cannot be correct for every file in a static build, so a
single-pass sync always picks a failure mode:

| Choice | Consequence |
|---|---|
| `max-age=31536000, immutable` for everything | The HTML entry point is cached for a year. Users keep the old shell, or an old shell that references bundle hashes you have since replaced. |
| `no-cache` for everything | Every navigation re-validates every hashed asset. You pay full CDN/egress for content that is content-addressed and can never change. |

The workflow therefore uploads in two passes, both with `--delete`:

| Pass | Selection | Default `Cache-Control` | Rationale |
|---|---|---|---|
| 1 — immutable | everything *except* `immutable_exclude_patterns` | `public, max-age=31536000, immutable` | filenames contain a content hash, so the bytes behind a URL never change |
| 2 — revalidated | `revalidate_include_patterns` | `no-cache, no-store, must-revalidate` | the entry point must be re-fetched on every deploy, and service workers in particular must never be pinned |

Defaults for the entry-point list: `*.html`, `*.xml`, `*.webmanifest`, `manifest.json`,
`sw.js`, `service-worker.js`.

Because the two passes use complementary filters and both filters apply to the delete
decision, neither pass can delete the other's objects. Set
`tiered_cache_control: false` to get the single-pass legacy behaviour (for example when
an S3/CloudFront policy already sets the headers).

> The service-worker and manifest entries are not decoration: a stale service worker
> pinned in a browser cache is a **remote kill switch you can no longer flip**. It must
> always be uploaded as revalidated.

---

## Quick start

### 1. Provision the target (once per environment)

```bash
./scripts/setup-project-infra.sh \
  --bucket my-site-prod \
  --region us-east-1 \
  --repo-pattern 'repo:OWNER/REPO:ref:refs/heads/main' \
  --cloudfront-distribution-id EXXXXXXXXXXXXX
```

The script prints the role ARN to use in the caller workflow. Inspect what it will do
first with `--dry-run`. Full reference: [below](#provisioning-aws-setup-project-infrash).

### 2. Call the workflow

Copy [`examples/caller-deploy.yml`](examples/caller-deploy.yml) into
`.github/workflows/deploy.yml` of the site repository and fill in five values: the
artefact name/path, the bucket, the region, the role ARN and the distribution id.

```yaml
name: Deploy
on:
  push:
    branches: [main]

permissions:
  id-token: write   # required for the keyless OIDC exchange
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci && npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: site-dist
          path: ./dist
          retention-days: 1

  deploy:
    needs: build
    uses: kenzikenzili-build/actions-s3-cloudfront-deploy/.github/workflows/deploy-s3-cloudfront.yml@dev
    with:
      artifact_name: site-dist
      artifact_path: ./dist
      s3_bucket: my-site-prod
      aws_region: us-east-1
      role_to_assume: arn:aws:iam::111122223333:role/my-site-prod-deploy-role
      cloudfront_distribution_id: EXXXXXXXXXXXXX
      sync_exclude_paths: |
        data/*
        telemetry.json
    secrets: inherit
```

That is the whole integration. `id-token: write` on the calling job is the only
permission the deploy needs to reach AWS.

---

## Inputs and secrets reference

### `workflow_call` inputs

| Input | Required | Default | Purpose |
|---|---|---|---|
| `s3_bucket` | ✅ | — | Bucket that receives the artefacts. |
| `artifact_path` | | `./dist` | Directory to sync, relative to the workspace. |
| `artifact_name` | | `""` | When set, download this Actions artifact into `artifact_path` instead of using the checked-out repo. |
| `cloudfront_distribution_id` | | `""` | When set, invalidate the cache after the sync; when empty the step is skipped. |
| `invalidation_paths` | | `/*` | One path per line. |
| `role_to_assume` | | `""` | IAM role ARN for the OIDC exchange. Required unless the `AWS_ROLE_ARN` secret is provided. |
| `aws_region` | | `us-east-1` | Region of the bucket. |
| `sync_exclude_paths` | | `""` | **Data-safety guard.** One exclusion pattern per line; protected from upload *and* delete in every pass. |
| `tiered_cache_control` | | `true` | Two-pass upload with per-tier `Cache-Control`. |
| `immutable_cache_control` | | `public, max-age=31536000, immutable` | Header for pass 1. |
| `revalidate_cache_control` | | `no-cache, no-store, must-revalidate` | Header for pass 2. |
| `immutable_exclude_patterns` | | `*.html`, `*.xml`, `*.webmanifest`, `manifest.json`, `sw.js`, `service-worker.js` | Excluded from the immutable pass. |
| `revalidate_include_patterns` | | same list | Included in the revalidating pass. Keep the two lists aligned. |

### `workflow_call` secrets

| Secret | Required | Purpose |
|---|---|---|
| `AWS_ROLE_ARN` | | Optional fallback for `role_to_assume`. Prefer the input: a role ARN is an identifier, not a credential, and an input makes the trust boundary readable in the run log. |

No other secret is consumed. In particular this workflow never accepts an access key
id or a secret access key: if you have one, the correct fix is to stop using it.


---

## Provisioning AWS (`setup-project-infra.sh`)

`scripts/setup-project-infra.sh` creates the three things the workflow needs, and
nothing else.

### Usage

```
setup-project-infra.sh --bucket <name> --repo-pattern <pattern> [options]
```

| Flag | Required | Description |
|---|---|---|
| `--bucket <name>` | ✅ | Bucket to create/reuse. Created only if `head-bucket` says it is absent. |
| `--repo-pattern <pattern>` | ✅ | Trust-policy `sub` pattern, e.g. `repo:OWNER/REPO:ref:refs/heads/main`. |
| `--repo <owner/repo>` | | Shorthand for `--repo-pattern "repo:<owner>/<repo>:*"`. |
| `--region <region>` | | Default: `$AWS_REGION`, `$AWS_DEFAULT_REGION`, then `us-east-1`. |
| `--role-name <name>` | | Default `<bucket>-deploy-role`. Must be ≤ 64 characters (IAM limit); the script fails fast rather than truncating. |
| `--policy-name <name>` | | Default `<role-name>-policy`. |
| `--cloudfront-distribution-id <id>` | | Repeatable. Scopes `cloudfront:CreateInvalidation` to that distribution's ARN. |
| `--no-cloudfront` | | Omit the CloudFront statement entirely (site not behind CloudFront). |
| `--create-oidc-provider` | | Create the account-level GitHub OIDC provider if absent. Opt-in, because it is shared account infrastructure. |
| `--block-public-access` | | Apply the S3 Block Public Access configuration. |
| `--dry-run` | | Print the plan and the generated IAM payloads; change nothing. |

### What it creates

| Resource | Name | Notes |
|---|---|---|
| S3 bucket | `--bucket` | Region-correct creation (`LocationConstraint` omitted for `us-east-1`, where AWS rejects it). |
| IAM role | `--role-name` | Trust policy allows **only** the OIDC federated principal, with pinned `aud` and your `sub` pattern. |
| Inline policy | `--policy-name` | `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject` on **one** bucket and its objects; `cloudfront:CreateInvalidation` on the distributions you name. |

### Idempotency

Every operation is *create-if-absent, reconcile-if-present*:

```
head-bucket     → present ? leave alone : create
get-role        → present ? update-assume-role-policy : create-role
put-role-policy → always overwrite the document (AWS upserts it)
```

Running the script twice produces the same end state; the second run mutates nothing.
That makes it safe to keep in a bootstrap script, a runbook or a scheduled drift check.
`tests/smoke-infra-dryrun.sh` asserts the reconcile path against a stubbed AWS CLI.

### Least privilege, stated honestly

- The S3 statement is scoped to a single bucket ARN pair — the role cannot read another
  project's bucket.
- CloudFront invalidation is scoped to the distribution ARNs you pass. If you pass
  none, the script grants it on `*` and **prints that fact in the plan and the
  summary**, rather than pretending the policy is tight. Pass the ids.
- The OIDC provider is never created implicitly: it is account-wide infrastructure, so
  the script stops and tells you to opt in with `--create-oidc-provider`.
- `--dry-run` prints both generated policies and performs no mutating call. The smoke
  test fails the build if a mutating call slips into dry-run.

### Example

```console
$ ./scripts/setup-project-infra.sh --bucket octo-site-prod --region eu-west-1 \
    --repo-pattern 'repo:octo-org/octo-site:ref:refs/heads/main' \
    --cloudfront-distribution-id ABCD1234EFGH --dry-run

=== Provisioning plan ===
  AWS account  : 111122223333  (arn:aws:iam::111122223333:user/ci-provisioner)
  Region       : eu-west-1
  S3 bucket    : octo-site-prod
  IAM role     : octo-site-prod-deploy-role
  IAM policy   : octo-site-prod-deploy-role-policy (inline)
  OIDC provider: arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com
  Trust sub    : repo:octo-org/octo-site:ref:refs/heads/main
  CloudFront   : ABCD1234EFGH (invalidation scoped to these distributions)
  Mode         : DRY RUN — nothing will be created or modified
```


---

## Repository layout

```
.github/workflows/
  deploy-s3-cloudfront.yml   the reusable workflow (workflow_call)
  validate.yml               CI: identifier audit, syntax, offline smoke tests
scripts/
  setup-project-infra.sh     idempotent, least-privilege AWS bootstrap
examples/
  caller-deploy.yml          minimal caller workflow to copy
tests/
  verify-no-identifiers.sh   fails on any proprietary identifier or key shape
  smoke-infra-dryrun.sh      offline contract test (stubbed AWS CLI, dry-run only)
  smoke-workflow-sync.sh     executes the real sync step; proves the guard reaches
                             every pass, last in the filter list
```

---

## Verifying this repository

Everything below runs offline. No command in this repository needs AWS credentials, and
the tests deliberately avoid them.

```bash
tests/verify-no-identifiers.sh   # no proprietary identifiers, no credential shapes
tests/smoke-infra-dryrun.sh      # trust policy + least privilege + dry-run mutates nothing
tests/smoke-workflow-sync.sh     # the data-safety guard reaches every sync pass
```

Expected:

```
verify-no-identifiers: ✅ clean — no proprietary identifiers, no credential shapes.
smoke-infra-dryrun: 30 passed, 0 failed
smoke-workflow-sync: 28 passed, 0 failed
```

`verify-no-identifiers.sh` inspects **tracked** files and fails on:

- hardcoded account ids (in ARNs or bare), distribution ids, bucket names and
  organisation names that belong to a specific deployment;
- AWS access-key shapes (`AKIA…`, `ASIA…`, `AROA…`, `AIDA…`) and private-key blocks.

Documentation placeholders (`000000000000`, `111122223333`, `123456789012`, `EXAMPLE`,
`PLACEHOLDER`, …) are allowlisted so the README and examples stay realistic. The scanner
is excluded from its own scan — it necessarily contains the literals it hunts for — and
it is negative-controlled: introducing an account id and an organisation name into a
tracked file makes it exit non-zero and print the offending file and line.

`smoke-infra-dryrun.sh` injects a stub `aws` binary into `PATH` which answers the
read-only calls (`sts get-caller-identity`,
`iam list-open-id-connect-providers`, `s3api head-bucket`, `iam get-role`) and logs
every invocation. It then asserts:

- the trust policy names the OIDC provider, pins `aud`, and carries exactly the
  requested `sub` pattern — with no static principal;
- the deploy policy is scoped to one bucket plus the named distributions and parses as
  JSON;
- the reconcile path is taken when the bucket and role already exist;
- **no mutating AWS call occurs in dry-run**;
- malformed input (`--bucket` missing or invalid, a bad `--repo-pattern`, an unknown
  flag) fails before any AWS call is reached.

`smoke-workflow-sync.sh` reads the `run:` bodies of the sync and invalidation steps
**out of the workflow file itself** and executes them against a stub `aws`, so the
assertions cannot drift from the shipped pipeline. It proves that:

- the exclusion array is passed to **every** sync pass (a guard attached to one pass
  only would still lose the data);
- the exclusions come *after* the cache-tier filters, so the last-match rule keeps them
  in force;
- each pass carries the expected `--cache-control` header and `--delete`;
- `tiered_cache_control: false` collapses to a single pass that still honours the guard;
- invalidations pass the distribution id and each path as separate arguments, and empty
  paths fall back to `/*`.

`.github/workflows/validate.yml` runs all three suites plus shell syntax checks and YAML
parsing on every push and pull request.

---

## Assumptions and limitations

Stated plainly, so the next reader does not have to discover them:

- **The workflow uploads; it does not build.** Callers own their toolchain. This keeps
  the reusable unit language-agnostic.
- **`sync_exclude_paths` is maintained by hand.** The pipeline cannot know which object
  prefixes a runtime writer owns. An unlisted prefix is still deletable; the workflow
  warns when the list is empty, but it cannot warn about a missing entry.
- **CloudFront invalidation is optional and additive.** Origins, behaviours, OAC/OAI,
  custom domains and certificate wiring are out of scope: this repository deploys
  objects and invalidates a distribution that already exists.
- **Tiered caching assumes content-hashed filenames.** If your bundler emits stable
  filenames, immutable caching is wrong for those files — extend
  `immutable_exclude_patterns` accordingly.
- **`revalidate_include_patterns` and `immutable_exclude_patterns` must stay aligned.**
  They describe the same set of entry points from two directions. Diverging them means
  an entry point is uploaded in neither pass (and therefore deleted by one of them) or
  in both (and the later header wins).
- **No CloudFront function / viewer-request rewriting.** Clean-URL rewrites, SPA
  fallbacks and redirect rules belong to the distribution configuration, not to an
  uploader.
- **The provisioning script manages the bucket and the role only.** It does not create
  the distribution, DNS records or certificates.
- **No licence file yet.** The repository is private. Add an explicit licence before any
  wider distribution.

### Provenance

Extracted from a private internal CI/CD monorepo pipeline. Every account id,
distribution id, bucket name, organisation name and internal repository reference was
removed and replaced with an input or an argument; the identifier audit in
`tests/verify-no-identifiers.sh` exists to keep it that way.

The behavioural differentiators were preserved deliberately and are documented above:
keyless OIDC authentication, the `sync_exclude_paths` data-loss guard, two-tier cache
control, and CloudFront invalidation.

