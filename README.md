# aitp-ci

Shared CI/CD building blocks for the **aitp-\*** repositories — one place to
define how the whole org builds, propagates dependencies, and ships, so every
repo stays uniform instead of drifting.

## What's here

| Reusable workflow | Purpose |
|---|---|
| [`.github/workflows/auto-merge.yml`](.github/workflows/auto-merge.yml) | Auto-merge Dependabot PRs once required checks pass. Patch + minor unattended; **majors held** for review. |
| [`.github/workflows/bump-consume.yml`](.github/workflows/bump-consume.yml) | Consume a new `aitp` SDK release: resolve → wait for registry → bump manifest + lockfile → PR → arm auto-merge. Ecosystems: `npm`, `cargo`, `uv`. |
| [`.github/workflows/bump-spec-ref.yml`](.github/workflows/bump-spec-ref.yml) | Bump a pinned spec SHA (in a workflow `ref:` — `mode: ref`, or a plain pin file like `tests/schemas/SPEC_VERSION` — `mode: file`) and open a **held** PR. |

| Script | Purpose |
|---|---|
| [`scripts/standardize.sh`](scripts/standardize.sh) | Apply uniform branch protection + `allow_auto_merge` + required checks to every repo. |

See **[DELIVERY-STANDARD.md](DELIVERY-STANDARD.md)** for the full model
(dependency-propagation graph, credential design, rollout).

## How a repo uses it

`auto-merge` — commit `.github/workflows/auto-merge.yml`:

```yaml
name: auto-merge
on: pull_request
permissions: { contents: write, pull-requests: write }
jobs:
  call:
    uses: agentidentitytrustprotocol/aitp-ci/.github/workflows/auto-merge.yml@v1
```

`bump-aitp` (consumers only) — commit `.github/workflows/bump-aitp.yml`:

```yaml
name: bump aitp
on:
  repository_dispatch: { types: [aitp-released] }
  workflow_dispatch:   { inputs: { version: { required: false, default: '' } } }
jobs:
  bump:
    uses: agentidentitytrustprotocol/aitp-ci/.github/workflows/bump-consume.yml@v1
    with:  { ecosystem: npm, package: '@agentidentitytrustprotocol/aitp' }  # uv + aitp-sdk for playground
    secrets: inherit
```

## Credentials

The **only** cross-repo credential is the `aitp-deps-bot` GitHub App, stored
once as org secrets `AITP_BOT_APP_ID` / `AITP_BOT_PRIVATE_KEY`. Workflows mint a
short-lived installation token via `actions/create-github-app-token`. No PATs.
Registry-publish tokens (`NPM_TOKEN`; PyPI is OIDC) live in `aitp-rs` and are a
separate concern.

## Conventions

- Third-party actions are **SHA-pinned**; first-party `actions/*` use major tags.
- Pin callers to a release tag (`@v1`), not `@main`.
