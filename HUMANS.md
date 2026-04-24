# fedbuild

## Quick Start

```bash
make deps                                  # install createrepo_c (once)
cp ~/.ssh/id_ed25519.pub keys/authorized_key   # place your SSH pubkey
make                                       # build RPM + local yum repo (default = devbox variant)
make image                                 # build Fedora 43 VM image (needs sudo);
                                           # emits .raw.zst (field dd) + .qcow2 (ADCON runtime)
make smoke                                 # boot + assert firstboot (needs KVM)
make publish-mirror                        # stage qcow2 + SBOM + provenance for ADCON mirror
```

`make help` lists every target. `make variants` lists known variants. Full reference + gotchas in **[AGENTS.md](AGENTS.md)**.

## VM lifecycle

Use the standardized lifecycle entrypoint:

```bash
../vm.sh up                             # default local stack: bastion-core + bastion-edge + /workspace theatre
../vm.sh status                         # stack status and access summary
../vm.sh ssh                            # SSH to bastion-core
../vm.sh down                           # stop the stack
../vm.sh destroy                        # destroy stack run state

../vm.sh up --variant bastion-core      # single-VM escape hatch
../vm.sh status --variant bastion-core
../vm.sh ssh --variant bastion-core
```

Equivalent `make` targets exist via `make run-vm`, `make stop-vm`, `make destroy-vm`,
 `make vm-status`, and `make ssh-vm`. Those `make` runtime targets still target
 a single VM via `VM_VARIANT` (default `bastion-core`); use the no-arg
 `../vm.sh` actions when you want the full local stack.

- `up` defaults to a **fresh** `output/<variant>/run/` state. Set `VM_REUSE_STATE=1`
  (or pass `--reuse-state`) only when you intentionally want to keep the prior
  overlay and firmware vars.
- For the default stack, `up` boots `bastion-core` and `bastion-edge`, enrolls
  the TheatreManager into Core, creates or reuses a Theatre at `/workspace`,
  captures the regenerated Core bootstrap identity into
  `output/bastion-core/run/bootstrap.env`, and prints the Bastion URL,
  WebSocket URL, WS token, TheatreManager, Theatre, SSH entrypoints, and serial
  log paths in the terminal summary.
- For single-VM `--variant bastion-core`, `up` still captures the regenerated
  bootstrap identity (`BASTION_SAI_*`, `BASTION_WS_TOKEN`) into
  `output/bastion-core/run/bootstrap.env` after firstboot completes, and prints
  the Bastion URL plus WS token in the terminal summary.
- For `devbox`, `up` prepares a Bastion dev bootstrap env at
  `~/.config/bastion/bootstrap.env` inside the VM, mirrors it to
  `output/devbox/run/bootstrap.env`, and prints the WS token plus bootstrap-env
  guidance in the terminal summary. If you manually start Bastion inside the VM,
  rerunning `up` also prints the local tunnel details.
- `devbox` uses the SSH key baked from `keys/authorized_key`; set `VM_SSH_KEY=/path/to/private-key`
  if the script cannot infer the matching private key automatically.

## Multiple variants

fedbuild builds multiple Fedora 43 image variants from one repo. The default `devbox` variant builds a Bastion Agent sandbox; other variants (e.g. `bastion-edge`) live as siblings under `variants/`. Pick one via `VARIANT=`:

```bash
make VARIANT=devbox            # default (omit VARIANT for the same effect)
make VARIANT=bastion-edge image  # build the bastion-edge image (when defined)
make variants                  # list all known variants
```

Per-variant state (blueprint, firstboot RPM, baselines, smoke assertions, optional `extra-rpms/` upstream pickup) lives under `variants/<name>/`. Per-variant build outputs land in `output/<name>/`. Adding a new variant: see [AGENTS.md § Variant anatomy](AGENTS.md#variant-anatomy-extended).

## Publishing to the ADCON authoritative-mirror

ADCON runtime VMs (the live VMs TheatreManagers + Theatres run as) boot from fedbuild qcow2 images served through bastion-core's authoritative-mirror. `make publish-mirror` stages the current variant's build output into the layout the mirror's route parser expects:

```
$(MIRROR_DIR)/vm-images/$(VARIANT)/$(VERSION)/
├── <variant>-<version>-x86_64.qcow2
├── <qcow2>.sha256
├── SHA256SUMS[.sig,.pem]
├── sbom.cdx.json / sbom.spdx.json
└── provenance.json[.sig,.pem]
```

Defaults: `MIRROR_DIR=$(OUTDIR)/mirror-stage` (self-contained inside `output/<variant>/`). For production, override: `MIRROR_DIR=/var/lib/bastion/adcon-mirror make VARIANT=bastion-edge publish-mirror`. Aim bastion-core's `BASTION_ADCON_MIRROR_CACHE_DIR` at the same path.

bastion-core's `GrpcQemuAdapter` resolves the runtime image from `BASTION_QEMU_IMAGE_DIR/<variant>.qcow2` (default `/var/lib/bastion/qemu/images`). After `make publish-mirror`, symlink (or copy) the landed qcow2 into that directory:

```bash
sudo ln -sfn /var/lib/bastion/adcon-mirror/vm-images/bastion-edge/0.1.0/bastion-edge-0.1.0-x86_64.qcow2 \
             /var/lib/bastion/qemu/images/bastion-edge.qcow2
```

Full spec: meta-repo `specs/active/adcon-runtime-vm-fedbuild-migration/spec.md`.

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
