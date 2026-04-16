# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Reproducible RPM builds — `SOURCE_DATE_EPOCH` from last commit touching spec/sources; `clamp_mtime_to_source_date_epoch` + `use_source_date_epoch_as_buildtime` pin file mtimes and buildtime. Two successive `make rpm` runs produce byte-identical output.
- Image size budget — `make image` writes `output/SIZE` and runs `make check-size`; fails if compressed image exceeds `tests/size.baseline` by more than `SIZE_BUDGET_PCT` (default 10%). `make bless-size` promotes current size to baseline.

## [0.3.0] - 2026-04-16

### Added
- Blueprint packages: `jq`, `yq`, `sqlite`, `buildah`, `skopeo`

## [0.2.0] - 2026-04-16

### Added
- `BuildRequires: systemd-rpm-macros` in spec
- `make check-versions` enforces parity between spec `Version` and blueprint `version`

### Changed
- Agent config (`CLAUDE.md`, `settings.json`) extracted from inline heredocs into RPM-managed `SOURCES/agent-claude.md` and `SOURCES/agent-settings.json`

## [0.1.0] - 2026-04-16

### Added
- `bastion-vm-firstboot` RPM: systemd oneshot service installs Homebrew and dev tools on first boot
- `fedora-43-devbox` osbuild blueprint: Fedora 43 VM with 40+ packages, VS Code, cloudflared
- Claude Code agent configuration baked into `~/.claude/` via firstboot (`CLAUDE.md` + `settings.json`)
- `make smoke` target: QEMU/KVM integration test — boots image, SSHes in, asserts tools + firstboot
- GitHub Actions CI: shellcheck + TOML lint + actionlint + RPM build + rpmlint
- Issue templates (bug report, feature request) and PR template
- Documentation: `HUMANS.md` (human guide), `AGENTS.md` (agent reference), `SECURITY.md`, `CONTRIBUTING.md`

### Architecture
- `blueprint.toml`: osbuild blueprint with always-update (`version = "*"`) package policy
- `bastion-vm-firstboot/`: RPM package — firstboot service + profile.d + sudoers
- `Makefile`: `rpm → repo → image` build chain with `check`, `lint`, `validate`, `smoke` targets
- `keys/authorized_key`: SSH public key (gitignored), substituted at build time into `blueprint.effective.toml`
