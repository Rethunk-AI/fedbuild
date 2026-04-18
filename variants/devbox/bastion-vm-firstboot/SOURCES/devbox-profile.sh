# shellcheck shell=bash
# /etc/profile.d/devbox.sh — environment for coding-agent VM
# Applied to all login shells.

# Go workspace
export GOPATH="${HOME}/go"
export GOBIN="${GOPATH}/bin"
[[ ":${PATH}:" != *":${GOBIN}:"* ]] && export PATH="${PATH}:${GOBIN}"

# Homebrew on Linux — populated after bastion-vm-firstboot completes
if [ -d /home/linuxbrew/.linuxbrew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# Preferred CLI tools
export EDITOR=nvim
export VISUAL=nvim
export PAGER=less

# npm global installs go under home, not /usr
export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
[[ ":${PATH}:" != *":${HOME}/.npm-global/bin:"* ]] && export PATH="${PATH}:${HOME}/.npm-global/bin"

# Suppress semgrep's network update-check banner (brew keeps it up to date).
export SEMGREP_ENABLE_VERSION_CHECK=0
