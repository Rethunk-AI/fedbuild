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
make check-size      # fail if image > baseline * (1 + SIZE_BUDGET_PCT/100)  [default 10%]
make bless-size      # promote current image size to tests/size.baseline
make shellcheck  # shellcheck all shell scripts in SOURCES
make lint        # rpmlint on built RPM
make validate    # check TOML syntax + SSH key + image-builder target
make smoke       # boot VM in QEMU/KVM and assert firstboot + tool presence (requires built image)
make diff-packages # drift: declared RPMs (blueprint) vs rpm -qa on running VM
make sign        # cosign keyless-sign output/SHA256SUMS (Sigstore OIDC)
make verify      # cosign verify SHA256SUMS (set CERT_IDENTITY + CERT_OIDC_ISSUER)
make clean       # rm rpmbuild/ and repo/
make distclean   # clean + rm output/
make deps        # install createrepo_c if missing
make bump-patch  # bump Z in X.Y.Z (spec + blueprint lockstep) → runs check-versions
make bump-minor  # bump Y, reset Z=0
make bump-major  # bump X, reset Y=0, Z=0
make install-hooks  # install pre-commit hooks (requires pip install pre-commit)
make changelog      # regenerate CHANGELOG.md from Conventional Commits (needs brew install git-cliff)
make help        # print target descriptions
make sbom        # generate syft SBOM (CycloneDX JSON + SPDX) from built image → output/
make attest      # cosign attest-blob SLSA v1 provenance for image (requires OIDC session)
make smoke-rerun # re-run smoke test against existing image without rebuilding
make baseline-record  # append build/boot timing row to tests/baselines.csv (run after make smoke)
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
      Brewfile → /usr/share/bastion-vm-firstboot/Brewfile  # brew formulae list (brew bundle)
  tests/
    smoke.sh                              # QEMU/KVM boot + SSH + tool-presence assertions
    diff-packages.sh                      # blueprint vs rpm -qa drift report (used by `make diff-packages`)
    size.baseline                         # image-size budget baseline (bytes, raw.zst)
  keys/
    authorized_key                        # SSH pubkey (gitignored) — required by `make image`
  .github/workflows/
    ci.yml                                # fedora:43 lint: shellcheck + rpmlint + actionlint + TOML
  schemas/
    agent-settings.schema.json            # JSON Schema (2020-12) for baked ~/.claude/settings.json
  .pre-commit-config.yaml                 # local hooks mirroring `make check`; install: make install-hooks
  cliff.toml                              # git-cliff config for `make changelog`
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
