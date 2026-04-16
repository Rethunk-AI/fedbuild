#!/bin/bash
# bastion-vm-firstboot — runs once on first boot as the 'user' account.
# Installs Homebrew + formulae from /usr/share/bastion-vm-firstboot/Brewfile,
# corepack (yarn v4), and AI CLI npm globals (claude, gemini).
#
# RPM repos handle: cloudflared, code/code-insiders (both signed).
# Brew handles formulae that lack a signed always-update RPM source; see Brewfile.
# npm handles AI CLIs (no signed RPM repo exists upstream).
set -euo pipefail

SENTINEL_DIR=/var/lib/bastion-vm-firstboot
BREW_INSTALLER=""
log() { echo "[firstboot] $(date -Iseconds) $*"; }

on_exit() {
    local rc=$?
    [[ -n "$BREW_INSTALLER" ]] && rm -f "$BREW_INSTALLER"
    if [[ $rc -ne 0 ]]; then
        log "FAILED (exit $rc) — writing failure sentinel"
        touch "${SENTINEL_DIR}/failed" 2>/dev/null || true
    fi
}
trap on_exit EXIT

log "Starting"

# ── Environment (profile.d not sourced by systemd) ────────────────────────────
export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
export PATH="${HOME}/.npm-global/bin:${PATH}"

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    log "Installing Homebrew"
    BREW_INSTALLER=$(mktemp /tmp/brew-install-XXXXXX.sh)
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        -o "$BREW_INSTALLER"
    log "Homebrew installer downloaded — $(sha256sum "$BREW_INSTALLER")"
    NONINTERACTIVE=1 bash "$BREW_INSTALLER"
fi

eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
log "Homebrew $(brew --version | head -1)"

# ── Update formulae metadata ───────────────────────────────────────────────────
log "Updating Homebrew formulae"
brew update

# ── Brew formulae via Brewfile ────────────────────────────────────────────────
# Single source of truth shipped by the RPM; diffable, one place to add/remove.
FAILED=()
BREWFILE=/usr/share/bastion-vm-firstboot/Brewfile
log "Running brew bundle --file=$BREWFILE"
if brew bundle --file="$BREWFILE"; then
    log "brew bundle OK"
else
    log "ERROR: brew bundle reported failures"
    FAILED+=("brew:bundle")
fi

# ── Yarn v4 Berry via corepack ────────────────────────────────────────────────
# Fedora's nodejs RPM no longer ships corepack, so install it globally via npm
# first, then enable (needs root — user has NOPASSWD:ALL). 'prepare yarn@stable'
# downloads v4 Berry and makes it the global default.
log "Installing corepack (npm global — Fedora nodejs RPM no longer ships it)"
if ! command -v corepack &>/dev/null; then
    sudo npm install -g corepack || { log "ERROR: npm install -g corepack failed"; FAILED+=("npm:corepack"); }
fi
log "Enabling corepack (yarn/pnpm shims)"
if sudo corepack enable; then
    log "Preparing Yarn v4 Berry"
    if corepack prepare yarn@stable --activate; then
        log "Yarn $(yarn --version) active"
    else
        log "ERROR: corepack prepare yarn@stable failed"
        FAILED+=("corepack:yarn@stable")
    fi
else
    log "ERROR: corepack enable failed"
    FAILED+=("corepack:enable")
fi

# ── npm globals — AI CLI tools with no signed RPM repo ────────────────────────
npm_install_global() {
    local pkg="$1"
    log "Installing $pkg (npm)"
    if npm install -g "$pkg"; then
        log "$pkg OK"
    else
        log "ERROR: $pkg npm install failed"
        FAILED+=("npm:$pkg")
    fi
}

# claude: Anthropic's AI coding CLI — npm is the official install method
npm_install_global @anthropic-ai/claude-code
# gemini: Google's Gemini CLI — npm is the official install method
npm_install_global @google/gemini-cli

# ── Go workspace ──────────────────────────────────────────────────────────────
log "Creating Go workspace dirs"
mkdir -p ~/go/bin

# ── Claude Code agent configuration ───────────────────────────────────────────
log "Writing Claude Code agent configuration"
mkdir -p ~/.claude
cp /usr/share/bastion-vm-firstboot/agent-claude.md ~/.claude/CLAUDE.md
cp /usr/share/bastion-vm-firstboot/agent-settings.json ~/.claude/settings.json
log "Claude Code configuration written to ~/.claude/"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    log "FAILED installs: ${FAILED[*]}"
    exit 1
fi

log "Done"
