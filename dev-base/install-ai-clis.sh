#!/usr/bin/env bash
# docker/dev-base/install-ai-clis.sh
# Installs Claude Code and OpenAI Codex CLIs for the given user.
# Both ship as standalone binaries — no Node.js dependency, works on
# glibc (Debian/Ubuntu) and musl (Alpine) alike.
#
# Accepted mutable inputs (docs/reproducibility.md): the Claude installer script
# and both CLIs follow upstream "latest". CI resolves the current latest to an
# explicit version first and passes it in, so the exact versions are recorded
# (OCI labels, build-info.json). Without arguments (local builds) "latest" is
# resolved by the installers themselves.
#   CLAUDE_CODE_VERSION  x.y.z | latest | stable            (default: latest)
#   CODEX_VERSION        GitHub release tag, e.g. rust-v0.155.1 | latest
set -eu -o pipefail

USER_NAME="${1:?USER_NAME required}"
HOME_DIR="/home/${USER_NAME}"
BIN_DIR="${HOME_DIR}/.local/bin"
mkdir -p "${BIN_DIR}"

### Claude Code — native installer, no Node.js required ###
curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION:-latest}"

### Alpine/musl: use OS ripgrep instead of the bundled binary ###
if ldd --version 2>&1 | grep -qi musl; then
  mkdir -p "${HOME_DIR}/.claude"
  SETTINGS_FILE="${HOME_DIR}/.claude/settings.json"
  [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
  tmp="$(mktemp)"
  jq '.env.USE_BUILTIN_RIPGREP = "0"' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
fi

### OpenAI Codex CLI — static musl binary, no Node.js required ###
case "$(uname -m)" in
  x86_64)  CODEX_ARCH="x86_64-unknown-linux-musl" ;;
  aarch64) CODEX_ARCH="aarch64-unknown-linux-musl" ;;
  *) echo "Unsupported architecture for Codex CLI: $(uname -m)" >&2; exit 1 ;;
esac

CODEX_VERSION="${CODEX_VERSION:-latest}"
if [ "$CODEX_VERSION" = "latest" ]; then
  CODEX_URL="https://github.com/openai/codex/releases/latest/download/codex-${CODEX_ARCH}.tar.gz"
else
  CODEX_URL="https://github.com/openai/codex/releases/download/${CODEX_VERSION}/codex-${CODEX_ARCH}.tar.gz"
fi

mkdir -p /tmp/codex-dl
curl -fsSL -o /tmp/codex.tar.gz "$CODEX_URL"
tar -xzf /tmp/codex.tar.gz -C /tmp/codex-dl
mv "/tmp/codex-dl/codex-${CODEX_ARCH}" "${BIN_DIR}/codex"
chmod +x "${BIN_DIR}/codex"
rm -rf /tmp/codex.tar.gz /tmp/codex-dl

### Ensure ~/.local/bin is on PATH for zsh (idempotent) ###
# Single quotes are intentional: $HOME/$PATH must expand when zsh starts, not now.
# shellcheck disable=SC2016
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "${HOME_DIR}/.zshrc" \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME_DIR}/.zshrc"
