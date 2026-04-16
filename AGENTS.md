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
make shellcheck  # shellcheck all shell scripts in SOURCES
make lint        # rpmlint on built RPM
make validate    # check TOML syntax + SSH key + image-builder target
make clean       # rm rpmbuild/ and repo/
make distclean   # clean + rm output/
make deps        # install createrepo_c if missing
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
- RPM version/release auto-derived from spec via `sed` in Makefile — edit spec, not Makefile
- blueprint `version` field is semver string, bump it on each change for traceability
- `CLAUDE.md` is a symlink to `AGENTS.md` — never write to `CLAUDE.md` directly; edit `AGENTS.md`
