#!/usr/bin/env bash
# Run the product smoke test from a TEST image (tests/product/Dockerfile.*):
# the product image plus only the test scripts. The product image itself is
# never modified, and no extras image is involved.
#
# Usage: run-product-smoke.sh TEST_IMAGE VARIANT [PLATFORM]
#   TEST_IMAGE  image built FROM the product under test (docker-bake.hcl: test / test-published)
#   VARIANT     debian | alpine
#   PLATFORM    optional docker --platform. CI only runs the runner-native
#               platform (linux/amd64); other platforms would need emulation.
# Environment:
#   SMOKE_TIMEOUT       seconds before the container run is aborted (default 600)
#   EXPECT_LABELS       "1": also require the OCI labels written by CI to match
#                       build-info.json (installed versions/revisions)
#   EXPECT_REVISION     if set, org.opencontainers.image.revision must equal it
set -euo pipefail

image="${1:?usage: run-product-smoke.sh TEST_IMAGE VARIANT [PLATFORM]}"
variant="${2:?VARIANT required (debian|alpine)}"
platform="${3:-}"
timeout_s="${SMOKE_TIMEOUT:-600}"
label_prefix="io.github.ivan-kostko.dev-base"

run_args=(run --rm)
[ -z "$platform" ] || run_args+=(--platform "$platform")

echo "== product smoke test via ${image} (${variant}${platform:+, $platform}) =="

# The image's own default user must be the non-root dev user (no --user needed).
default_user="$(docker image inspect "$image" --format '{{.Config.User}}')"
if [ "$default_user" != "vscode" ]; then
  echo "FAIL image default user is '${default_user}', expected 'vscode'" >&2
  exit 1
fi
echo "PASS image default user: vscode"

rc=0
timeout "$timeout_s" docker "${run_args[@]}" --user vscode "$image" \
  /opt/dev-base-tests/smoke.sh "$variant" || rc=$?
[ "$rc" -eq 0 ] || { echo "product smoke test FAILED (exit ${rc})" >&2; exit 1; }

label() { docker image inspect "$image" --format "{{ index .Config.Labels \"$1\" }}"; }

if [ -n "${EXPECT_REVISION:-}" ]; then
  actual="$(label org.opencontainers.image.revision)"
  [ "$actual" = "$EXPECT_REVISION" ] \
    || { echo "FAIL label org.opencontainers.image.revision: expected ${EXPECT_REVISION}, got '${actual}'" >&2; exit 1; }
  echo "PASS label org.opencontainers.image.revision ${actual}"
fi

if [ "${EXPECT_LABELS:-}" = "1" ]; then
  info="$(timeout "$timeout_s" docker "${run_args[@]}" --user vscode "$image" cat /usr/local/share/dev-base/build-info.json)"
  check_label() { # label-suffix installed-value
    local got; got="$(label "${label_prefix}.$1")"
    [ "$got" = "$2" ] || { echo "FAIL label ${label_prefix}.$1: '${got}' != installed '$2'" >&2; exit 1; }
    echo "PASS label ${label_prefix}.$1 = $2"
  }
  check_label claude-code-version "$(jq -r .installed.claude_code <<<"$info")"
  check_label codex-version "$(jq -r .installed.codex <<<"$info")"
  check_label oh-my-zsh-revision "$(jq -r .installed.oh_my_zsh_revision <<<"$info")"
  check_label powerlevel10k-revision "$(jq -r .installed.powerlevel10k_revision <<<"$info")"
fi
echo "product smoke test passed"
