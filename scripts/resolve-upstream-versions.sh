#!/usr/bin/env bash
# Resolve the current "latest" of every accepted-mutable upstream input to an
# explicit version/revision, so a build installs exactly that and records it
# (docs/reproducibility.md). Prints key=value lines (append to "$GITHUB_OUTPUT"):
#   claude_code_version  2.1.278
#   codex_tag            rust-v0.155.1     (GitHub release tag; build input)
#   codex_version        0.155.1           (as `codex --version` reports it)
#   omz_revision         <sha of ohmyzsh/ohmyzsh master>
#   p10k_revision        <sha of romkatv/powerlevel10k HEAD>
# GITHUB_TOKEN, if set, is used for the GitHub API (avoids anonymous rate limits).
set -euo pipefail

# Public reads only; ignore any user git config (e.g. https -> ssh rewrites).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

claude="$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest | tr -d '[:space:]')"
[[ "$claude" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "unexpected Claude Code version: '${claude}'" >&2; exit 1; }

auth=()
[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
codex_tag="$(curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/openai/codex/releases/latest | jq -r .tag_name)"
[[ "$codex_tag" =~ ^rust-v[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "unexpected Codex tag: '${codex_tag}'" >&2; exit 1; }

sha_of() { # sha_of <repo-url> <ref>
  local sha
  sha="$(git ls-remote "$1" "$2" | awk 'NR == 1 { print $1 }')"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "could not resolve $2 of $1" >&2; exit 1; }
  echo "$sha"
}

echo "claude_code_version=${claude}"
echo "codex_tag=${codex_tag}"
echo "codex_version=${codex_tag#rust-v}"
echo "omz_revision=$(sha_of https://github.com/ohmyzsh/ohmyzsh refs/heads/master)"
echo "p10k_revision=$(sha_of https://github.com/romkatv/powerlevel10k HEAD)"
