# Tasks — fedbuild multi-variant refactor

Companion to [`spec.md`](./spec.md) and [`plan.md`](./plan.md). Two phases: **A** (structural refactor, agent-executable), **B** (bastion-edge variant, human-gated for sudo+KVM).

## Phase A — Structural refactor

### A1 — Baseline (rebuild-determinism only; no cross-tree comparison)
- [x] BDA finding recorded in fedbuild AGENTS.md § Reproducibility scope: cross-tree byte-identity is not achievable (RPM embeds `_sourcedir` path); same-tree determinism is the actual invariant.
- [x] Record pre-refactor SDE for documentation only: `git log -1 --format=%ct -- bastion-vm-firstboot/SPECS/...` → 1776424334 (captured 2026-04-17)

### A2 — Move devbox files into `variants/devbox/`
- [x] `git mv blueprint.toml variants/devbox/blueprint.toml`
- [x] `git mv bastion-vm-firstboot/ variants/devbox/bastion-vm-firstboot/`
- [x] `git mv tests/size.baseline variants/devbox/tests/size.baseline`
- [x] `git mv tests/boot-time.baseline variants/devbox/tests/boot-time.baseline`
- [x] `git mv tests/baselines.csv variants/devbox/tests/baselines.csv`
- [x] `git mv tests/cve-allowlist.yaml variants/devbox/tests/cve-allowlist.yaml`
- [x] `git mv tests/smoke.sh variants/devbox/tests/smoke.sh`
- [x] Keep `tests/{smoke-rerun.sh,diff-packages.sh,brew-drift.sh}` at root (generic helpers)
- [x] Keep `schemas/` at root

### A3 — Create `variant.mk` convention
- [x] Write `variants/devbox/variant.mk` with PKG_NAME, PKG_BLUEPRINT_NAME, PKG_IMAGE_FORMAT, EXTRA_REPOS

### A4 — Parameterize root Makefile
- [x] Add `VARIANT ?= devbox`, `VARIANT_DIR := $(FEDBUILD)/variants/$(VARIANT)`, `VARIANT_TESTS := $(VARIANT_DIR)/tests`
- [x] `-include $(VARIANT_DIR)/variant.mk` after variable declarations
- [x] Re-point `REPODIR`, `OUTDIR`, `SPECFILE`, `SRCDIR`, `BLUEPRINT`, `BLUEPRINT_EFFECTIVE`, `SIZE_BASELINE`, `BOOT_TIME_BASELINE`, `BASELINES_CSV` to variant-scoped paths
- [x] Add `EXTRA_RPMS_DIR := $(VARIANT_DIR)/extra-rpms` + `EXTRA_RPMS_MANIFEST := $(EXTRA_RPMS_DIR)/EXPECTED_SHA256`
- [x] **rpm recipe: honour `SOURCE_DATE_EPOCH` env override** (F5a) — `sde=$${SOURCE_DATE_EPOCH:-$$(git log ...)}`
- [x] **Followup (2026-04-17): git-log fallback bug** — `git log -- <uncommitted>` exits 0 with empty output, so the original `|| date +%s` chain never fires. Split into two `:-` defaults so empty SDE falls through to `date +%s`. Surfaced by first bastion-edge rpm build (uncommitted files).
- [x] **repo target: sweep `$(EXTRA_RPMS_DIR)/*.rpm`** after placing the fedbuild-built RPM, verifying `$(EXTRA_RPMS_MANIFEST)` if present (F7 + F7a)
- [x] `image` target uses `$(EXTRA_REPOS)` from variant.mk instead of hardcoded flags
- [x] `smoke` target invokes `bash $(VARIANT_DIR)/tests/smoke.sh $(OUTDIR)`
- [x] `shellcheck` target globs `$(VARIANT_DIR)/**/*.sh` + `tests/*.sh`
- [x] Add `check-versions-all` fleet convenience target (loops variants/)
- [x] Add `variants` listing target (prints each variant dir + its description from README first line)
- [x] Add sanity check: abort early if `$(VARIANT_DIR)/variant.mk` missing

### A5 — (folded into A2)

