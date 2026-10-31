# AITP Delivery Standard

The uniform CI/CD model for every `aitp-*` repository. Where repos legitimately
differ (build toolchain, publish target), that difference is called out and
kept local; everything else is shared here.

## Publish topology

`aitp-rs` is the hub. It publishes via independent, tag-triggered workflows,
each with its own registry credential:

| Package | Workflow (in aitp-rs) | Trigger | Registry | Credential |
|---|---|---|---|---|
| `aitp` crates (13) | `release-plz.yml` | push to `main` | crates.io | `CARGO_REGISTRY_TOKEN` |
| `@agentidentitytrustprotocol/aitp` (NAPI) | `bindings-release.yml` | tag `aitp-node-v*` | npm | `NPM_TOKEN` |
| `aitp-sdk` wheels | `aitp-py-release.yml` | tag `aitp-py-v*` | PyPI | OIDC (no token) |

## Propagation graph

```
                     ┌─ crate (release-plz) ─▶ crates.io   (external use — NO in-org consumer)
aitp-rs publishes ───┼─ npm   (bindings)     ─▶ dispatch ▶ aitp-control-plane → npm re-lock
                     └─ py    (py-release)   ─▶ dispatch ▶ aitp-playground    → uv lock --upgrade
```

Only **two** SDK dispatches are wired: no in-org repo consumes the crates.io
crates, so `release-plz.yml` stays unwired (add a crate consumer → wire it).
Each wired publish job fires `repository_dispatch: aitp-released` (payload
`{version, ecosystem}`) at its consumer using an `aitp-deps-bot` App token.
The consumer's `bump-aitp.yml` calls `bump-consume.yml`. Dependabot's weekly
`aitp-sdk` group is the safety net if a dispatch is ever missed.

Leaves — standardized (CI + auto-merge + Dependabot) but no SDK dependency, so
no `bump-aitp`:

- **aitp-verifier-py**, **aitp-verifier-ts**, **aitp-verifier-go** —
  independent implementations of the verification core (for spec Final
  promotion). Their independence from `aitp-rs` is the point (independent in
  code; all share one author, so none meets the v1.0 different-authorship
  criterion). Each pins the spec in a `SPEC_VERSION` file and bumps it with
  `bump-spec-ref` like aitp-rs. aitp-verifier-ts and aitp-verifier-go also pin
  the aitp-rs conformance runner they test under (`AITP_RS_COMMIT`), bumped by
  the same workflow with `label: aitp-rs`.
- **aitp-ui-console**, **aitp-website** — Vercel deploys.

## Propagation mechanics

Two propagation lanes, both event-driven, both App-authenticated, both with a
Dependabot safety net.

### SDK propagation (a new `aitp` package → its consumers)

1. `aitp-rs` publishes (`bindings-release` npm tag / `aitp-py-release` PyPI tag).
   Each publish job, on a real publish, mints an App token scoped to the
   consumer and POSTs `repository_dispatch: aitp-released` with
   `client_payload {version, ecosystem}`.
   - npm → `aitp-control-plane` (version from the `aitp-node-v*` tag)
   - PyPI → `aitp-playground` (version from the `aitp-py-v*` tag)
