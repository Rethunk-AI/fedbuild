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
    log "brew bundle reported OK"
else
    log "ERROR: brew bundle reported failures"
    FAILED+=("brew:bundle")
fi
log "──── brew bundle output ────"
cat "$BREW_BUNDLE_LOG"
log "──── end brew bundle output ────"
rm -f "$BREW_BUNDLE_LOG"

# Verify all formulae actually installed. `brew bundle` has been observed to
# report "complete! N dependencies now installed" while silently missing one
# under concurrent bottle fetches (seen: semgrep absent from Cellar after
# bundle claimed success). `brew bundle check` catches the gap; retry once.
if ! brew bundle check --file="$BREWFILE" >/dev/null 2>&1; then
    log "WARN: brew bundle check found missing formulae — retrying"
    brew bundle check --file="$BREWFILE" --verbose 2>&1 | sed 's/^/  /' | head -20
    if brew bundle --file="$BREWFILE"; then
        log "brew bundle retry OK"
    else
        log "ERROR: brew bundle retry failed"
        FAILED+=("brew:bundle:retry")
    fi
    if ! brew bundle check --file="$BREWFILE" >/dev/null 2>&1; then
        log "ERROR: brew bundle still incomplete after retry"
        brew bundle check --file="$BREWFILE" --verbose 2>&1 | sed 's/^/  /' | head -20
        FAILED+=("brew:bundle:check")
    fi
fi

# Dump a post-install record of what landed this boot.
# THIS IS A RECORD, NOT A PIN — next boot still pulls "latest" unless
# `brew bundle --frozen` is used. Name keeps `.json` suffix for convention
# though `brew bundle dump` emits Brewfile-format text, not JSON.
# Only run if the bundle succeeded — otherwise the dump reflects a partial
# install and misleads drift diffs.
if [[ ${#FAILED[@]} -eq 0 ]]; then
    log "Dumping Brewfile.lock.json (post-install record)"
    _lock_tmp=$(mktemp /tmp/Brewfile.lock.XXXXXX)
    if brew bundle dump --file="$_lock_tmp" --force; then
        sudo install -m 0644 "$_lock_tmp" "${SENTINEL_DIR}/Brewfile.lock.json"
        log "Brewfile.lock.json written to ${SENTINEL_DIR}/Brewfile.lock.json"
    else
        log "WARN: brew bundle dump failed — lock record not written"
    fi
    rm -f "$_lock_tmp"
fi
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

# ── Cleanup: reclaim disk after deferred brew cleanup + dnf caches ────────────
# HOMEBREW_NO_INSTALL_CLEANUP=1 above skipped per-install cleanup for speed;
# we run it once here at the end. dnf metadata/cache are redundant in a baked
# image — the agent can redownload on demand.
# Only runs on success; on failure we leave caches in place for diagnosis.
section_start cleanup
if [[ ${#FAILED[@]} -eq 0 ]]; then
    before=$(df --output=used -B1 /home/linuxbrew 2>/dev/null | tail -1 || echo 0)
    log "brew cleanup --prune=all"
    brew cleanup --prune=all || log "WARN: brew cleanup returned non-zero"
    log "sudo dnf clean all"
    sudo dnf clean all || log "WARN: dnf clean all returned non-zero"
    after=$(df --output=used -B1 /home/linuxbrew 2>/dev/null | tail -1 || echo 0)
    if [[ "$before" != 0 && "$after" != 0 ]]; then
        freed=$(( (before - after) / 1024 / 1024 ))
        log "Freed ${freed} MiB on /home/linuxbrew"
    fi
else
    log "Skipping cleanup due to earlier failures (preserve caches for diagnosis)"
fi
section_end

if [[ ${#FAILED[@]} -gt 0 ]]; then
    log "FAILED installs: ${FAILED[*]}"
    exit 1
fi

# ── Emit /var/log/fedbuild-ready.json ─────────────────────────────────────────
# Single-line JSON snapshot of firstboot outcome for observability + smoke.
# Sourced from /etc/fedbuild-release (baked by RPM %post); tool versions queried
# inline. Writing /var/log requires root → sudo tee.
log "Writing /var/log/fedbuild-ready.json"
# shellcheck source=/dev/null
. /etc/fedbuild-release 2>/dev/null || true
tool_version() { command -v "$1" >/dev/null 2>&1 && "$@" 2>/dev/null | head -1 || echo "<missing>"; }
ready_json=$(cat <<JSON
{"name":"${NAME:-bastion-vm-firstboot}","version":"${VERSION:-unknown}","release":"${RELEASE:-unknown}","git_commit":"${GIT_COMMIT:-unknown}","install_date":"${INSTALL_DATE:-unknown}","firstboot_date":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","firstboot_secs":${SECONDS},"tools":{"claude":"$(tool_version claude --version)","gemini":"$(tool_version gemini --version)","brew":"$(brew --version 2>/dev/null | head -1)","node":"$(tool_version node --version)","go":"$(go version 2>/dev/null)"}}
JSON
)
echo "$ready_json" | sudo tee /var/log/fedbuild-ready.json >/dev/null
sudo chmod 0644 /var/log/fedbuild-ready.json

log "Done"
