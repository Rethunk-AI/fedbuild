# fedbuild

Reproducible Fedora 43 VM image builder. One pipeline; multiple variants for distinct shipping artifacts.

## Variants

| Variant | Purpose | Built by |
|---------|---------|----------|
| `devbox` | Bastion Agent (Claude Code, Gemini CLI) sandbox — Homebrew + dev toolchain | `make` (default) |
| `bastion-edge` | Field-deployable image with `bastion-edge` service pre-enabled | `make VARIANT=bastion-edge image` *(coming in Phase B)* |

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