2. The consumer's thin `bump-aitp.yml` calls `bump-consume.yml@v1`, which:
   resolves the target, **waits for the registry to actually serve it** (npm CDN
   / PyPI can lag a publish), bumps the manifest + lockfile for the ecosystem
   (`npm` rewrites the dep and any `npm:` alias — control-plane declares
   `"aitp": "npm:@agentidentitytrustprotocol/aitp@^x"`; `uv` runs
   `uv lock --upgrade-package aitp-sdk`), opens a PR, and arms auto-merge
   **unless the bump is breaking** (major, or a `0.x` minor).
   For npm it waits for every optional platform package the SDK pins, not just
   the SDK (they publish one by one, and a re-lock that runs early drops the
   missing ones silently). It re-locks with npm 11, because npm 10 strips every
   `libc` field from the lockfile. Before opening the PR it fails unless the
   lock pins exactly the SDK's published `optionalDependencies`, each with its
   published `os`/`cpu`/`libc` (aitp-ci#6; `tests/bump-consume-npm-lock.sh`).
3. Missed dispatch → Dependabot's weekly `aitp-sdk` group opens the same PR later.

### Spec propagation (a new spec revision → its SHA-pinners)

The spec (`agentidentitytrustprotocol`) is a **dependency pinned by git SHA**.
`aitp-rs` pins it in **`tests/schemas/SPEC_VERSION`** (a plain file, read by
`ci.yml` as `ref:`) — not in a workflow file. `aitp-verifier-py`,
`aitp-verifier-ts` and `aitp-verifier-go` pin it in a root `SPEC_VERSION` file
the same way, and `aitp-docs` pins it in `sources.config.json`.

1. On a conformance-relevant push (`schemas/**`, `docs/**`, `rfcs/**`,
   `registries/**`), the spec repo's `notify-spec-consumers.yml` dispatches
   `repository_dispatch: spec-released {sha}` to each pinner.
2. The pinner's `bump-spec.yml` calls `bump-spec-ref.yml@v1` with
   `mode: file, file: tests/schemas/SPEC_VERSION`, which rewrites the pinned SHA
   and opens a PR that is **never auto-merged** — the PR's own conformance CI
   runs against the new fixtures, and a human adopts the new spec deliberately
   (the pin exists precisely so spec changes never silently alter CI).
   A pinner whose generated files derive from the spec passes `post-bump`, a
   shell command run after the rewrite and before the commit, so the PR lands
   with those files already regenerated.
   Opening a bump PR closes the older open bump PRs for the same `label` whose
   SHA the new one contains, so only the newest stays open. A bump PR for a
   commit that is not behind the new SHA stays open.

## Merge policy

Patch + minor auto-merge on a green pipeline; **majors are held** for a human
(Dependabot majors, and breaking SDK bumps — `major`, or a `minor` while
`0.x` — from `bump-consume`).

## CI baseline

Auto-merge only ships what CI vouches for, so every repo's `main` protection must
require a pipeline that meets this bar. **The principles are uniform; how each
ecosystem satisfies them is not** — do not port one repo's tooling into another
(a Rust repo's gate is clippy, not a TS lint script).

Every repo:

- [ ] **Format** enforced, not advisory — rustfmt / ruff format / prettier
- [ ] **Lint** at zero warnings — clippy `-D warnings` / ruff / eslint `--max-warnings 0`
- [ ] **Type-check** — `tsc --noEmit` / mypy (native to Rust)
- [ ] **Tests + coverage gate** — thresholds enforced in CI, not merely measured
- [ ] **Convention / supply-chain checks** where the repo defines them — e.g.
      aitp-rs `cargo-deny` + `cargo-audit` + `cargo-semver-checks`; control-plane
      `Dependency audit (prod, high+)`

Ships a container image → additionally:

- [ ] **`docker build` (no push) on PRs** — a broken Dockerfile fails at PR time,
      not release time
- [ ] **Boot / smoke before publish** — boot the built image (or run a
      golden-vector / conformance smoke) so an unbootable artifact never reaches
      the registry or a deploy

The jobs satisfying this bar are the **required status checks** on `main`
(configured by `scripts/standardize.sh`), so a red gate blocks the merge and
auto-merge never overrides it. `aitp-rs` exceeds the baseline and keeps its own
richer protection (not clobbered by `standardize.sh`).

`scripts/standardize.sh --check` is the read-only audit: it compares every
repo's live settings and protection (auto-merge, squash, delete-branch, the
exact required-check set, `strict: true`, no admin enforcement, no required
reviews) with `checks_for()` and exits non-zero on any drift. Run it after any
CI job rename; a required check whose job was renamed hangs every PR.

### Go (aitp-verifier-go)

The Go baseline, all in `ci.yml`:

- **Format** — `gofmt -l .` must print nothing.
- **Lint** — `go vet ./...` and staticcheck (run with `go run …@version` as a
  CI tool, never a module dependency).
- **Supply chain** — govulncheck, and the **no-deps rule**: `go list -m all`
  must list only the module itself (JCS, strict JSON and JWS are hand-written).
- **Tests + coverage gate** — `go test` on the floor and current Go (1.26,
  1.27), with coverage of `internal/` gated at ≥ 85%.
- **Conformance** — the adapter under `aitp-conformance` (core: no failed or
  skipped fixture) and an aitp-rs mint → Go verify cross-check.

Required checks: `spec pin + generated files`, `tests (go 1.26)`,
`tests (go 1.27)`, `build aitp-rs tools`, `conformance (aitp-conformance)`,
`mint (aitp-rs) -> verify`. Publishing is the tag: the Go module proxy serves
`vX.Y.Z` tags, so there is no registry credential.

## Credentials

One GitHub App (`aitp-deps-bot`, App ID 4261763), installed org-wide, key stored
once as org secrets `AITP_BOT_APP_ID` / `AITP_BOT_PRIVATE_KEY`. Every cross-repo
dispatch and every bot PR mints a short-lived installation token from it —
**zero PATs**. Registry-publish tokens (`NPM_TOKEN`; PyPI is OIDC) stay in
`aitp-rs`.

App repository permissions:

| Permission | Why |
|---|---|
| Contents: Read/write | commit bump branches; POST `repository_dispatch`; edit `tests/schemas/SPEC_VERSION` |
| Pull requests: Read/write | open the bump PRs |
| Workflows: Read/write | held for the `ref` mode of `bump-spec-ref` (editing under `.github/workflows/`). AITP's spec pin lives in a plain file, so the spec bump does **not** need it — but the App carries it for portability |

`bump-consume` (manifests/lockfiles) and AITP's file-mode spec bump both need
only Contents + Pull requests.

## Repo matrix

| Repo | Lang | CI caller | auto-merge | Dependabot | bump-aitp | Publish | Graph role |
|---|---|---|---|---|---|---|---|
| aitp-rs | Rust | own ci | ✅ | ✅ (SHA pin in file) | — | crate+npm+py+wasm | **hub / sends 2 dispatches** |
| aitp-control-plane | npm | own ci | ✅ | npm+ga | npm | Docker→GHCR | consumes npm |
| aitp-playground | Python/uv | own ci | ✅ | uv+ga | uv (`aitp-sdk`) | Docker→GHCR | consumes py |
| aitp-verifier-py | Python | own ci | ✅ | pip+ga | — | PyPI | independent |
| aitp-verifier-ts | TS | own ci | ✅ | npm+ga | — | npm | independent |
| aitp-verifier-go | Go | own ci | ✅ | ga (no deps) | — | Go module proxy (tag) | independent |
| aitp-ui-console | TS | own ci | ✅ | npm+ga | — | Vercel | leaf |
| aitp-website | MDX | own ci | ✅ | npm+ga | — | Vercel | leaf |
| agentidentitytrustprotocol | Spec | own ci | ✅ | ga | — | release zip | **spec source / sends spec-released** |

## Extending to new SDKs (Java / Go / Kotlin)

Add a `bump-consume` ecosystem branch (`gradle`/`go`/…) and an `aitp-rs`
publish→dispatch step. The consumer repo gets the same thin `bump-aitp.yml`
caller. Nothing else changes.