### A6 — Documentation rewrite
- [x] `README.md`: variant table; "Two artifacts" → "Per-variant artifacts"
- [x] `AGENTS.md`: multi-variant framing in opening paragraph; Commands section updated; add Variant Anatomy section
- [x] `HUMANS.md`: Quick Start mentions `VARIANT` default; add "Multiple Variants" subsection
- [x] `CONTRIBUTING.md`: `make VARIANT=devbox check && make VARIANT=bastion-edge check` in pre-PR checklist

### A7 — CI matrix
- [x] `.github/workflows/ci.yml`: `strategy.matrix.variant: [devbox, bastion-edge]` (unskipped; edge row lands green in Phase B along with the scaffold)
- [x] `make VARIANT=$${{ matrix.variant }} check/rpm/lint` per matrix cell
- [x] `actionlint .github/workflows/ci.yml` green

### A8 — Same-tree determinism verify
- [x] Run `make clean && SOURCE_DATE_EPOCH=1776424334 make VARIANT=devbox rpm` twice in the new tree
- [x] Verified both runs produce identical SHA256 (specific hash omitted — depends on SOURCES mtimes; the invariant is rebuild-determinism, not a fixed ground-truth)
- [x] Same-tree determinism preserved under refactor; cross-tree comparison out of scope per BDA in fedbuild AGENTS.md
- [x] bastion-edge also verified — two back-to-back `SOURCE_DATE_EPOCH=1776424334 make VARIANT=bastion-edge rpm` → `a47c5d89126961d92940aae2334b2592284c452a30bb30a94d573776d8585176` both runs

### Phase A commit
- [x] Commits landed: `22681d5` (refactor), `a390205` (BDA + spec corrections), `fd99f43` (docs)

## Phase B — bastion-edge variant

**Naming correction (2026-04-17, advisor-reviewed):** The upstream `bastion-edge` source repo ships two version-matched RPMs, not one:
- `bastion-theatre` — Node payload, no systemd unit
- `bastion-theatre-manager` — daemon, ships `bastion-theatre-manager.service`, `Requires: bastion-theatre = %{version}-%{release}`

fedbuild's variant slot stays named `bastion-edge` (Bastion tier-3+4 concept). Blueprint packages, `services.enabled`, firstboot `After=`, and smoke assertions all use the real upstream names (`bastion-theatre*`). spec.md F6 / plan.md B2–B5 updated in the same commit.

### B1 — Skeleton
- [x] `mkdir -p variants/bastion-edge/{bastion-edge-firstboot/SPECS,bastion-edge-firstboot/SOURCES,tests,extra-rpms}`
- [x] `variants/bastion-edge/extra-rpms/.keep` + `variants/bastion-edge/.gitignore` excluding `*.rpm`
- [x] `variants/bastion-edge/extra-rpms/EXPECTED_SHA256` — comments-only stub; populated by operator with two sha256 entries (theatre + theatre-manager)
- [x] `variants/bastion-edge/variant.mk`
- [x] `variants/bastion-edge/README.md` documents: two-RPM pickup flow (`yarn release:rpm:theatre` + `yarn release:rpm:theatre-manager`), supply-chain pinning (F7a), smoke assertions, what's NOT in this variant (no Homebrew, no agent tooling)

### B2 — Blueprint
- [x] Write `variants/bastion-edge/blueprint.toml` — Fedora 43 minimal + nodejs + openssl + bastion-theatre{,-manager} + cloud-init + audit + dnf5-plugin-automatic
- [x] Version `0.1.0` initial
- [x] No Homebrew, no dev packages
- [x] `[customizations.services] enabled = ["sshd", "bastion-theatre-manager", "bastion-edge-firstboot", "dnf5-automatic.timer", "auditd.service"]`
- [x] `[customizations.user]` `edge-operator` with `CHANGEME` placeholder (same substitution pattern as devbox)

