#!/usr/bin/env bash
# Installs the standalone repository tools (Syft, Grype, Hadolint, actionlint)
# into $INSTALL_DIR (default /usr/local/bin). Run as root while building
# extras/Dockerfile.*; never part of the published dev-base product image.
# Versions/checksums: tools.env.
set -eu -o pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${here}/tools.env"

case "$(uname -m)" in
  x86_64)  arch=amd64;  hl_arch=x86_64 ;;
  aarch64) arch=arm64;  hl_arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

sha_var() { local v="${1}_SHA256_${arch^^}"; echo "${!v}"; }

fetch() { # fetch <url> <dest> <sha256>
  curl -fsSL -o "$2" "$1"
  echo "$3  $2" | sha256sum -c -
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for tool in syft grype; do
  ver_var="${tool^^}_VERSION"; ver="${!ver_var}"
  fetch "https://github.com/anchore/${tool}/releases/download/v${ver}/${tool}_${ver}_linux_${arch}.tar.gz" \
    "${tmp}/${tool}.tar.gz" "$(sha_var "${tool^^}")"
  tar -xzf "${tmp}/${tool}.tar.gz" -C "$tmp" "$tool"
  install -m 0755 "${tmp}/${tool}" "${INSTALL_DIR}/${tool}"
done

fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-${hl_arch}" \
  "${tmp}/hadolint" "$(sha_var HADOLINT)"
install -m 0755 "${tmp}/hadolint" "${INSTALL_DIR}/hadolint"

fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" \
  "${tmp}/actionlint.tar.gz" "$(sha_var ACTIONLINT)"
tar -xzf "${tmp}/actionlint.tar.gz" -C "$tmp" actionlint
install -m 0755 "${tmp}/actionlint" "${INSTALL_DIR}/actionlint"

for t in syft grype hadolint actionlint; do "${INSTALL_DIR}/${t}" --version 2>&1 | head -n 1 || true; done
