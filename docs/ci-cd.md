# CI/CD

Workflow: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Helper logic lives in
[`scripts/`](../scripts) so it can be run and tested locally. Image roles (product / extras / test):
[images.md](images.md).

## Jobs

| Job | Runs on | Token permissions | What it does |
|---|---|---|---|
| `resolve` | every event | `contents: read` | resolves Claude Code, Codex, powerlevel10k and oh-my-zsh "latest" to explicit versions/revisions, once per run (artifact `upstream-versions`) |
| `policy` | every event | `contents: read` | in the **extras** image: `pre-commit run --all-files` (actionlint, yamllint, ShellCheck, Hadolint, private-key and secret detection, whitespace/EOF/line-ending fixers, GitHub workflow + Dependabot schema checks, devcontainer policy) and the script self-tests |
| `verify` (debian, alpine) | every event | `contents: read` | build product (amd64 + arm64), build test + extras images on it, smoke-test the amd64 product via the **test** image, SBOM + vulnerability scan of **both** amd64 and arm64, upload per-platform reports |
| `publish` (debian, alpine) | trusted events only | `contents: read`, `packages`/`id-token`/`attestations`/`security-events: write` | push product by digest, repeat smoke test + scan on the pushed digests, attest, then tag |
| `drift` (debian, alpine) | schedule / manual | `contents: read`, `packages: read` | report upstream drift vs the published images; never publishes |
| `gate` | every event | none | one stable status check (`CI gate`) for branch protection |