### B3 — Firstboot RPM
- [x] Write `bastion-edge-firstboot/SPECS/bastion-edge-firstboot.spec` — minimal; `Requires: bastion-theatre-manager`; %ghost release file with 0644 attr; no interactive post install scriptlets beyond systemd preset macros + release-file write
- [x] Write `bastion-edge-firstboot/SOURCES/firstboot.sh` — cidata → machine-id fallback; FEDBUILD_MARK / FEDBUILD_READY / FEDBUILD_FAILED protocol; writes `/var/lib/bastion-edge/edge-id`
- [x] Write `bastion-edge-firstboot/SOURCES/bastion-edge-firstboot.service` — oneshot, After=cloud-init.target bastion-theatre-manager.service, full systemd hardening (NoNewPrivileges, ProtectSystem=strict, ReadWritePaths=/var/lib/bastion-edge)
- [x] `shellcheck` firstboot.sh — clean
- [x] `check-versions` green (0.1.0 lockstep)
- [x] `make VARIANT=bastion-edge rpm` builds successfully
- [x] `make VARIANT=bastion-edge lint` → 0 errors, 2 warnings (both also present for devbox: dangerous-command-in-%post chmod, %postun rm — intentional)

### B4 — Smoke
- [x] Write `variants/bastion-edge/tests/smoke.sh` based on `variants/devbox/tests/smoke.sh`; adapted for edge-operator SSH user, port 2232 (concurrent-safe with devbox), FEDBUILD_READY marker protocol, no tool-matrix logic
- [x] Assertions: `systemctl is-active bastion-theatre-manager`, firstboot done + no failed sentinel, edge-id non-empty, no Homebrew/Claude, node on PATH, SELinux enforcing with zero AVC, reboot persistence

### B5 — Docs + extra-rpms workflow
- [x] `variants/bastion-edge/README.md` explains the two-RPM `yarn release:rpm:*` → `extra-rpms/` flow + EXPECTED_SHA256 population
- [ ] Update top-level `README.md` variant table with bastion-edge row (already multi-variant-framed; verify the row exists and matches reality)
- [ ] Update `AGENTS.md` Variants section (verify same)

### B6 — HG-2: Image build (human)
- [ ] Human: `cp ~/.ssh/id_ed25519.pub keys/authorized_key`
- [ ] Human: run `yarn release:rpm:theatre` + `yarn release:rpm:theatre-manager` in the bastion-edge source repo; drop both RPMs into `variants/bastion-edge/extra-rpms/`
- [ ] Human: populate `variants/bastion-edge/extra-rpms/EXPECTED_SHA256` with the two sha256 lines
- [ ] Human: `make VARIANT=bastion-edge rpm` — produces `bastion-edge-firstboot-*.rpm` (agent verified this path: it works without the upstream RPMs)
- [ ] Human: `make VARIANT=bastion-edge image` — produces `output/bastion-edge/fedora-43-bastion-edge.raw.zst`

### B7 — HG-3: Smoke (human)
- [ ] Human: `make VARIANT=bastion-edge smoke` — KVM boot + assertion pass

### B8 — HG-4: Bless baselines (human)
- [ ] Human: `make VARIANT=bastion-edge bless-size` (after HG-3)
- [ ] Human: `FIRSTBOOT_SECS=<observed> make VARIANT=bastion-edge bless-boot-time`
- [ ] Human: `BUILD_SECS=… IMAGE_BYTES=… FIRSTBOOT_SECS=… SECONDBOOT_SECS=… make VARIANT=bastion-edge baseline-record`
- [ ] Commit `variants/bastion-edge/tests/{size.baseline,boot-time.baseline,baselines.csv}`

### Phase B commits
- [x] `feat(edge): variants/bastion-edge/ blueprint + firstboot scaffold` (B1–B3, Makefile SDE-fallback fix, CI matrix expansion, spec/plan corrections)
- [x] `test(edge): variant smoke assertions` (B4) — folded into same commit
- [x] `docs(edge): variant README + supply-chain pinning` (B5 agent portion) — folded into same commit
- [ ] `test(edge): baseline size + boot-time from first successful build` (B8, human-authored after HG-3)

## Signoff
- [ ] Downstream Bastion `specs/active/packaging-vm-retirement/` unblocked (fedbuild Phase B scaffolding green; unblocks HG-2/HG-3/HG-4 for Bastion meta to pin submodule)
- [ ] Bastion meta pins fedbuild submodule at post-B landing SHA
