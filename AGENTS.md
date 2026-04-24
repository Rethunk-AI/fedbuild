# fedbuild

Builds reproducible Fedora 43 VM images for Bastion. **Multi-variant** since 2026-04-17 (`refactor(variants)` commit `22681d5`). One repo, one pipeline, multiple shipping artifacts driven by `make VARIANT=<name>`.

Default variant: `devbox` — Bastion Agent (Claude Code, Gemini CLI) sandbox with Homebrew + dev toolchain. Other variants (e.g. `bastion-edge`) live as sibling subdirectories under `variants/`.

## Variants

| Variant | Purpose | Built by |
|---------|---------|----------|
| `devbox` | Bastion Agent (Claude Code, Gemini CLI) sandbox — Homebrew + dev toolchain | `make` (default) |
| `bastion-edge` | Field-deployable image with `bastion-theatre-manager` daemon pre-enabled (Fedora 43 minimal, no Homebrew, no dev tools) | `make VARIANT=bastion-edge image` |

See [`README.md`](README.md) § Variants for the same table in operator-facing docs. Per-variant inputs and smoke details live in `variants/<name>/README.md`.

## Variant dispatch

```bash
make variants               # list known variants with one-line description
make                        # default: VARIANT=devbox
make VARIANT=bastion-edge   # build the bastion-edge variant (Fedora 43 minimal + bastion-theatre-manager)
```

Every variant gets the same pipeline for free: reproducible RPM (SOURCE_DATE_EPOCH), createrepo with optional `extra-rpms/` pickup, image-builder, cosign-signed SHA256SUMS, syft SBOM, SLSA v1 provenance, size budget, smoke test.

## Commands

All targets accept `VARIANT=<name>` (or default to `devbox`).

```bash
make                  # build RPM + local yum repo (default goal: repo)
make rpm              # build firstboot RPM only
make repo             # copy RPM (+ extra-rpms/) into repo/$(VARIANT) and createrepo
make image            # build Fedora 43 VM image (requires sudo)
make check            # fast pre-push: shellcheck + TOML + actionlint + check-versions + check-settings
make check-versions   # assert spec Version matches blueprint version (this variant)
make check-versions-all  # check-versions across every variants/<name>
make check-settings   # JSON-schema validate baked agent-settings.json (devbox only; skipped if absent)
make check-size       # fail if image > baseline * (1 + SIZE_BUDGET_PCT/100)
make bless-size       # promote current image size to variants/<variant>/tests/size.baseline
make bless-boot-time  # FIRSTBOOT_SECS=<n> make bless-boot-time → variants/<variant>/tests/boot-time.baseline
make shellcheck       # shellcheck this variant's SOURCES/*.sh + tests/*.sh
make lint             # rpmlint on built RPM
make validate         # check blueprint syntax, SSH key substitution, image-builder target
make smoke            # boot VM (KVM) and run variant-specific smoke (variants/<variant>/tests/smoke.sh)
make run-vm           # single-VM umbrella-root convenience target — defaults to VM_VARIANT=bastion-core
make stop-vm          # stop the umbrella-root managed VM
make destroy-vm       # stop + delete output/<variant>/run
make vm-status        # show VM state via the umbrella-root manager
make ssh-vm           # SSH via the umbrella-root manager
make smoke-rerun      # re-run smoke against existing image (idempotency)
make diff-packages    # blueprint-declared RPMs vs rpm -qa on a running VM
make sign             # cosign keyless-sign $(OUTDIR)/SHA256SUMS
make verify           # cosign verify SHA256SUMS (CERT_IDENTITY + CERT_OIDC_ISSUER)
make sbom             # syft SBOM (CycloneDX + SPDX) from built image
make attest           # cosign attest-blob SLSA v1 provenance for image
make cve-scan         # grype scan SBOM with this variant's cve-allowlist.yaml
make brew-drift       # OLD=… NEW=… diff two brew-versions.txt snapshots (devbox only)
make baseline-record  # BUILD_SECS=… IMAGE_BYTES=… FIRSTBOOT_SECS=… SECONDBOOT_SECS=… → variants/<variant>/tests/baselines.csv
make check-boot-time  # fail if latest firstboot_secs > median(last 5) * 1.2
make clean            # rm rpmbuild/ + repo/$(VARIANT) + this variant's blueprint.effective.toml
make distclean        # clean + rm output/$(VARIANT)
make deps             # install createrepo_c (sudo)
make bump-patch       # bump Z in X.Y.Z for $(VARIANT) — spec + blueprint lockstep
make bump-minor       # bump Y, reset Z=0
make bump-major       # bump X, reset Y=0, Z=0
make install-hooks    # install pre-commit hooks
make changelog        # git-cliff regenerate CHANGELOG.md from Conventional Commits
make help             # list available targets
../vm.sh up                          # canonical local stack entrypoint (core + edge + /workspace theatre)
../vm.sh up --variant bastion-core   # single-VM escape hatch
```

