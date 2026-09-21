#!/usr/bin/env bash
# Run a command inside the extras image (extras/Dockerfile.<variant>) with
# the repository mounted at /workspace. This is how CI runs the checks, so a
# check that passes in the dev container passes in CI and vice versa.
#
# Usage: extras-run.sh IMAGE [DOCKER_RUN_OPTIONS...] -- COMMAND [ARGS...]
#
# Runs as root (EXTRAS_USER to change): the workspace on a CI runner is owned
# by a different uid than the image's `vscode` user. The image is a throwaway
# toolbox container; the product image is never run this way.
# Passed through: VULN_FAIL_ON, VULN_IGNORE_UNFIXED, VULN_EXCEPTIONS_FILE, VULN_VARIANT,
# GITHUB_STEP_SUMMARY (file
# is mounted so summaries written inside the container reach the job page).
set -euo pipefail

image="${1:?usage: extras-run.sh IMAGE [DOCKER_RUN_OPTIONS...] -- COMMAND [ARGS...]}"
shift
opts=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
[ "$#" -gt 0 ] || { echo "extras-run.sh: COMMAND required after --" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

args=(
  run --rm
  --user "${EXTRAS_USER:-root}"
  -v "${root}:/workspace"
  -w /workspace
  # Pre-commit hook environments baked into the image.
  -e PRE_COMMIT_HOME=/home/vscode/.cache/pre-commit
  # The mounted workspace is owned by another uid.
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/workspace
  -e VULN_FAIL_ON -e VULN_IGNORE_UNFIXED -e VULN_EXCEPTIONS_FILE -e VULN_VARIANT
)
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  args+=(-v "${GITHUB_STEP_SUMMARY}:${GITHUB_STEP_SUMMARY}" -e GITHUB_STEP_SUMMARY)
fi

exec docker "${args[@]}" "${opts[@]}" "$image" "$@"