Pull requests run `resolve`, `policy`, `verify` and `gate` with a read-only token; they never reach `publish`.
`publish` runs for: a push to the default branch, a `v*.*.*` tag push, or a manual run with `publish: true` on the
default branch or a `v*` tag. It runs in the `production` environment ([GitHub-side settings](github-settings.md)).
**The weekly schedule does not publish** (see [Scheduled builds](#scheduled-builds-and-drift)).

There is no `paths:` filter on `pull_request`: a required check skipped by a path filter never reports and blocks
merging. Every PR runs the full validation, including changes to `dev-base/`, `.devcontainer/`, `extras/`, `tests/`,
`.github/`, `.pre-commit-config.yaml`, `scripts/` and root config.

Local pre-commit is optional (`pre-commit install`, done by the devcontainer); CI does not depend on it.

## Release flow (publish)

Product images are pushed **by digest without tags**, then re-validated, and only then tagged:

1. build + push the untagged multi-platform product (layers come from the cache `verify` just filled)
2. build a test image **on the pushed amd64 digest**; run the product smoke test, including that the OCI labels equal
   what `build-info.json` says is installed and that `revision` is this commit
3. SBOM + vulnerability scan of both pushed platform digests; the threshold blocks here
4. upload reports, build metadata (artifact) and SARIF (code scanning, best effort)
5. attest (mandatory): build provenance on the index digest, SBOM on each platform digest (`push-to-registry`)
6. apply tags with `docker buildx imagetools create` (same names and rules as before)

If any step fails no tag moves; at worst an untagged, unreferenced digest is left in GHCR. Tags: `:debian`,
`:debian-YYYYMMDD`, `:debian-X.Y.Z`, `:debian-X.Y`, `:debian-sha-<sha>`, `:latest` (Debian), and the same for `alpine`.
Only product images are published; extras images are not.

## Scheduled builds and drift

Claude Code, Codex, powerlevel10k and oh-my-zsh follow upstream ([reproducibility.md](reproducibility.md)), so new
upstream releases silently change what a rebuild contains. To keep that from reaching consumers without a decision:

- The weekly run builds fresh (no cache) and scans, so new OS packages and vulnerabilities show up as a red/green run.
- `drift` compares the *published* images' labels with the versions resolved now (Claude Code, Codex, oh-my-zsh,
  powerlevel10k, pinned base digest) and prints a table in the run summary plus a `::warning::` per drifted input.
  `scripts/update-base-images.sh --check` additionally reports newer base-image digests.
- Nothing is published. To roll the rolling tags forward, run a release: merge to the default branch, push a release
  tag, or trigger the workflow manually with `publish: true` - each passes the same gate (smoke test, SBOM, scan,
  attestations) and the `production` environment approval.

Behaviour change: the weekly run used to republish the rolling tags automatically.

## Vulnerability release threshold

Scanner: [Syft](https://github.com/anchore/syft) SBOM, [Grype](https://github.com/anchore/grype) scan of that SBOM,
both from the extras image at the versions pinned in `extras/tools.env`; the Grype vulnerability DB is intentionally
fresh on every run.

| Setting | Values | Default | Meaning |
|---|---|---|---|
| `VULN_FAIL_ON` | `none`, `critical`, `high` | `critical` | `critical`: block on Critical, report High as a warning. `high`: block on both. `none`: report only |
| `VULN_IGNORE_UNFIXED` | `true`, `false` | `false` | `true`: findings with no available fix never block (still reported) |

Set them as repository variables (Settings → Secrets and variables → Actions → Variables); no code change needed. The
same threshold applies to `verify` (a PR sees what publish would do) and to `publish`. Plan: start with `critical`, move
to `high` once the High backlog is understood. If an unfixable upstream Critical blocks everything, set
`VULN_IGNORE_UNFIXED=true` (preferred) or, temporarily, `VULN_FAIL_ON=none`.
Logic: [`scripts/check-vuln-threshold.sh`](../scripts/check-vuln-threshold.sh) (tested by `scripts/tests/`).

Coverage: **both linux/amd64 and linux/arm64** are scanned in `verify` (before merge, read-only token, no registry login,
nothing pushed) with the same threshold, so a Critical in either platform fails `verify` and therefore the `CI gate`. In
`verify` each platform is exported as a Docker archive and scanned from the extras image; in `publish` the pushed
digests are scanned from the registry.

Outputs per image and platform: `sbom.spdx.json`, `sbom.syft.json`, `grype.json`, `grype.sarif`.
- Workflow artifacts: `verify-<variant>-reports` (14 days; `<variant>-amd64/` and `<variant>-arm64/` subdirectories), `publish-<variant>-reports` (90 days, includes
  `<variant>-build-metadata.json`), `upstream-versions` (90 days).
- SARIF is uploaded to code scanning from `publish` only (needs `security-events: write`, which PR jobs must not have).
  It is best effort: it needs code scanning to be available for the repository.

## Product smoke tests

Run from the test image ([images.md](images.md)) as the non-root `vscode` user, in an interactive `zsh`:
[`tests/product/smoke.sh`](../tests/product/smoke.sh), driven by
[`scripts/run-product-smoke.sh`](../scripts/run-product-smoke.sh). It checks the [product contract](product-contract.md):
identity, the command lists, the absence of repo dev tools, shell setup, and `build-info.json`.

Known constraint: **native platform only.** The runner is linux/amd64, so smoke tests run there. arm64 is built (QEMU),
SBOM-scanned before merge and again on the pushed digest at publish, but its binaries are never executed in CI. (Scanning
is static analysis of an exported archive and needs no emulation.) Native arm64 runners
(`ubuntu-24.04-arm`) would remove the gap at the cost of restructuring the multi-platform publish.

## Attestations

Every published index has a build-provenance attestation; every platform image has an SPDX SBOM attestation.

```sh
# provenance (index digest / any tag)
gh attestation verify oci://ghcr.io/<owner>/dev-base:debian --owner <owner>
# SBOM of one platform image: get its digest, then verify the SPDX predicate
docker buildx imagetools inspect ghcr.io/<owner>/dev-base:debian
gh attestation verify oci://ghcr.io/<owner>/dev-base@sha256:<platform-digest> \
  --owner <owner> --predicate-type https://spdx.dev/Document/v2.3
```
