#!/usr/bin/env bash
# Print the pinned base image of a product Dockerfile (no network).
#
# Usage: base-image-info.sh DOCKERFILE
# Prints key=value lines (append to "$GITHUB_OUTPUT"):
#   name    debian:bookworm
#   digest  sha256:...
#   ref     debian:bookworm@sha256:...
# The base image must be pinned by digest: `ARG BASE_IMAGE="name:tag@sha256:..."`.
set -euo pipefail

dockerfile="${1:?usage: base-image-info.sh DOCKERFILE}"
ref="$(sed -n 's/^ARG BASE_IMAGE="\{0,1\}\([^" ]*\)"\{0,1\}[[:space:]]*$/\1/p' "$dockerfile" | head -n1)"

if [[ ! "$ref" =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]]; then
  echo "$dockerfile: BASE_IMAGE must be pinned by digest (name:tag@sha256:...), got '${ref}'" >&2
  echo "Run scripts/update-base-images.sh --write" >&2
  exit 1
fi
echo "name=${BASH_REMATCH[1]}"
echo "digest=${BASH_REMATCH[2]}"
echo "ref=${ref}"
