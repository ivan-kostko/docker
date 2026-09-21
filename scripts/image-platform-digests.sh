#!/usr/bin/env bash
# List the per-platform image digests of a pushed multi-platform image.
#
# Usage: image-platform-digests.sh IMAGE@sha256:INDEX_DIGEST
# Prints "<os>/<arch> <digest>" lines. BuildKit attestation manifests
# (platform unknown/unknown) are skipped. A single-platform image prints its
# own digest under the platform reported in its config.
set -euo pipefail

ref="${1:?usage: image-platform-digests.sh IMAGE@sha256:DIGEST}"
raw="$(docker buildx imagetools inspect "$ref" --raw)"

if jq -e '.manifests' >/dev/null 2>&1 <<<"$raw"; then
  jq -r '.manifests[]
         | select(.platform.os != "unknown" and .platform.architecture != "unknown")
         | "\(.platform.os)/\(.platform.architecture) \(.digest)"' <<<"$raw"
else
  echo "error: $ref is not an image index" >&2
  exit 1
fi
