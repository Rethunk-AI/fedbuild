#!/bin/bash
# bastion-vm-firstboot — runs once on first boot as the 'user' account.
# Installs Homebrew and the dev tools that have no RPM (system or external repo).
#
# Packages already handled by RPM repos (not listed here):
#   cloudflared  → pkg.cloudflare.com/cloudflared/rpm  (signed)
#   code         → packages.microsoft.com/yumrepos/vscode (signed)
#
# kubectl is intentionally installed via brew (kubernetes-cli) rather than
# pkgs.k8s.io because that repo requires a pinned minor version in its URL,
# which would break the always-update policy of this image.
#
# AI CLI tools (claude, gemini) installed via npm — no signed RPM repo exists.
set -euo pipefail

SENTINEL_DIR=/var/lib/bastion-vm-firstboot
log() { echo "[firstboot] $(date -Iseconds) $*"; }

on_exit() {
    local rc=$?
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
    _brew_installer=$(mktemp /tmp/brew-install-XXXXXX.sh)
    trap 'rm -f "$_brew_installer"' EXIT
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        -o "$_brew_installer"
    log "Homebrew installer downloaded — $(sha256sum "$_brew_installer")"
    NONINTERACTIVE=1 bash "$_brew_installer"
    rm -f "$_brew_installer"
    trap - EXIT
    trap on_exit EXIT  # re-register after brew installer cleanup removed it
fi

eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
log "Homebrew $(brew --version | head -1)"

# ── Update formulae metadata ───────────────────────────────────────────────────
log "Updating Homebrew formulae"
brew update

# ── Brew formulae — bleeding-edge or no signed RPM repo ───────────────────────
# stripe-cli: Stripe's RPM is on a third-party JFrog instance with gpgcheck=0
#             and is not a Stripe-owned domain — brew is safer.
FAILED=()

brew_install() {
    local pkg="$1"
    log "Installing $pkg"
    if brew install "$pkg"; then
        log "$pkg OK"
    else
        log "ERROR: $pkg failed"
        FAILED+=("brew:$pkg")
    fi
}

brew_install actionlint
brew_install buf
brew_install kubernetes-cli
brew_install oven-sh/bun/bun
brew_install semgrep
brew_install uv
brew_install watchexec
brew_install stripe/stripe-cli/stripe
brew_install supabase/tap/supabase

# ── Yarn v4 Berry via corepack ────────────────────────────────────────────────
# corepack ships with Node.js; 'enable' installs yarn/pnpm shims system-wide
# (needs root — user has NOPASSWD:ALL). 'prepare yarn@stable' downloads v4
# Berry and makes it the global default; runs as user into corepack's cache.
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

cat > ~/.claude/CLAUDE.md << 'CLAUDEMD'
# Bastion Agent

Coding agent running in an isolated Fedora 43 VM (fedbuild).

## Environment

- Sudo: passwordless (`NOPASSWD: ALL`) — VM is sandboxed, intentional
- Network: outbound only; no inbound exposure

## Tools

Installed via RPM / Homebrew / npm — use these, don't install ad-hoc:

| Category | Tools |
|----------|-------|
| VCS | git, gh |
| Runtimes | go, node, bun, yarn, uv (Python) |
| Search | rg, fd, tokei |
| Containers | podman, kubectl, helm |
| AI CLIs | claude, gemini |
| Linters | shellcheck, actionlint, semgrep, buf |
| Cloud | stripe, supabase, cloudflared |

## Git Identity

`/etc/gitconfig`: `Bastion Agent <bastion-agent@rethunk.tech>` — override per-repo:
`git config user.name "..." && git config user.email "..."`

## Defaults

- Editor: nvim; Pager: less
- Python: uv (not pip/poetry)
- Prefer `rg` over grep, `fd` over find
- Commit early and often; conventional commits (`type(scope): subject`)
CLAUDEMD

cat > ~/.claude/settings.json << 'SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(gh *)",
      "Bash(make *)",
      "Bash(brew *)",
      "Bash(npm *)",
      "Bash(npx *)",
      "Bash(node *)",
      "Bash(go *)",
      "Bash(uv *)",
      "Bash(python3 *)",
      "Bash(bun *)",
      "Bash(yarn *)",
      "Bash(rg *)",
      "Bash(fd *)",
      "Bash(curl *)",
      "Bash(sudo *)",
      "Bash(podman *)",
      "Bash(kubectl *)",
      "Bash(helm *)",
      "Bash(semgrep *)",
      "Bash(actionlint *)",
      "Bash(shellcheck *)",
      "Bash(buf *)",
      "Bash(stripe *)",
      "Bash(supabase *)"
    ]
  }
}
SETTINGS

log "Claude Code configuration written to ~/.claude/"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    log "FAILED installs: ${FAILED[*]}"
    exit 1
fi

log "Done"
