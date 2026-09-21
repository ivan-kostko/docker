# Reproducibility: pinned and accepted-mutable inputs

Principle: pin what can be pinned cheaply; for what is deliberately mutable, **resolve it to an explicit version at
build time and record it**, so any image can be traced to exact upstream versions. No fake or empty checksum variables
are used anywhere.

## Pinned

| Input | Where | How |
|---|---|---|
| Base images | `ARG BASE_IMAGE` in `dev-base/Dockerfile.*` | `debian:bookworm@sha256:…`, `alpine:3.23@sha256:…` committed in the Dockerfiles (tag kept for readability) |
| Fonts | `ARG P10K_MEDIA_REF` | immutable commit of `romkatv/powerlevel10k-media` (equal to master, untouched since 2023) |
| `p10k.zsh` | `ADD` URL | gist revision hash in the URL |
| Repo tools in extras: Syft, Grype, Hadolint, actionlint | `extras/tools.env` | version + sha256 per architecture, verified at build |
| GitHub Actions | `ci.yml` | full commit SHAs with version comments |
| pre-commit hooks | `.pre-commit-config.yaml` | `rev:` pins |

### Updating base-image digests

```sh
scripts/update-base-images.sh --check    # shows committed vs current digest, exit 1 on drift
scripts/update-base-images.sh --write    # rewrites dev-base/Dockerfile.* to the current digests
```

Review and commit the diff (code-owned). The scheduled workflow runs `--check` and warns on drift. To change the tag
itself (e.g. `alpine:3.23` → `3.24`) edit the `ARG`, then run `--write`. Only official Docker Hub images are supported
(`library/<name>`), which covers debian and alpine. `apt-get upgrade` / `apk upgrade` still run on every build, so OS
package updates arrive without moving the base digest.

Support status when pinned (2026-09-21): Alpine 3.23 is supported until 2027-11-01. Debian bookworm's regular support
ended 2026-07-11; it receives LTS security updates until 2028-06-30.

## Accepted mutable inputs

Each follows upstream on purpose. CI resolves it once per run ([`resolve`](../scripts/resolve-upstream-versions.sh)),
builds exactly that, and records it (below). Local builds without CI simply take upstream latest.

| Input | Follows | Why it stays mutable |
|---|---|---|
| Claude Code (`claude.ai/install.sh`, version = current `latest`) | upstream latest | the dev container's purpose is to ship a current agent CLI; the installer verifies the binary against Anthropic's release manifest. Its bootstrap step always uses the current latest binary |
| Codex CLI (GitHub release `latest`) | upstream latest | same; no signed checksum list is consumed |
| powerlevel10k (`git`, default branch HEAD) | upstream latest | theme should stay current; commit resolved and recorded |
| oh-my-zsh (installer from and clone of `master`) | `master` | no release tags exist; the installer cannot check out a SHA, so CI moves the clone to the resolved `master` commit after install |
| OS packages (`apt-get upgrade`, `apk upgrade`) | distro repos | security updates; the SBOM records the result |
| Docker devcontainer feature `docker-outside-of-docker:1` | floating major | `.devcontainer/debian/devcontainer-lock.json` (currently untracked) pins it by digest; consider committing it |
| Extras base in devcontainers | `ghcr.io/ivan-kostko/dev-base:<variant>` | moving tag by design; CI builds extras on the product from the same checkout instead |

## Recorded

- **OCI labels** on published product images: `org.opencontainers.image.{source,revision,version,created,base.name,base.digest}`
  and `io.github.ivan-kostko.dev-base.{variant,claude-code-version,codex-version,codex-release-tag,oh-my-zsh-revision,powerlevel10k-revision}`.
- **`/usr/local/share/dev-base/build-info.json`** inside every image: requested vs actually installed versions and
  revisions. The smoke test fails if an explicit request does not match what is installed, and (for published images)
  if the labels differ from what is installed.
- **CI artifacts:** `upstream-versions` (resolved versions per run), `<variant>-build-metadata.json` (digests, tags,
  base image, build-info) and the SBOMs (`publish-<variant>-reports`, 90 days).
- **Attestations:** provenance + SBOM on the published digests.

## Drift

The weekly `drift` job compares the published images' labels with what a rebuild would install today and reports the
difference; it never publishes ([ci-cd.md](ci-cd.md#scheduled-builds-and-drift)).
