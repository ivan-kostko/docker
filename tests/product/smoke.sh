#!/usr/bin/env bash
# Product smoke test. Runs INSIDE the test image (product + this directory,
# nothing else installed) as the non-root `vscode` user, so every assertion is
# about the unchanged inherited product environment.
#
# Usage: smoke.sh VARIANT           (debian | alpine)
#
# Checks (docs/product-contract.md):
#   - identity: user `vscode`, non-root, HOME=/home/vscode
#   - the command contract (contract/common.txt + contract/<variant>.txt) in an
#     interactive zsh, exactly like a devcontainer terminal
#   - repo dev/test/scanner tools are NOT in the product (contract/forbidden.txt)
#   - shell setup: oh-my-zsh, powerlevel10k, fonts, .zshrc wiring, ~/.gnupg mode
#   - /usr/local/share/dev-base/build-info.json exists and its installed
#     versions match what was requested
set -uo pipefail

variant="${1:?usage: smoke.sh VARIANT}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
contract="${here}/contract"
info=/usr/local/share/dev-base/build-info.json
fail=0

pass() { printf 'PASS %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }
# expect <description> <command...>: pass if the command succeeds
expect() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else bad "$desc"; fi; }

# --- identity -----------------------------------------------------------------
user="$(id -un)"; uid="$(id -u)"
if [ "$user" = "vscode" ] && [ "$uid" != "0" ]; then pass "user is vscode (uid ${uid})"; else bad "expected non-root vscode, got ${user} (uid ${uid})"; fi
expect "HOME=/home/vscode" test "$HOME" = "/home/vscode"

# --- command contract ---------------------------------------------------------
[ -f "${contract}/${variant}.txt" ] || { echo "unknown variant: ${variant}" >&2; exit 2; }
commands=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  commands+=("$line")
done < <(cat "${contract}/common.txt" "${contract}/${variant}.txt")

# One interactive zsh runs the whole list. Built as literal lines because zsh
# does not word-split variables.
zsh_script=$'fail=0\n'
for c in "${commands[@]}"; do
  q="${c//\'/\'\\\'\'}"
  zsh_script+="out=\$( ${c} 2>&1 ) && printf 'PASS %s\\n' '${q}' || { printf 'FAIL %s\\n%s\\n' '${q}' \"\$out\"; fail=1; }"$'\n'
done
# shellcheck disable=SC2016 # $fail must expand inside zsh
zsh_script+='exit $fail'
zsh -ic "$zsh_script" || fail=1

# --- must NOT be in the product -----------------------------------------------
while IFS= read -r tool; do
  case "$tool" in ''|'#'*) continue ;; esac
  if zsh -ic "command -v $tool" >/dev/null 2>&1; then bad "forbidden tool in product: ${tool}"; else pass "absent: ${tool}"; fi
done < "${contract}/forbidden.txt"

# --- shell setup --------------------------------------------------------------
expect "oh-my-zsh installed" test -d "$HOME/.oh-my-zsh"
expect "powerlevel10k installed" test -f "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme"
expect "p10k config present (.p10k.zsh)" test -f "$HOME/.p10k.zsh"
expect ".zshrc uses powerlevel10k" grep -q '^ZSH_THEME="powerlevel10k/powerlevel10k"' "$HOME/.zshrc"
# shellcheck disable=SC2016 # literal line expected in .zshrc
expect ".zshrc puts ~/.local/bin on PATH" grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc"
fonts="$(find "$HOME/.fonts" -name 'MesloLGS NF*.ttf' 2>/dev/null | wc -l)"
expect "4 MesloLGS NF fonts (found ${fonts})" test "$fonts" -eq 4
expect ".gnupg has mode 700" test "$(stat -c %a "$HOME/.gnupg" 2>/dev/null)" = "700"

# --- build info ---------------------------------------------------------------
if [ -f "$info" ] && jq -e '.schema == 1' "$info" >/dev/null 2>&1; then
  pass "build-info.json present"
  # requested value, when explicit, must equal what is installed
  req() { jq -r ".requested.$1" "$info"; }
  ins() { jq -r ".installed.$1" "$info"; }
  cmp_version() { # name requested installed
    case "$2" in latest|stable|HEAD|master|'') pass "build-info $1: '$2' resolved to $3" ;;
      *) if [ "$2" = "$3" ]; then pass "build-info $1 = $3"; else bad "build-info $1: requested $2, installed $3"; fi ;;
    esac
  }
  cmp_version claude_code "$(req claude_code)" "$(ins claude_code)"
  cmp_version codex "$(req codex | sed 's/^rust-v//')" "$(ins codex)"
  cmp_version oh_my_zsh "$(req oh_my_zsh)" "$(ins oh_my_zsh_revision)"
  cmp_version powerlevel10k "$(req powerlevel10k)" "$(ins powerlevel10k_revision)"
else
  bad "${info} missing or invalid"
fi

if [ "$fail" -eq 0 ]; then echo "product smoke test passed (${variant})"; else echo "product smoke test FAILED (${variant})" >&2; fi
exit "$fail"