## Architecture

```
fedbuild/
  Makefile                                  # VARIANT dispatch; all targets variant-scoped
  variants/<name>/                          # one subdirectory per shipping artifact
    variant.mk                              # PKG_NAME, PKG_BLUEPRINT_NAME, EXTRA_REPOS, PKG_IMAGE_FORMAT
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
  keys/
    authorized_key                          # SSH pubkey (gitignored) — required by make image
  .github/workflows/
    ci.yml                                  # fedora:43 matrix per variant
  schemas/
    agent-settings.schema.json              # JSON Schema for baked ~/.claude/settings.json
  cliff.toml                                # git-cliff config for make changelog
  repo/<variant>/                           # per-variant local yum repo (createrepo output)
  rpmbuild/                                 # rpmbuild working tree (shared, isolated by package name)
  output/<variant>/                         # per-variant built VM images
  specs/active/                             # active work specs
```

## Variant anatomy (extended)

Each `variants/<name>/variant.mk` declares:
- `PKG_NAME` — name of the firstboot RPM produced for this variant (must match the spec `Name:`)
- `PKG_BLUEPRINT_NAME` — name field in the variant's `blueprint.toml`
- `PKG_IMAGE_FORMAT` — image-builder output format (e.g. `minimal-raw-zst`)
- `EXTRA_REPOS` — additional `--extra-repo <url>` flags passed to `image-builder`

The root Makefile errors out if `variants/$(VARIANT)/variant.mk` is missing, so a typo in `VARIANT=` fails fast.

