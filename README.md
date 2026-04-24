# fedbuild

Reproducible Fedora 43 VM image builder. One pipeline; multiple variants for distinct shipping artifacts.

## Variants

| Variant | Purpose | Built by |
|---------|---------|----------|
| `devbox` | Bastion Agent (Claude Code, Gemini CLI) sandbox — Homebrew + dev toolchain | `make` (default) |
| `bastion-edge` | Field-deployable image with `bastion-theatre-manager` daemon pre-enabled (Fedora 43 minimal, no Homebrew, no dev tools) | `make VARIANT=bastion-edge image` |

Each variant produces:
- A small **firstboot RPM** (systemd oneshot for first-boot bootstrap)
- A bootable **Fedora 43 image** (`.raw.zst`) built via `image-builder`

**Supply chain:** reproducible same-tree RPMs (`SOURCE_DATE_EPOCH`), SHA256SUMS cosign-signed (keyless Sigstore), per-variant size budget enforced, optional `extra-rpms/` pickup with `EXPECTED_SHA256` verification, syft SBOM, SLSA v1 provenance.

## Quick Start

```bash
make deps                                                # install createrepo_c (once)
cp ~/.ssh/id_ed25519.pub keys/authorized_key

# Devbox (default — Bastion Agent sandbox):
make && make image && make smoke

# Other variants:
make VARIANT=bastion-edge && make VARIANT=bastion-edge image && make VARIANT=bastion-edge smoke
```

`make variants` lists all available variants. `make help` lists all targets.

Persistent VM lifecycle is standardized under the umbrella-root **`vm.sh`**
script. From `fedbuild/`, run `../vm.sh <up|down|destroy|status|ssh>`.

- No-arg `../vm.sh up` now boots the local Bastion stack: `bastion-core`,
  `bastion-edge`, automatic TheatreManager enrollment into Core, and a Theatre
  rooted at `/workspace`.
- No-arg `../vm.sh status` prints the operator-ready summary: Bastion URL,
  WebSocket URL, `BASTION_WS_TOKEN`, TheatreManager, Theatre, SSH entrypoints,
  bootstrap path, and serial logs.
- `../vm.sh ssh` still defaults to `bastion-core`.
- Use `--variant <name>` when you intentionally want a single VM instead of the
  full stack.

Single-VM `bastion-core` still captures the regenerated bootstrap identity in
`output/bastion-core/run/bootstrap.env` and prints the Bastion URL plus
`BASTION_WS_TOKEN` in the terminal summary. `devbox` still prepares a reusable
Bastion dev bootstrap env and prints the WS token plus bootstrap-env guidance;
if Bastion is already running manually inside the VM, rerunning `up` also
prints the local tunnel details.

`make run-vm` remains a single-VM convenience target: it passes an explicit
`VM_VARIANT` (default `bastion-core`) into `vm.sh`, so use no-arg `../vm.sh`
when you want the full stack.

## Documentation

| Doc | Audience |
|-----|----------|
| **[HUMANS.md](HUMANS.md)** | Quick start, release flow, what first-boot installs |
| **[AGENTS.md](AGENTS.md)** | LLM reference: commands, architecture, blueprint format, gotchas, **reproducibility scope (BDA)** |
| **[CONTRIBUTING.md](CONTRIBUTING.md)** | PR checklist, file-change map, commit style |
| **[CHANGELOG.md](CHANGELOG.md)** | Auto-generated from Conventional Commits (`make changelog`) |
| **[SECURITY.md](SECURITY.md)** | Vulnerability reporting |
| **[specs/](specs/)** | Active and completed work specs |

## Variant anatomy

```
variants/<name>/
  variant.mk                              # PKG_NAME, PKG_BLUEPRINT_NAME, EXTRA_REPOS, …
  blueprint.toml                          # osbuild blueprint
  <pkg-name>-firstboot/
    SPECS/<pkg-name>-firstboot.spec
    SOURCES/                              # firstboot.sh + service unit + variant-specific assets
  tests/
    smoke.sh                              # variant-specific QEMU/KVM assertions
    size.baseline                         # per-variant image-bytes ceiling
    boot-time.baseline                    # per-variant firstboot-secs reference
    baselines.csv                         # per-commit timing history
    cve-allowlist.yaml                    # optional, falls back to repo-root default
  extra-rpms/                             # optional: operator-supplied upstream RPMs
    EXPECTED_SHA256                       # optional sha256sum manifest, verified pre-createrepo
  README.md                               # what this variant produces, its inputs, its smoke
```

Adding a new variant: drop `variants/<name>/` with the above contents, add a row to the variant table above, and (when ready) add `<name>` to the CI matrix in `.github/workflows/ci.yml`.

## License

MIT — Copyright (c) 2026 Rethunk.Tech, LLC
