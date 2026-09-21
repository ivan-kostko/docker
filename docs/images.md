# Image roles: product / extras / test

Three kinds of image, built by [`docker-bake.hcl`](../docker-bake.hcl). Only the first is a release artifact.

| Role | Dockerfile | Derived from | Contains | Published |
|---|---|---|---|---|
| **Product** | [`dev-base/Dockerfile.{debian,alpine}`](../dev-base) | pinned upstream base (`debian:bookworm`, `alpine:3.23`, by digest) | only the documented [product contract](product-contract.md) | **yes**, `ghcr.io/<owner>/dev-base:<variant>` |
| **Extras** | [`extras/Dockerfile.{debian,alpine}`](../extras) | the product | product + this repository's development tools: `pre-commit`, ShellCheck, yamllint, Hadolint, actionlint, Syft, Grype, and pre-warmed pre-commit hook environments | no |
| **Test** | [`tests/product/Dockerfile.{debian,alpine}`](../tests/product) | the product under test | product + the smoke-test scripts and command contract in `/opt/dev-base-tests`. **No packages, no test framework** | no |

## Boundaries (enforced, not just documented)

1. **CI never installs anything into a product image.** No package, test framework, scanner, linter or temporary tool.
   Anything CI needs goes into the extras image or the test image, which are separate images built *on top of* the
   product. The product smoke test also asserts that `pre-commit shellcheck hadolint actionlint yamllint syft grype`
   are **not** on the product's PATH ([`dev-base/contract/forbidden.txt`](../dev-base/contract/forbidden.txt)).
2. **Extras is the repository's dev/check environment.** Both devcontainers build from it (never from the raw product),
   and CI runs the repository checks in it via [`scripts/extras-run.sh`](../scripts/extras-run.sh), so a check that
   passes in the devcontainer passes in CI. Nothing is downloaded at container start: tools are baked in and every
   pre-commit hook environment is pre-installed.
3. **The test image is the product plus tests, nothing more.** Smoke tests run *from* it, as `vscode`, against the
   unchanged inherited environment (same user, PATH, `~/.zshrc`, files). **An extras image is never used as a stand-in
   for validating the product.**
4. **Only product images are published.** Extras images are development infrastructure, not a supported offering, so
   they are not published. If that ever changes they must get separate names/tags (e.g. `dev-base-extras`) so
   consumers cannot confuse them with the product.

## Building

```sh
docker buildx bake --load              # debian: product, test, extras  (dev-base-{product,test,extras}:debian)
VARIANT=alpine docker buildx bake --load
```

`test` and `extras` are built on the product from the same checkout through named build contexts, so the product built
locally is exactly what gets tested. In CI the product is built for amd64 + arm64. Both platforms are SBOM-generated and
vulnerability-scanned before merge (static analysis, in the unprivileged `verify` job); the smoke test runs on the
runner's native platform (amd64) only, so arm64 binaries are never executed in CI.

The devcontainers build extras on the **published** product (`ghcr.io/ivan-kostko/dev-base:<variant>`), so at least one
publish must exist. To try local `dev-base/` changes in the dev container first:

```sh
docker buildx bake product --set product.tags=ghcr.io/ivan-kostko/dev-base:debian --load
# then "Rebuild Container"
```

## What runs where in CI

| Step | Runs in | Relationship to the product |
|---|---|---|
| `pre-commit run --all-files`, script self-tests | extras (Debian) | none |
| product smoke test | **test** image, `docker run --user vscode` | inherits the product unchanged |
| SBOM + vulnerability scan (PR / verify), **linux/amd64 and linux/arm64** | extras | each platform handed over as an archive mounted read-only: amd64 via `docker save` of the loaded image, arm64 via a Docker-archive export of the QEMU build. Static analysis only; no product binary is executed, nothing is pushed |
| smoke test + SBOM + scan (publish) | test image built on the pushed amd64 digest; extras for scanning both platform digests from the registry | the pushed artifact itself |
