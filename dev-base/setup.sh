#!/usr/bin/env bash
# docker/deb-base/setup.sh
set -eu -o pipefail

# Accepted mutable inputs (docs/reproducibility.md): oh-my-zsh follows its
# `master` branch and powerlevel10k follows its default branch. CI resolves
# both to the current commit SHA first and passes it in, so the exact source
# revisions are recorded (OCI labels, build-info.json).
#   OMZ_REF   full commit SHA | empty (= whatever `master` is when built)
#   P10K_REF  full commit SHA or tag | empty (= default branch HEAD)
USER_NAME="${1:?USER_NAME required}"
HOME_DIR="/home/${USER_NAME}"

mkdir -p "${HOME_DIR}/.fonts" "${HOME_DIR}/.gnupg"
chmod 700 "${HOME_DIR}/.gnupg"
chown -R "${USER_NAME}" "${HOME_DIR}/.gnupg/"

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
if [ -n "${OMZ_REF:-}" ]; then
  # The installer clones `master`; move to the exact commit CI resolved.
  git -C "$HOME/.oh-my-zsh" fetch --quiet --depth=1 origin "$OMZ_REF"
  git -C "$HOME/.oh-my-zsh" checkout --quiet FETCH_HEAD
fi

P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ -n "${P10K_REF:-}" ]; then
  # Works for tags and full commit SHAs (GitHub allows fetching a SHA directly).
  git init --quiet "$P10K_DIR"
  git -C "$P10K_DIR" fetch --quiet --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_REF"
  git -C "$P10K_DIR" checkout --quiet FETCH_HEAD
else
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
fi

sed -i '1 iif [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then\n\tsource "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"\nfi' "${HOME_DIR}/.zshrc"
sed -i 's#ZSH_THEME=.*#ZSH_THEME="powerlevel10k/powerlevel10k"#g' "${HOME_DIR}/.zshrc"
echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> "${HOME_DIR}/.zshrc"
echo "export GPG_TTY=\${TTY}" >> "${HOME_DIR}/.zshrc"
