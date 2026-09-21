#!/usr/bin/env bash
# Generate an SBOM for an image, scan it for vulnerabilities and apply the
# release threshold (see check-vuln-threshold.sh).
#
# Usage: scan-image.sh SOURCE OUT_DIR [PLATFORM] [LABEL]
#   SOURCE    a Syft source, e.g. docker:dev-base:pr-debian (local daemon) or
#             registry:ghcr.io/owner/dev-base@sha256:... (pushed digest)
#   OUT_DIR   receives sbom.spdx.json, sbom.syft.json, grype.json, grype.sarif
#   PLATFORM  e.g. linux/arm64 (needed to pick one manifest of an index)
#   LABEL     name used in messages (default: SOURCE)
# Tools: $SYFT / $GRYPE (paths; the dev image has both on PATH, so these are
# only needed to override) or `syft` / `grype` from PATH.
#
# Reports are always written before the threshold is evaluated, so they can be
# uploaded even when the image is blocked. Exit code is the threshold's.
set -euo pipefail

source_ref="${1:?usage: scan-image.sh SOURCE OUT_DIR [PLATFORM] [LABEL]}"
out="${2:?OUT_DIR required}"
platform="${3:-}"
label="${4:-$source_ref}"
syft="${SYFT:-syft}"
grype="${GRYPE:-grype}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$out"
platform_args=()
[ -z "$platform" ] || platform_args=(--platform "$platform")

echo "::group::SBOM (${label})"
"$syft" scan "$source_ref" "${platform_args[@]}" \
  -o "syft-json=${out}/sbom.syft.json" \
  -o "spdx-json=${out}/sbom.spdx.json"
echo "::endgroup::"

# Scan the lossless Syft SBOM (same package set as the published SBOM).
echo "::group::Vulnerability scan (${label})"
"$grype" "sbom:${out}/sbom.syft.json" \
  -o "json=${out}/grype.json" \
  -o "sarif=${out}/grype.sarif"
echo "::endgroup::"

"${here}/check-vuln-threshold.sh" "${out}/grype.json" "$label"