`extra-rpms/` is the pickup point for upstream-built RPMs. Example: the `bastion-edge` variant consumes two version-matched RPMs from the [bastion-edge source repo](https://github.com/Rethunk-Tech/bastion-edge) — `bastion-theatre` (Node payload) + `bastion-theatre-manager` (daemon) — produced via `yarn release:rpm:theatre` + `yarn release:rpm:theatre-manager`. Drop them in, optionally pin sha256s in `EXPECTED_SHA256`, then `make image`.

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
- RPM builds reproducible *within a single tree* (`SOURCE_DATE_EPOCH` = commit ctime; byte-identical across rebuilds in the same `_sourcedir`). **Cross-tree byte-identity is not achievable — see § Reproducibility scope (BDA) below.**
- Image size budget enforced by `make check-size` against `tests/size.baseline` (run `make bless-size` after intentional size changes)
- Brew formulae list lives in `SOURCES/Brewfile` (consumed by `brew bundle` in firstboot) — do not hardcode brew packages in `firstboot.sh`
- `make smoke` requires KVM, `qemu-system-x86_64`, `zstd`, and a built image in `output/`
- smoke failures: if SSH came up, firstboot journal is captured to `$OUTDIR/smoke-fail.log` (override via `FAIL_LOG=...`)
- `tests/baselines.csv` records per-commit build/boot timing; commit it alongside `tests/size.baseline` after blessing
- `Brewfile.lock.json` dumped post-firstboot is a record of what installed, NOT a pin — next boot re-resolves `latest`
- `auditd` root-exec rule covers euid=0 only; firstboot/brew/agent activity (as `user`) is not audited
- SLSA provenance (`make attest`) is Build L1 — no hardened builder; authenticates artifact identity, not build isolation
- Git SSH signing: firstboot generates per-VM ed25519 key at `~user/.ssh/id_ed25519_signing`, sets `gpg.format=ssh`+`commit.gpgsign=true`+`tag.gpgsign=true` in user-level gitconfig, and appends pubkey to `~user/.ssh/allowed_signers`. `git log --show-signature` verifies locally. Collaborators need the pubkey in their own allowed_signers to verify remotely.
- `agent-settings.json` is schemaVersion-pinned (currently 1). Bump both `schemaVersion` in the JSON and the filename fragment in `schemas/agent-settings.v1.schema.json` together on incompatible revisions.
- `tests/cve-allowlist.yaml` is grype's native config; entries require rationale + owner + review date. `make cve-scan` fails on any critical CVE not listed.
- `tests/brew-drift.sh OLD NEW` diffs two `brew-versions.txt` snapshots (firstboot emits `/var/lib/bastion-vm-firstboot/brew-versions.txt` alongside `Brewfile.lock.json`).

## Reproducibility scope (BDA — 2026-04-17)

**One-line rule:** fedbuild guarantees *same-tree determinism*, not *cross-tree byte-identity*. Don't chase the latter.

**What was tried and failed:** During the `multi-variant-refactor` spec execution, an attempt was made to verify that moving `bastion-vm-firstboot/` into `variants/devbox/bastion-vm-firstboot/` produced a byte-identical RPM (same SHA256). It did not — and that was the correct outcome, but only obvious in hindsight.

**Why it can't work:** rpmbuild bakes the absolute `_sourcedir` path into the captured `%install` scriptlet that is stored in the SRPM header. That header is then hashed into the binary RPM's `Sourcesigmd5`, which is hashed into `Sha1header` and `Sha256header`. Net effect: changing the SOURCES path (whether by `git mv` or by cloning the repo to a different directory) cascades into different RPM bytes, even when SDE, git SHA, `_buildhost`, payload content, and SOURCES mtimes are all identical.

**Concrete evidence captured:**
- Pre-refactor (`bastion-vm-firstboot/SOURCES/`, SDE=1776424334): SHA256 `9473bc9f144af4af3b5c7d0f3f363e2ea5102d93a8445d266bb5be519afafa45`
- Post-refactor (`variants/devbox/bastion-vm-firstboot/SOURCES/`, SDE=1776424334): SHA256 `085c67f310e284e2049ded8d01750dbebeef7a0119fe8fcaa9117a7112f95203`
- Binary RPM payload (cpio) sha256: **identical** in both — `5b4bdd3b25b0c9200d034fb1a0862decfd9d92d1ec61cc56b2f23ab9d9a8b2dd`
- SRPM payload (cpio) sha256: **identical** in both — `b595095720d73b99f74ab269985271caf5230d34f81734098beea9bfc45cbb42`
- The only divergent header tags: `Sigmd5`, `Sha1header`, `Sha256header`, `Sourcesigmd5` — all derived hashes
- `strings rpm | grep _sourcedir-path` showed the captured `%install` script with absolute paths

**What this means in practice:**
- Two developers cloning fedbuild to different paths (`/home/alice/fedbuild` vs `/home/bob/fedbuild`) will always produce different RPM bytes. This is normal for RPM and not a fedbuild bug.
- A renamed-in-place file move (this refactor) shifts the path the same way and produces the same kind of difference.
- Cosign signs the SHA256SUMS of artifact bytes, so the signature is path-dependent too. Re-sign per build.

**What IS guaranteed (the actual reproducibility property):**
- Same tree, same git SHA, same SDE, same `_sourcedir` → same RPM bytes across rebuilds. Verified.
- Payload content is path-independent (the cpio archive of installed files doesn't depend on `_sourcedir`).

**Anti-patterns to avoid in future fedbuild work:**
- Don't gate refactors on cross-tree RPM byte-identity. Use rebuild-determinism instead (`make rpm; sha256sum; make clean; make rpm; sha256sum; diff`).
- Don't chase mtime normalization (`touch -d "@$SDE"` on SOURCES) hoping it'll close the gap — `clamp_mtime_to_source_date_epoch 1` already handles installed-file mtimes; the SRPM's path embedding is what differs and `touch` can't fix that.
- Don't compare RPMs built from different filesystem locations (`/var/tmp/foo` vs `/home/x/foo`) and expect equality. The `_topdir` and `_sourcedir` are baked in.

**Before chasing reproducibility "issues" in future work, ask:** is this a real reproducibility regression (same tree, same inputs, different output → bug), or a path-sensitivity rediscovery (different tree, different `_sourcedir`, different output → expected)? If the latter, stop — RPM is doing its thing.

## CI

`.github/workflows/ci.yml` runs on push/PR to `main` in `fedora:43` container:
- shellcheck (all `SOURCES/*.sh`)
- rpmlint (built RPM)
- actionlint (pinned v1.7.7)
- TOML syntax (`yq`)
- `make check-versions` (spec ↔ blueprint parity)
- `make check-settings` (JSON-schema validate `agent-settings.json`)

Local equivalent: `make check`.
