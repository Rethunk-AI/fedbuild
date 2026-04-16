# fedbuild

## Quick Start

```bash
make deps                                  # install createrepo_c (once)
cp ~/.ssh/id_ed25519.pub keys/authorized_key   # place your SSH pubkey
make                                       # build RPM + local yum repo (default)
make image                                 # build Fedora 43 VM image (needs sudo)
make smoke                                 # boot + assert firstboot (needs KVM)
```

`make help` lists every target. Full reference + gotchas in **[AGENTS.md](AGENTS.md)**.

## What First Boot Installs

- **RPM packages** — declared in [`blueprint.toml`](blueprint.toml) (`packages = [...]`)
- **Brew formulae** — listed in [`bastion-vm-firstboot/SOURCES/Brewfile`](bastion-vm-firstboot/SOURCES/Brewfile); consumed by `brew bundle` on first boot
- **npm globals** — `@anthropic-ai/claude-code`, `@google/gemini-cli` (hardcoded in `firstboot.sh` — no signed RPM source)

Progress: `journalctl -u bastion-vm-firstboot -f` on the VM.

## Release Flow

```bash
make bump-minor       # spec + blueprint version lockstep → runs check-versions
make changelog        # regenerate CHANGELOG.md from Conventional Commits
git commit -am "chore(release): $(yq -p toml '.version' blueprint.toml)"
git tag "v$(yq -p toml '.version' blueprint.toml)"
```
