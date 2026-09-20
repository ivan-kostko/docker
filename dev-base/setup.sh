#!/usr/bin/env bash
# docker/deb-base/setup.sh
set -eu -o pipefail

USER_NAME="${1:?USER_NAME required}"
HOME_DIR="/home/${USER_NAME}"

mkdir -p "${HOME_DIR}/.fonts" "${HOME_DIR}/.gnupg"
chmod 700 "${HOME_DIR}/.gnupg"
chown -R "${USER_NAME}" "${HOME_DIR}/.gnupg/"

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"

sed -i '1 iif [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then\n\tsource "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"\nfi' "${HOME_DIR}/.zshrc"
sed -i 's#ZSH_THEME=.*#ZSH_THEME="powerlevel10k/powerlevel10k"#g' "${HOME_DIR}/.zshrc"
echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> "${HOME_DIR}/.zshrc"
echo "export GPG_TTY=\${TTY}" >> "${HOME_DIR}/.zshrc"
