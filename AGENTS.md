# fedbuild

Builds a Fedora 43 VM image for Bastion Agent (Claude Code) to run freely in an isolated VM.
Two artifacts: `bastion-vm-firstboot` RPM + `fedora-43-devbox` image via image-builder.

## Commands

```bash
make             # build RPM + local yum repo (default)
make rpm         # build bastion-vm-firstboot RPM only
make repo        # copy RPM into repo/ and run createrepo
make image       # build Fedora 43 VM image (requires sudo + SSH key set)
make check       # fast pre-push: shellcheck + TOML syntax + actionlint (no RPM build)
make check-versions  # assert spec Version matches blueprint version field
make check-settings  # JSON-schema validate agent-settings.json
make shellcheck  # shellcheck all shell scripts in SOURCES
make lint        # rpmlint on built RPM
make validate    # check TOML syntax + SSH key + image-builder target
make smoke       # boot VM in QEMU/KVM and assert firstboot + tool presence (requires built image)
make sign        # cosign keyless-sign output/SHA256SUMS (Sigstore OIDC)
make verify      # cosign verify SHA256SUMS (set CERT_IDENTITY + CERT_OIDC_ISSUER)
make clean       # rm rpmbuild/ and repo/
make distclean   # clean + rm output/
make deps        # install createrepo_c if missing
make bump-patch  # bump Z in X.Y.Z (spec + blueprint lockstep) → runs check-versions
make bump-minor  # bump Y, reset Z=0
make bump-major  # bump X, reset Y=0, Z=0
make help        # print target descriptions
```

## Architecture

```
fedbuild/
  blueprint.toml                          # osbuild blueprint — packages, repos, customizations
  Makefile                                # orchestration: rpm → repo → image chain
  bastion-vm-firstboot/
    SPECS/bastion-vm-firstboot.spec       # RPM spec
    SOURCES/
      firstboot.sh                        # runs on first boot as 'user', installs Homebrew + tools
      bastion-vm-firstboot.service        # systemd oneshot, User=user, TimeoutStartSec=infinity
      devbox-profile.sh → /etc/profile.d/devbox.sh   # GOPATH, PATH, Homebrew shellenv
      user-sudoers → /etc/sudoers.d/user  # NOPASSWD: ALL (intentional, no external IP)
      agent-claude.md → ~user/.claude/CLAUDE.md      # baked agent instructions (copied by firstboot)
      agent-settings.json → ~user/.claude/settings.json  # baked agent settings
  tests/
    smoke.sh                              # QEMU/KVM boot + SSH + tool-presence assertions
  keys/
    authorized_key                        # SSH pubkey (gitignored) — required by `make image`
  .github/workflows/
    ci.yml                                # fedora:43 lint: shellcheck + rpmlint + actionlint + TOML
  schemas/
    agent-settings.schema.json            # JSON Schema (2020-12) for baked ~/.claude/settings.json
  repo/                                   # local yum repo (createrepo output), passed via --extra-repo
  rpmbuild/                               # rpmbuild working tree
  output/                                 # built VM images
```

## Blueprint Format (non-obvious)

osbuild blueprint TOML — reference: https://osbuild.org/docs/user-guide/blueprint-reference/

- All packages use `version = "*"` — always-update policy, no pins anywhere
- `[[customizations.user]]` array-of-tables syntax required (dotted key + table header = invalid TOML)
- SSH key: place public key in `keys/authorized_key` (gitignored) — `make image` auto-generates `blueprint.effective.toml` with key substituted; `blueprint.toml` retains `CHANGEME` placeholder
- `[[customizations.files]]` inlines file content as escaped string in `data =`
- `[[customizations.repositories]]` wires external RPM repos at image-build time

## Git Identity

Image bakes `/etc/gitconfig` via `[[customizations.files]]`:
- `user.name = Bastion Agent`
- `user.email = bastion-agent@rethunk.tech`

Agent can override per-repo: `git config user.name / user.email`

## Gotchas

- `make image` needs `sudo` — image-builder runs privileged
- `TimeoutStartSec=infinity` in service — brew installs take 20+ min
- firstboot runs as `user` (not root) — Homebrew requires non-root
- firstboot logs go to journal only: `journalctl -u bastion-vm-firstboot -f`
- Done sentinel: `/var/lib/bastion-vm-firstboot/done` — delete to re-run on next boot
- Failure sentinel: `/var/lib/bastion-vm-firstboot/failed` — written on non-zero exit; check `journalctl -u bastion-vm-firstboot` for root cause
- RPM version/release auto-derived from spec via `sed` in Makefile — edit spec, not Makefile
- blueprint `version` field is semver string, bump it on each change for traceability
- `CLAUDE.md` is a symlink to `AGENTS.md` — never write to `CLAUDE.md` directly; edit `AGENTS.md`
- `make smoke` requires KVM, `qemu-system-x86_64`, `zstd`, and a built image in `output/`
- smoke failures: if SSH came up, firstboot journal is captured to `$OUTDIR/smoke-fail.log` (override via `FAIL_LOG=...`)

## CI

`.github/workflows/ci.yml` runs on push/PR to `main` in `fedora:43` container:
- shellcheck (all `SOURCES/*.sh`)
- rpmlint (built RPM)
- actionlint (pinned v1.7.7)
- TOML syntax (`yq`)
- `make check-versions` (spec ↔ blueprint parity)
- `make check-settings` (JSON-schema validate `agent-settings.json`)

Local equivalent: `make check`.
