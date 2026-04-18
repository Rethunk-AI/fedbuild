# Tasks — fedbuild multi-variant refactor

Companion to [`spec.md`](./spec.md) and [`plan.md`](./plan.md). Two phases: **A** (structural refactor, agent-executable), **B** (bastion-edge variant, human-gated for sudo+KVM).

## Phase A — Structural refactor

### A1 — Baseline capture
- [ ] Run `make clean && make rpm` on current tree; record RPM SHA256 in operator scratch (not committed)
- [ ] Record current git SHA for post-refactor comparison

### A2 — Move devbox files into `variants/devbox/`
- [ ] `git mv blueprint.toml variants/devbox/blueprint.toml`
- [ ] `git mv bastion-vm-firstboot/ variants/devbox/bastion-vm-firstboot/`
- [ ] `git mv tests/size.baseline tests/devbox/size.baseline`
- [ ] `git mv tests/boot-time.baseline tests/devbox/boot-time.baseline`
- [ ] `git mv tests/baselines.csv tests/devbox/baselines.csv`
- [ ] `git mv tests/cve-allowlist.yaml tests/devbox/cve-allowlist.yaml`
- [ ] `git mv tests/smoke.sh variants/devbox/tests/smoke.sh`
- [ ] Keep `tests/{smoke-rerun.sh,diff-packages.sh,brew-drift.sh}` at root (generic helpers)
- [ ] Keep `schemas/` at root

### A3 — Create `variant.mk` convention
- [ ] Write `variants/devbox/variant.mk` with PKG_NAME, PKG_BLUEPRINT_NAME, PKG_IMAGE_FORMAT, EXTRA_REPOS

### A4 — Parameterize root Makefile
- [ ] Add `VARIANT ?= devbox`, `VARIANT_DIR`, `VARIANT_TESTS` variables near top
- [ ] `-include $(VARIANT_DIR)/variant.mk` after variable declarations
- [ ] Re-point `REPODIR`, `OUTDIR`, `SPECFILE`, `SRCDIR`, `BLUEPRINT`, `BLUEPRINT_EFFECTIVE`, `SIZE_BASELINE`, `BOOT_TIME_BASELINE`, `BASELINES_CSV` to variant-scoped paths
- [ ] `image` target uses `$(EXTRA_REPOS)` from variant.mk instead of hardcoded flags
- [ ] `smoke` target invokes `bash $(VARIANT_DIR)/tests/smoke.sh $(OUTDIR)`
- [ ] `shellcheck` target globs `$(VARIANT_DIR)/**/*.sh` + `tests/*.sh`
- [ ] Add `check-versions-all` fleet convenience target (loops variants/)
- [ ] Add `variants` listing target (prints each variant dir + its description from README first line)
- [ ] Add sanity check: abort early if `$(VARIANT_DIR)/variant.mk` missing

### A5 — (folded into A2)

### A6 — Documentation rewrite
- [ ] `README.md`: variant table; "Two artifacts" → "Per-variant artifacts"
- [ ] `AGENTS.md`: multi-variant framing in opening paragraph; Commands section updated; add Variant Anatomy section
- [ ] `HUMANS.md`: Quick Start mentions `VARIANT` default; add "Multiple Variants" subsection
- [ ] `CONTRIBUTING.md`: `make VARIANT=devbox check && make VARIANT=bastion-edge check` in pre-PR checklist

### A7 — CI matrix
- [ ] `.github/workflows/ci.yml`: `strategy.matrix.variant: [devbox, bastion-edge]` (edge row initially skipped via `if: matrix.variant != 'bastion-edge'` until B lands, then unskipped)
- [ ] `make VARIANT=$${{ matrix.variant }} check/rpm/lint` per matrix cell
- [ ] `actionlint .github/workflows/ci.yml` green

### A8 — Byte-fidelity verify (HG-1)
- [ ] Run `make clean && make VARIANT=devbox rpm`
- [ ] Diff RPM SHA256 vs A1 baseline — MUST match exactly
- [ ] If mismatch: diagnose + fix before landing Phase A

