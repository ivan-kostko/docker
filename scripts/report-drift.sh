#!/usr/bin/env bash
# Report drift between what is currently published for a variant and what an
# upstream-latest rebuild would contain. Reporting only: it never publishes.
# Publishing a refreshed image is a deliberate release (docs/ci-cd.md).
#
# Usage: report-drift.sh VARIANT
# Environment:
#   IMAGE                 ghcr.io/<owner>/dev-base  (published image name)
#   CLAUDE_CODE_VERSION, CODEX_VERSION (numeric, as `codex --version`),
#   OMZ_REVISION, P10K_REVISION   resolved upstream values
#                         (scripts/resolve-upstream-versions.sh)
#   BASE_DIGEST           digest committed in dev-base/Dockerfile.<variant>
#   DRIFT_FAIL            "1": exit 1 when drift is found (default: exit 0)
#   PUBLISHED_LABELS_FILE JSON object of image labels; skips the registry lookup
#                         (used by tests)
# Writes a Markdown table to $GITHUB_STEP_SUMMARY when set, ::warning:: lines
# for each drifted input.
set -euo pipefail

variant="${1:?usage: report-drift.sh VARIANT}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix="io.github.ivan-kostko.dev-base"

if [ -n "${PUBLISHED_LABELS_FILE:-}" ]; then
  labels="$(cat "$PUBLISHED_LABELS_FILE")"
else
  ref="${IMAGE:?IMAGE required}:${variant}"
  if ! index="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null)"; then
    echo "::notice::${ref} is not published yet; nothing to compare"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "### Drift ${variant}: ${ref} not published yet" >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
  amd64="$("${here}/image-platform-digests.sh" "${IMAGE}@${index}" | awk '$1 == "linux/amd64" { print $2 }')"
  labels="$(docker buildx imagetools inspect "${IMAGE}@${amd64}" --format '{{json .Image}}' \
    | jq -c '(.config // .Config // {}).Labels // {}')"
fi

drifted=0
rows=""
compare() { # compare <name> <published> <upstream>
  local status="same"
  if [ -z "$2" ]; then status="unknown (no label)"; drifted=1
  elif [ "$2" != "$3" ]; then status="DRIFT"; drifted=1; echo "::warning title=Upstream drift (${variant})::$1 published ${2}, upstream now ${3}"
  fi
  rows+="| $1 | ${2:--} | $3 | ${status} |"$'\n'
}
lab() { jq -r --arg k "$1" '.[$k] // ""' <<<"$labels"; }

compare "Claude Code"    "$(lab "${prefix}.claude-code-version")"    "${CLAUDE_CODE_VERSION:?}"
compare "Codex"          "$(lab "${prefix}.codex-version")"          "${CODEX_VERSION:?}"
compare "oh-my-zsh"      "$(lab "${prefix}.oh-my-zsh-revision")"     "${OMZ_REVISION:?}"
compare "powerlevel10k"  "$(lab "${prefix}.powerlevel10k-revision")" "${P10K_REVISION:?}"
compare "Base image"     "$(lab org.opencontainers.image.base.digest)" "${BASE_DIGEST:?}"

table="### Upstream drift: ${variant}"$'\n\n'"| Input | Published | Upstream now | Status |"$'\n'"|---|---|---|---|"$'\n'"${rows}"
printf '%s\n' "$table"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$table" >> "$GITHUB_STEP_SUMMARY"

if [ "$drifted" = 1 ]; then
  echo "Drift found. Run a release (workflow_dispatch with publish) to roll the tags forward."
  [ "${DRIFT_FAIL:-}" != 1 ] || exit 1
fi
