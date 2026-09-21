# Product contract

What a `dev-base` image guarantees to the repositories and devcontainer templates built on it. Anything not listed is
not part of the contract. It is enforced by [`tests/product/smoke.sh`](../tests/product/smoke.sh) (run from the test
image, see [images.md](images.md)); the machine-readable command lists are in
[`dev-base/contract/`](../dev-base/contract).

## Both variants (Debian bookworm, Alpine 3.23)

- **User:** default user `vscode`, non-root, uid 1000 (build arg `USER_UID`), `HOME=/home/vscode`; the image's default
  `USER` is `vscode`.
- **Shell:** `zsh` with oh-my-zsh and the powerlevel10k theme, `~/.p10k.zsh`, the four MesloLGS NF fonts in `~/.fonts`,
  and `~/.local/bin` on PATH via `~/.zshrc`. `~/.gnupg` exists with mode 700.
- **Commands** (work in an interactive zsh as `vscode`): `zsh git curl jq ssh gpg less unzip gcc make claude codex`
  ([`common.txt`](../dev-base/contract/common.txt)).
- **Build info:** `/usr/local/share/dev-base/build-info.json` records the requested and actually installed Claude Code
  and Codex versions and the oh-my-zsh / powerlevel10k revisions.
- **Labels (published images):** `org.opencontainers.image.{source,revision,version,created,base.name,base.digest}` and
  `io.github.ivan-kostko.dev-base.{variant,claude-code-version,codex-version,codex-release-tag,oh-my-zsh-revision,powerlevel10k-revision}`.

## Alpine only

`bash`, `docker` CLI + `docker buildx` + `docker compose`, `rg` (ripgrep, used instead of Claude's bundled one), and
passwordless `sudo` for `vscode` ([`alpine.txt`](../dev-base/contract/alpine.txt)).

## Debian: no Docker CLI

The Debian image does not contain a Docker CLI; the Debian devcontainer gets it from the `docker-outside-of-docker`
feature at container start.

## Explicitly NOT in the product

Repository development, test and scanning tools: `pre-commit`, ShellCheck, Hadolint, actionlint, yamllint, Syft, Grype
([`forbidden.txt`](../dev-base/contract/forbidden.txt)). They live in the extras image.

> **Change:** earlier revisions of the product image shipped `pre-commit` and `shellcheck`. They were moved to the
> extras image, so projects that relied on them being in `dev-base` must install them themselves.

## Changing the contract

Edit the lists in `dev-base/contract/`, this document and the Dockerfiles together; the smoke test fails when they
disagree. `dev-base/` is code-owned.
