# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Capture serial console to file; dump on failure
- Dump firstboot timing summary; quiet semgrep version banner
- Harden firstboot unit with selected sandboxing
- Emit /etc/fedbuild-release + inline shellcheck in %check
- Emit /var/log/fedbuild-ready.json on success
- Always dump journal, SELinux + release assertions
- Expand CLAUDE.md workflow notes; add hooks/env/model to settings
- Slim locale + drop man-pages; raise disk to 50 GiB
- Add sbom target (syft CycloneDX + SPDX)
- Unified regression tracking CSV + baseline-record target
- Bake dnf-automatic security-only updates
- Ship auditd with minimal root-exec + sudoers watch rules
- Dump Brewfile.lock.json record post-install (not a pin)
- Add bless-boot-time + include smoke-rerun.sh in shellcheck

### CI
- Enforce Conventional Commits on PRs via commitlint
- Add systemd-analyze security advisory step

### Changed
- Tidy log layout — aligned columns, status glyphs
- Parallelize brew bundle with npm work; add timing summary
- Reclaim disk at end via brew cleanup + dnf clean all
- Unify tool presence + version into one section
- Dense final banner; hide passing config rows

### Docs
- Add threat model + trust boundary
- Operational notes for baselines, auditd, SBOM verification
- Document sbom/attest/smoke-rerun/baseline-record targets
- SBOM, SLSA L1, auditd, dnf-automatic in threat model

### Fixed
- Scheme-qualify --extra-repo and add build-time external repos
- Drop user(user) auto-dep; chown sentinel dir at service start
- Force zstd decompression over mktemp placeholder
- Swap -nographic for -display none to allow -daemonize
- Observe QEMU; detect early exit; surface stderr
- Boot under OVMF (UEFI) via q35
- Disable initial-setup.service to unblock headless boot
- Pass -cpu host so guest sees SSSE3/AVX/etc.
- Add tar and ruby for Homebrew bootstrap
- Drop brew --no-lock; install corepack via npm
- Drop stripe-cli — macOS-only formula
- Use per-tool version commands
- Verify brew bundle completeness
- Strip chained env-var prefixes before probing binary
- Clean run output + ephemeral host keys

### Tests
- Assert auditd + dnf-automatic + Brewfile.lock.json
- Boot-time regression check against tests/boot-time.baseline
- Add smoke-rerun.sh for idempotency verification
- Initial boot-time baseline placeholder (120s)

## [0.4.0] - 2026-04-16

### Added
- Emit SHA256SUMS alongside built image
- Add sign/verify targets for SHA256SUMS (cosign keyless)
- JSON-schema validate baked agent-settings.json
- Add bump-patch/minor/major for spec+blueprint version lockstep
- Add pre-commit config + install-hooks target
- Reproducible builds via SOURCE_DATE_EPOCH
- Image-size budget with bless-size
- Brewfile replaces per-pkg install loop
- Diff-packages drift report
- Git-cliff automation + make changelog

### CI
- Pin actionlint to v1.7.7; expand cache key to blueprint+spec

### Docs
- Sync brew formula list with firstboot.sh
- Backfill 0.2.0 and 0.3.0 entries
- Add CI section, baked agent files, missing make targets
- Reconcile AGENTS/HUMANS/CONTRIBUTING for new targets
- Refresh with supply-chain summary + doc map

### Fixed
- Clean repo dir before rebuilding
- Consolidate EXIT trap; failure sentinel survives brew install
- Sshd_config.d drop-in mode 0644 (was 0600)
- Install systemd-rpm-macros + git; fix spec changelog dates

### Tests
- Fail fast when firstboot writes failed sentinel
- Capture firstboot journal to smoke-fail.log on failure

## [0.3.0] - 2026-04-16

### Added
- Add jq, yq, sqlite, buildah, skopeo; bump to 0.3.0

### Changed
- Extract agent config to RPM-managed source files

## [0.2.0] - 2026-04-16

### Added
- Bake Claude Code agent config into ~/.claude/
- Add QEMU smoke test (make smoke)
- Drop ollama — not needed in guest
- Harden SSHD — key-only, no root, no X11
- Cache dnf packages weekly
- Log installed versions after tool-presence check

### Docs
- Add CHANGELOG.md (keepachangelog, 0.1.0)
- Add make smoke to AGENTS.md, HUMANS.md; wire smoke.sh into make check
- Document failure sentinel; bump blueprint to 0.2.0

### Fixed
- Add least-privilege GITHUB_TOKEN permissions
- Set NPM_CONFIG_PREFIX for systemd context
- Add failure sentinel + harden corepack/yarn
- Install actionlint via go install, not dnf
- Add BuildRequires: systemd-rpm-macros
- Fail loudly on install errors

### Tests
- Check failed sentinel; expand tool assertions

## [0.1.0] - 2026-04-16

### Added
- Add Fedora 43 devbox image blueprint
- Add bastion-vm-firstboot RPM package
- Add AI coding CLIs — Claude Code, Gemini CLI, VS Code stable
- Add bun and yarn v4 Berry (corepack)
- Add check target — shellcheck + TOML + actionlint

### Docs
- Remove Package Decisions table into add-package-to-vm skill
- Split docs into AGENTS.md/HUMANS.md, symlink CLAUDE.md
- Add SECURITY.md
- Add CONTRIBUTING.md
- Fix org name, modernize pre-push checks
- Deconflict and deduplicate repo documentation

### Fixed
- Resolve ShellCheck warnings in firstboot and profile scripts

### Build
- Add Makefile orchestrating rpm → repo → image pipeline


