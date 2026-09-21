# Devcontainer policy and local-development trust boundaries

`.devcontainer/*/devcontainer.json` files decide what code inside the dev container can reach on the developer's
machine. [`scripts/check-devcontainer-policy.py`](../scripts/check-devcontainer-policy.py) runs in pre-commit (and
therefore in the CI `policy` job) and **fails** when such a file contains a setting that is not recorded, with a
reason, in [`.devcontainer/policy-allowlist.json`](../.devcontainer/policy-allowlist.json). Both paths are code-owned,
so widening a boundary needs a reviewed change to the allowlist.

## What is checked (default deny)

| Rule | Triggered by | Why it matters |
|---|---|---|
| `mount` | every entry of `mounts` (SSH, GPG, Docker socket, cloud credentials are labelled *sensitive* in the message) | exposes host files to everything in the container |
| `run-arg` | every `runArgs` entry, e.g. `--privileged`, `--security-opt seccomp=unconfined`, `--cap-add`, `--device`, host namespaces | weakens container isolation |
| `build-option` | `build.options` | raw `docker build` flags |
| `security-opt`, `cap-add`, `privileged` | the corresponding properties | same as above |
| `feature` | every entry of `features` (e.g. `docker-outside-of-docker`, `docker-in-docker`) | features can add mounts, privileges and packages |
| `host-command` | `initializeCommand` | runs on the **host**, outside the container |
| `compose` | `dockerComposeFile` | arbitrary service definitions |
| `docker-socket` | any string mentioning `docker.sock` / `DOCKER_HOST` | Docker daemon access = root on the host |
| `root-user` | `containerUser` / `remoteUser` = root | |

Allowlist entries match on file + rule + exact value. Entries that no longer match anything **also fail**, so the
list cannot go stale. Adding an entry requires a `reason`.

## Currently allowlisted (all local-development trust boundaries)

The dev container is meant for your own code on your own machine. **Do not open untrusted code in it**: everything
running inside can use these.

| Setting | Files | What it exposes |
|---|---|---|
| mount `~/.ssh` | alpine, debian | all SSH private keys |
| mount `~/.gnupg` | alpine, debian | GPG secret keyring, read-write (commit/tag signing) |
| mount `.devcontainer/.zsh_history` | alpine, debian | shell history (may contain pasted secrets); git-ignored |
| mount `~/.claude`, `~/.claude.json` | alpine, debian | Claude Code config and login state |
| `--security-opt seccomp=unconfined` | alpine, debian | no syscall filtering; larger container-escape surface. Candidate for removal |
| `initializeCommand` (`mkdir -p ~/.ssh ~/.claude && touch ~/.claude.json`) | alpine, debian | runs on the host; only creates paths the mounts need |
| feature `docker-outside-of-docker:1` | debian | host Docker daemon access, equivalent to root on the host |

The Alpine image installs `docker-cli`/`buildx` but has no feature and no socket mount, so it cannot reach a daemon
unless one is added, which would need an allowlist entry.

## Adding or changing a setting

1. Make the change in `devcontainer.json`.
2. Add/adjust the entry in `policy-allowlist.json` with a reason that names the exposure.
3. Run `pre-commit run devcontainer-policy --all-files` (or `python3 scripts/check-devcontainer-policy.py`).
4. A code owner reviews both files together.
