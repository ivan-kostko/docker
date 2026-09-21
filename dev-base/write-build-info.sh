#!/usr/bin/env bash
# docker/dev-base/write-build-info.sh
# Records what was actually installed (as opposed to requested) in
# /usr/local/share/dev-base/build-info.json. Part of the documented product
# contract (docs/product-contract.md): CI extracts it as a build-metadata
# artifact and the smoke test checks it against the requested versions.
# Run as the dev user after setup.sh and install-ai-clis.sh.
set -eu -o pipefail

out="${BUILD_INFO_FILE:-/usr/local/share/dev-base/build-info.json}"
export PATH="${HOME}/.local/bin:${PATH}"

omz_dir="${HOME}/.oh-my-zsh"
p10k_dir="${ZSH_CUSTOM:-${omz_dir}/custom}/themes/powerlevel10k"

# shellcheck source=/dev/null
os_name="$(. /etc/os-release && echo "$PRETTY_NAME")"

jq -n \
  --arg os "$os_name" \
  --arg req_claude "${CLAUDE_CODE_VERSION:-latest}" \
  --arg req_codex "${CODEX_VERSION:-latest}" \
  --arg req_omz "${OMZ_REF:-master}" \
  --arg req_p10k "${P10K_REF:-HEAD}" \
  --arg claude "$(claude --version | awk '{print $1}')" \
  --arg codex "$(codex --version | awk '{print $2}')" \
  --arg omz "$(git -C "$omz_dir" rev-parse HEAD)" \
  --arg p10k "$(git -C "$p10k_dir" rev-parse HEAD)" \
  '{
    schema: 1,
    os: $os,
    requested: {claude_code: $req_claude, codex: $req_codex, oh_my_zsh: $req_omz, powerlevel10k: $req_p10k},
    installed: {claude_code: $claude, codex: $codex, oh_my_zsh_revision: $omz, powerlevel10k_revision: $p10k}
  }' > "$out"
cat "$out"
