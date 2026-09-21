#!/usr/bin/env bash
# Check or update the digests of the product base images.
#
# Usage: update-base-images.sh [--check | --write]     (default: --check)
#   --check  print each base image with its committed and current digest;
#            exit 1 if any differs (used by the scheduled drift report)
#   --write  rewrite dev-base/Dockerfile.* to the current digests, then review
#            and commit the diff (CODEOWNERS applies)
#
# Only official Docker Hub images (library/<name>:<tag>) are supported, which
# covers debian and alpine. Uses the registry API only; no Docker daemon needed.
# Changing the tag (e.g. alpine:3.23 -> 3.24) is a manual edit of the ARG;
# then run --write to refresh its digest.
set -euo pipefail

mode="check"
case "${1:---check}" in
  --check) mode="check" ;;
  --write) mode="write" ;;
  *) echo "usage: update-base-images.sh [--check|--write]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
accept="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"

current_digest() { # current_digest name tag
  local token
  token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/$1:pull" | jq -r .token)"
  curl -fsSI -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
    "https://registry-1.docker.io/v2/library/$1/manifests/$2" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

drift=0
for dockerfile in "${root}"/dev-base/Dockerfile.*; do
  ref="$(sed -n 's/^ARG BASE_IMAGE="\{0,1\}\([^" ]*\)"\{0,1\}[[:space:]]*$/\1/p' "$dockerfile" | head -n1)"
  if [[ ! "$ref" =~ ^([a-z0-9._-]+):([A-Za-z0-9._-]+)(@(sha256:[0-9a-f]{64}))?$ ]]; then
    echo "$(basename "$dockerfile"): unsupported BASE_IMAGE '${ref}' (need official-image name:tag[@sha256:...])" >&2
    exit 2
  fi
  name="${BASH_REMATCH[1]}"; tag="${BASH_REMATCH[2]}"; committed="${BASH_REMATCH[4]:-}"
  latest="$(current_digest "$name" "$tag")"
  [[ "$latest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "could not resolve ${name}:${tag}" >&2; exit 2; }

  if [ "$committed" = "$latest" ]; then
    echo "up to date: ${name}:${tag}@${latest}"
    continue
  fi
  drift=1
  echo "DRIFT ${name}:${tag}: committed ${committed:-<none>} -> current ${latest}"
  if [ "$mode" = write ]; then
    sed -i "s|^ARG BASE_IMAGE=\"[^\"]*\"|ARG BASE_IMAGE=\"${name}:${tag}@${latest}\"|" "$dockerfile"
    echo "  updated $(basename "$dockerfile")"
  fi
done

[ "$mode" = write ] && exit 0
exit "$drift"