### Phase A commit
- [ ] Single commit titled `refactor(variants): introduce variants/<name>/ layout`; body references this spec
- [ ] Commit includes all moves + Makefile edits + doc rewrites + CI matrix change

## Phase B — bastion-edge variant

### B1 — Skeleton
- [ ] `mkdir -p variants/bastion-edge/{bastion-edge-firstboot/SPECS,bastion-edge-firstboot/SOURCES,tests,extra-rpms}`
- [ ] `variants/bastion-edge/extra-rpms/.keep` + `variants/bastion-edge/.gitignore` excluding `*.rpm`
- [ ] `variants/bastion-edge/variant.mk`
- [ ] `variants/bastion-edge/README.md`

### B2 — Blueprint
- [ ] Write `variants/bastion-edge/blueprint.toml` — Fedora 43 minimal + bastion-edge runtime deps
- [ ] Version `0.1.0` initial
- [ ] No Homebrew, no dev packages
- [ ] `[customizations.services] enabled = ["sshd", "bastion-edge", "bastion-edge-firstboot"]`
- [ ] `[customizations.user]` with `CHANGEME` placeholder (same substitution pattern as devbox)

### B3 — Firstboot RPM
- [ ] Write `bastion-edge-firstboot/SPECS/bastion-edge-firstboot.spec` (minimal, mirrors devbox firstboot spec structure)
- [ ] Write `bastion-edge-firstboot/SOURCES/firstboot.sh` — reads cidata for edge-id, writes to `/var/lib/bastion-edge/edge-id`
- [ ] Write `bastion-edge-firstboot/SOURCES/bastion-edge-firstboot.service` — oneshot, After=cloud-init + bastion-edge
- [ ] `shellcheck` firstboot.sh
- [ ] `check-versions` green

### B4 — Smoke
- [ ] Write `variants/bastion-edge/tests/smoke.sh` based on `variants/devbox/tests/smoke.sh`
- [ ] Assertions: `systemctl is-active bastion-edge`, firstboot done, edge-id populated, no Homebrew/Claude, reboot persistence

### B5 — Docs + extra-rpms workflow
- [ ] `variants/bastion-edge/README.md` explains the `yarn release:rpm` → `extra-rpms/` flow
- [ ] Update top-level `README.md` variant table with bastion-edge row
- [ ] Update `AGENTS.md` Variants section

### B6 — HG-2: Image build (human)
- [ ] Human: `cp ~/.ssh/id_ed25519.pub keys/authorized_key`
- [ ] Human: drop a current `bastion-edge-*.rpm` into `variants/bastion-edge/extra-rpms/`
- [ ] Human: `make VARIANT=bastion-edge rpm` — produces `bastion-edge-firstboot-*.rpm`
- [ ] Human: `make VARIANT=bastion-edge image` — produces `output/bastion-edge/fedora-43-bastion-edge.raw.zst`

### B7 — HG-3: Smoke (human)
- [ ] Human: `make VARIANT=bastion-edge smoke` — KVM boot + assertion pass

### B8 — HG-4: Bless baselines (human)
- [ ] Human: `make VARIANT=bastion-edge bless-size` (after HG-3)
- [ ] Human: `FIRSTBOOT_SECS=<observed> make VARIANT=bastion-edge bless-boot-time`
- [ ] Human: `BUILD_SECS=… IMAGE_BYTES=… FIRSTBOOT_SECS=… SECONDBOOT_SECS=… make VARIANT=bastion-edge baseline-record`
- [ ] Commit `tests/bastion-edge/{size.baseline,boot-time.baseline,baselines.csv}`

### Phase B commits
- [ ] `feat(edge): variants/bastion-edge/ blueprint + firstboot skeleton` (B1–B3)
- [ ] `test(edge): variant smoke assertions` (B4)
- [ ] `docs(edge): README + AGENTS variant index entry` (B5)
- [ ] `test(edge): baseline size + boot-time from first successful build` (B8, human-authored)
- [ ] CI matrix `if:` filter dropped in a final commit once B7 green

## Signoff
- [ ] Downstream Bastion `specs/active/packaging-vm-retirement/` unblocked (fedbuild Phase B green)
- [ ] Bastion meta pins fedbuild submodule at post-B landing SHA
