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

## Bless Procedures

After intentional size or performance changes, promote the new baselines so CI doesn't false-positive:

```bash
make image            # build fresh image
make bless-size       # promote image bytes → tests/size.baseline
make smoke            # confirm firstboot passes; captures boot timing
make baseline-record  # append build_secs, image_bytes, firstboot_secs, secondboot_secs to tests/baselines.csv
```

Run all four after any batch of changes that touches packages, blueprint, or firstboot logic. Commit `tests/size.baseline` and `tests/baselines.csv` together so the baselines travel with the code.

**When a regression fires:**
- `make check-size` fails → image grew past budget. Investigate with `make diff-packages`. Trim packages or run `make bless-size` if the growth is intentional (document why in the commit message).
- `make smoke` boot-time regression → `tests/baselines.csv` shows firstboot or secondboot time exceeded threshold. Check `journalctl -u bastion-vm-firstboot` inside the VM for slow steps.

## Boot-Time Regression Tracking

`tests/baselines.csv` records per-commit performance baselines with these columns:

```
commit,build_secs,image_bytes,firstboot_secs,secondboot_secs
```

`make baseline-record` appends a row after a successful `make smoke` run. The file is committed to the repo so CI can detect regressions against the prior row.

**What each column means:**

| Column | What it measures | Notes |
|--------|-----------------|-------|
| `build_secs` | Wall time for `make image` | Varies with host; useful for trend, not absolute comparison |
| `image_bytes` | Compressed `.raw.zst` size | Also tracked by `tests/size.baseline`; redundant for convenience |
| `firstboot_secs` | Time from SSH-up to firstboot `done` sentinel | Dominated by `brew bundle` (20+ min expected) |
| `secondboot_secs` | Time from SSH-up to shell-ready on second boot | Firstboot already done; measures baseline startup |

A jump in `firstboot_secs` usually means a new brew formula or npm package was added. A jump in `secondboot_secs` usually means a new systemd unit or startup script was added.

## Auditd Review

Audit logs land at `/var/log/audit/audit.log` on the VM guest. Query by rule key:

```bash
# Any process that ran as root (effective UID 0)
ausearch -k root-exec

# Any write or attribute change to /etc/sudoers
ausearch -k sudoers
```

**Coverage reminder:** auditd rules use `-F euid=0`. Anything run by `user` (UID 1000) — including `firstboot.sh`, `brew`, and the Bastion Agent itself — does not appear in the `root-exec` trail. Audit logs cover post-boot privileged activity only.

For persistent monitoring: `systemctl status auditd` and `journalctl -u auditd`.

## Post-First-Boot SBOM

Generate and sign the SBOM after building the image:

```bash
make sbom             # runs syft on output/fedora-43-devbox.raw.zst; emits CycloneDX JSON + SPDX tag-value
                      # outputs: output/fedora-43-devbox.cdx.json + output/fedora-43-devbox.spdx
make sign             # cosign keyless-sign SHA256SUMS (covers image + RPM + SBOM)
make attest           # cosign attest-blob SLSA v1 provenance for image
```

Artifacts land in `output/`. The SBOM is a point-in-time snapshot of what RPM and brew packages were present in the built image — it does **not** cover npm globals (installed post-firstboot) or brew packages installed after the image was scanned.

Inspect the SBOM:

```bash
cat output/fedora-43-devbox.cdx.json | jq '.components[] | {name, version}'
```

Verify the signature and provenance: see **Verifying Artifacts** in `SECURITY.md`.
