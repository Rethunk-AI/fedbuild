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

# ── Timing instrumentation ────────────────────────────────────────────────────
# Per-section SECONDS deltas; summary printed at end for journal-grep friendliness.
declare -A TIMINGS
SECTION_ORDER=()
section_start() { SECTION_T0=$SECONDS; SECTION_NAME="$1"; log "▶ $SECTION_NAME"; }
section_end()   {
    local dur=$((SECONDS - SECTION_T0))
    TIMINGS[$SECTION_NAME]=$dur
    SECTION_ORDER+=("$SECTION_NAME")
    log "◀ $SECTION_NAME (${dur}s)"
}
print_timing_summary() {
    log "──── Timing summary ────"
    local name
    for name in "${SECTION_ORDER[@]}"; do
        printf '  %-24s %4ss\n' "$name" "${TIMINGS[$name]}"
    done
    printf '  %-24s %4ss\n' "total" "$SECONDS"
}

# Homebrew: disable auto-update + cleanup + chatty hints for faster, quieter runs.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1

on_exit() {
    local rc=$?
    [[ -n "$BREW_INSTALLER" ]] && rm -f "$BREW_INSTALLER"
    print_timing_summary || true
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
section_start homebrew_install
if ! command -v brew &>/dev/null; then
    BREW_INSTALLER=$(mktemp /tmp/brew-install-XXXXXX.sh)
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        -o "$BREW_INSTALLER"
    log "Homebrew installer downloaded — $(sha256sum "$BREW_INSTALLER")"
    NONINTERACTIVE=1 bash "$BREW_INSTALLER"
fi
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
log "Homebrew $(brew --version | head -1)"
section_end

# Note: no explicit `brew update` — installer clones fresh taps and
# HOMEBREW_NO_AUTO_UPDATE=1 keeps bundle from re-fetching.

# ── Brew formulae via Brewfile ────────────────────────────────────────────────
# Single source of truth shipped by the RPM; diffable, one place to add/remove.
FAILED=()
BREWFILE=/usr/share/bastion-vm-firstboot/Brewfile
BREW_BUNDLE_LOG=$(mktemp /tmp/brew-bundle-XXXXXX.log)
# Run brew bundle in the background, concurrent with the npm/corepack work
# below. Brew writes under /home/linuxbrew; npm writes under ~/.npm-global and
# /usr (with sudo) — disjoint paths, safe to parallelize.
section_start brew_bundle_start
log "Running brew bundle --file=$BREWFILE (background)"
brew bundle --file="$BREWFILE" >"$BREW_BUNDLE_LOG" 2>&1 &
BREW_BUNDLE_PID=$!
section_end

# ── Yarn v4 Berry via corepack ────────────────────────────────────────────────
# Fedora's nodejs RPM no longer ships corepack, so install it globally via npm
# first, then enable (needs root — user has NOPASSWD:ALL). 'prepare yarn@stable'
# downloads v4 Berry and makes it the global default.
section_start corepack_yarn
if ! command -v corepack &>/dev/null; then
    sudo npm install -g corepack || { log "ERROR: npm install -g corepack failed"; FAILED+=("npm:corepack"); }
fi
if sudo corepack enable; then
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
section_end

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

section_start npm_globals
# claude: Anthropic's AI coding CLI — npm is the official install method
npm_install_global @anthropic-ai/claude-code
# gemini: Google's Gemini CLI — npm is the official install method
npm_install_global @google/gemini-cli
section_end

# ── Wait for backgrounded brew bundle ─────────────────────────────────────────
section_start brew_bundle_wait
log "Waiting for brew bundle (pid $BREW_BUNDLE_PID)"
if wait "$BREW_BUNDLE_PID"; then
    log "brew bundle OK"
else
    log "ERROR: brew bundle reported failures"
    FAILED+=("brew:bundle")
fi
log "──── brew bundle output ────"
cat "$BREW_BUNDLE_LOG"
log "──── end brew bundle output ────"
rm -f "$BREW_BUNDLE_LOG"
section_end

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
