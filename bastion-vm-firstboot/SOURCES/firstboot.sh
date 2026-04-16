#!/bin/bash
# bastion-vm-firstboot — runs once on first boot as the 'user' account.
# Installs Homebrew and the dev tools that have no RPM (system or external repo).
#
# Packages already handled by RPM repos (not listed here):
#   cloudflared  → pkg.cloudflare.com/cloudflared/rpm  (signed)
#
# kubectl is intentionally installed via brew (kubernetes-cli) rather than
# pkgs.k8s.io because that repo requires a pinned minor version in its URL,
# which would break the always-update policy of this image.
set -euo pipefail

log() { echo "[firstboot] $(date -Iseconds) $*"; }
log "Starting"

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    log "Installing Homebrew"
    _brew_installer=$(mktemp /tmp/brew-install-XXXXXX.sh)
    trap 'rm -f "$_brew_installer"' EXIT
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        -o "$_brew_installer"
    log "Homebrew installer downloaded — $(sha256sum "$_brew_installer")"
    NONINTERACTIVE=1 bash "$_brew_installer"
    rm -f "$_brew_installer"
    trap - EXIT
fi

eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
log "Homebrew $(brew --version | head -1)"

# ── Update formulae metadata ───────────────────────────────────────────────────
log "Updating Homebrew formulae"
brew update

# ── Brew formulae — bleeding-edge or no signed RPM repo ───────────────────────
# stripe-cli: Stripe's RPM is on a third-party JFrog instance with gpgcheck=0
#             and is not a Stripe-owned domain — brew is safer.
brew_install() {
    local pkg="$1"
    log "Installing $pkg"
    brew install "$pkg" && log "$pkg OK" || log "WARNING: $pkg failed — continuing"
}

brew_install actionlint
brew_install buf
brew_install kubernetes-cli
brew_install semgrep
brew_install uv
brew_install watchexec
brew_install stripe/stripe-cli/stripe
brew_install supabase/tap/supabase
brew_install ollama

# ── Go workspace ──────────────────────────────────────────────────────────────
log "Creating Go workspace dirs"
mkdir -p ~/go/bin

log "Done"
