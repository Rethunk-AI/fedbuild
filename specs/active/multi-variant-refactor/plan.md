# Plan — fedbuild multi-variant refactor

Companion to [`spec.md`](./spec.md). Two-phase execution: **Phase A** is a pure structural refactor (no behavioural change, byte-identical RPM output); **Phase B** adds the `bastion-edge` variant.

---

## 1. Phase graph

```
Phase A — structural refactor
  ├─► A1 baseline-capture: record devbox RPM SHA256 pre-refactor
  ├─► A2 create variants/devbox/ and move files
  ├─► A3 extract variants/<name>/variant.mk convention
  ├─► A4 parameterize root Makefile (VARIANT, VARIANT_DIR, per-variant OUTDIR/REPODIR)
  ├─► A5 move per-variant tests (smoke.sh, size.baseline, boot-time.baseline) under tests/<variant>/
  ├─► A6 rewrite README + AGENTS + HUMANS for multi-variant framing
  ├─► A7 update CI matrix (strategy.matrix.variant)
  └─► A8 verify: devbox RPM SHA256 matches pre-refactor baseline (HG-1)

Phase B — bastion-edge variant
  ├─► B1 create variants/bastion-edge/ skeleton
  ├─► B2 write variants/bastion-edge/blueprint.toml (Fedora 43 minimal + runtime deps)
  ├─► B3 write bastion-edge-firstboot/{SPECS,SOURCES}/
  ├─► B4 write variants/bastion-edge/tests/smoke.sh assertions
  ├─► B5 document extra-rpms/ pickup convention
  ├─► B6 HG-2: make VARIANT=bastion-edge image (sudo)
  ├─► B7 HG-3: make VARIANT=bastion-edge smoke (KVM)
  └─► B8 HG-4: bless size.baseline + boot-time.baseline; seed tests/bastion-edge/baselines.csv
```

---

## 2. Phase A detail — structural refactor

### A1 — Baseline capture (HG-1 prep)

**Scope correction (BDA — see fedbuild `AGENTS.md` § Reproducibility scope):** RPM is path-dependent by design — the captured `%install` scriptlet stored in the SRPM header embeds the absolute `_sourcedir` path. Cross-tree byte-identity (pre-rename vs post-rename) was never achievable and is not a fedbuild goal. The actual invariant is **same-tree determinism**: rebuild twice in the same tree with the same SDE → same RPM bytes.

A1 therefore captures the reproducibility property only, not a hash to compare against:
```bash
make clean && make rpm
sha256sum rpmbuild/RPMS/noarch/*.rpm  # record SHA1
make clean && make rpm                # rebuild
sha256sum rpmbuild/RPMS/noarch/*.rpm  # MUST match SHA1 (same-tree determinism)
```

### A2 — Create `variants/devbox/`

File moves (single commit, `git mv` preserves history):

```
blueprint.toml                                → variants/devbox/blueprint.toml
blueprint.effective.toml                      (kept at root — derived artifact, git-ignored)
bastion-vm-firstboot/                         → variants/devbox/bastion-vm-firstboot/
  SPECS/bastion-vm-firstboot.spec
  SOURCES/  (all files)
tests/size.baseline                           → variants/devbox/tests/size.baseline
tests/boot-time.baseline                      → variants/devbox/tests/boot-time.baseline
tests/baselines.csv                           → variants/devbox/tests/baselines.csv
tests/smoke.sh                                → variants/devbox/tests/smoke.sh
tests/cve-allowlist.yaml                      → variants/devbox/tests/cve-allowlist.yaml
tests/smoke-rerun.sh                          (kept at tests/ — generic helper, takes OUTDIR arg)
tests/diff-packages.sh                        (kept at tests/ — generic helper)
tests/brew-drift.sh                           (kept at tests/ — generic shape; devbox-only in practice)
schemas/agent-settings.schema.json            (kept at schemas/ — reusable schema pattern)
```

**Layout rule:** everything variant-specific lives under `variants/<variant>/`. Nothing variant-specific lives under `tests/` at the repo root. `tests/` at root holds only generic helpers that take a variant as input argument.

Notes:
- `brew-drift.sh` stays at top-level for Phase A; if bastion-edge doesn't use brew (it won't), we can scope it to `variants/devbox/tests/` in a follow-up.
- `agent-settings.schema.json` is devbox-specific today but is a reusable schema pattern; leave at `schemas/` until a second consumer emerges.

### A3 — `variants/<name>/variant.mk` convention

Each variant dir ships a small makefile fragment:

`variants/devbox/variant.mk`:
```makefile
# Variables exported to the root Makefile for VARIANT=devbox
PKG_NAME           := bastion-vm-firstboot
PKG_BLUEPRINT_NAME := fedora-43-devbox
PKG_IMAGE_FORMAT   := minimal-raw-zst
# Any EXTRA_REPOS flags specific to this variant
EXTRA_REPOS        := --extra-repo https://packages.microsoft.com/yumrepos/vscode \
                      --extra-repo https://pkg.cloudflare.com/cloudflared/rpm
```

`variants/bastion-edge/variant.mk` (added in Phase B):
```makefile
PKG_NAME           := bastion-edge-firstboot
PKG_BLUEPRINT_NAME := fedora-43-bastion-edge
PKG_IMAGE_FORMAT   := minimal-raw-zst
EXTRA_REPOS        :=   # bastion-edge pulls only from local repo (which includes extra-rpms/)
```

### A4 — Makefile parameterization

Top of Makefile gains:
```makefile
VARIANT          ?= devbox
VARIANT_DIR      := $(FEDBUILD)/variants/$(VARIANT)
VARIANT_TESTS    := $(VARIANT_DIR)/tests

# Pull variant-specific vars
-include $(VARIANT_DIR)/variant.mk

# Derived paths (all variant-scoped; no legacy root-level per-variant state)
REPODIR    := $(FEDBUILD)/repo/$(VARIANT)
OUTDIR     := $(FEDBUILD)/output/$(VARIANT)
SPECFILE   := $(VARIANT_DIR)/$(PKG_NAME)/SPECS/$(PKG_NAME).spec
SRCDIR     := $(VARIANT_DIR)/$(PKG_NAME)/SOURCES
BLUEPRINT  := $(VARIANT_DIR)/blueprint.toml
BLUEPRINT_EFFECTIVE := $(VARIANT_DIR)/blueprint.effective.toml
EXTRA_RPMS_DIR      := $(VARIANT_DIR)/extra-rpms
EXTRA_RPMS_MANIFEST := $(EXTRA_RPMS_DIR)/EXPECTED_SHA256
SIZE_FILE           := $(OUTDIR)/SIZE
SIZE_BASELINE       := $(VARIANT_TESTS)/size.baseline
BOOT_TIME_BASELINE  := $(VARIANT_TESTS)/boot-time.baseline
BASELINES_CSV       := $(VARIANT_TESTS)/baselines.csv
```

**rpm recipe: honour `SOURCE_DATE_EPOCH` env override (F5a)** — replace the `@sde=$$(git log -1 ...)` shell line with:
```makefile
@sde=$${SOURCE_DATE_EPOCH:-$$(git log -1 --format=%ct -- $(SPECFILE) $(SRCDIR) 2>/dev/null || date +%s)}; \
 sha=$$(git rev-parse HEAD 2>/dev/null || echo unknown); \
 ...
```
This both (a) lets A8 verify byte-fidelity by pinning the pre-refactor SDE and (b) enables CI runners + external reproducers to pin an explicit epoch.

**`repo` target: sweep `extra-rpms/` (F7)** — extend the recipe:
```makefile
$(REPO_MARKER): $(RPM)
	@command -v createrepo >/dev/null 2>&1 || { echo "createrepo_c not found — run: make deps"; exit 1; }
	rm -rf $(REPODIR)
	mkdir -p $(REPODIR)
	cp -v $(RPM) $(REPODIR)/
	@if [ -d $(EXTRA_RPMS_DIR) ]; then \
	   if [ -f $(EXTRA_RPMS_MANIFEST) ]; then \
	     echo "Verifying extra-rpms against $(EXTRA_RPMS_MANIFEST)..."; \
	     (cd $(EXTRA_RPMS_DIR) && sha256sum -c EXPECTED_SHA256) || { echo "ERROR: extra-rpms checksum mismatch"; exit 1; }; \
	   else \
	     echo "NOTE: $(EXTRA_RPMS_DIR) present but no EXPECTED_SHA256 manifest — supply-chain gap, see variant README"; \
	   fi; \
	   find $(EXTRA_RPMS_DIR) -maxdepth 1 -name '*.rpm' -exec cp -v {} $(REPODIR)/ \; ; \
	 fi
	createrepo $(REPODIR)
```

The `image` target's `--extra-repo` flags become `$(EXTRA_REPOS)` from variant.mk. All other targets (`check`, `lint`, `sign`, `verify`, `sbom`, `attest`, `cve-scan`) remain variant-agnostic in structure — they just operate on `$(OUTDIR)` which is now variant-scoped.

`check-versions` and `bump-*` need a loop-over-variants pass for fleet-wide safety, but the minimum for Phase A is: they operate on `$(VARIANT)` and the operator repeats for each variant. Add a `check-versions-all` convenience target for fleet pass.

### A5 — Per-variant tests directory

New layout under `tests/`:
```
tests/
  <variant>/             # per-variant baselines + optional csv history + optional cve-allowlist
    size.baseline
    boot-time.baseline
    baselines.csv
    cve-allowlist.yaml   # optional, falls back to tests/cve-allowlist.yaml if missing
  smoke-rerun.sh         # generic; takes OUTDIR as arg
  diff-packages.sh       # generic; takes VM_HOST as arg
  brew-drift.sh          # generic shape; may move per-variant later
  cve-allowlist.yaml     # default fallback
```

Variant-specific `smoke.sh` lives at `variants/<variant>/tests/smoke.sh`. The root Makefile `smoke` target invokes `bash $(VARIANT_DIR)/tests/smoke.sh $(OUTDIR)`.

### A6 — Documentation rewrite

- `README.md`: Replace "Two artifacts: `bastion-vm-firstboot` RPM + `fedora-43-devbox` image" with variant-table. Add a "Variants" section listing available variants with one-liner purpose.
- `AGENTS.md`: Rewrite the first paragraph; rewrite the Commands section to show `make VARIANT=<name> image`; add a Variant Anatomy section showing the `variants/<name>/` layout.
- `HUMANS.md`: Quick Start updated to mention `VARIANT` default; add a "Multiple Variants" subsection.
- `CONTRIBUTING.md`: Update "Before Submitting a PR" to include `make VARIANT=devbox check && make VARIANT=bastion-edge check`.
- `.github/workflows/ci.yml`: Add `strategy.matrix.variant: [devbox, bastion-edge]`; ensure `make VARIANT=$${{ matrix.variant }} check` + `rpm` + `lint` run per matrix cell.

### A7 — CI matrix

Edit `.github/workflows/ci.yml`:
```yaml
jobs:
  build:
    strategy:
      matrix:
        variant: [devbox, bastion-edge]
    steps:
      - uses: actions/checkout@v4
      - run: make VARIANT=${{ matrix.variant }} check
      - run: make VARIANT=${{ matrix.variant }} rpm
      - run: make VARIANT=${{ matrix.variant }} lint
```

### A8 — Verify same-tree determinism

```bash
make clean && SOURCE_DATE_EPOCH=1776424334 make VARIANT=devbox rpm
sha256sum rpmbuild/RPMS/noarch/*.rpm > /var/tmp/devbox-rpm.sha256.run1
make clean && SOURCE_DATE_EPOCH=1776424334 make VARIANT=devbox rpm
sha256sum rpmbuild/RPMS/noarch/*.rpm > /var/tmp/devbox-rpm.sha256.run2
diff /var/tmp/devbox-rpm.sha256.run1 /var/tmp/devbox-rpm.sha256.run2
# MUST produce zero diff output
```

Verified during this spec's execution: two back-to-back rebuilds with pinned SDE produced byte-identical RPMs. (Specific hash omitted on purpose — it depends on SOURCES mtimes which can shift across operator workflows; the invariant is determinism between adjacent runs in the same tree, not a fixed ground-truth hash.)

**Why not pin SDE unconditionally?** Default `git log`-derived SDE remains correct for normal use. The env override (F5a) is an escape hatch for CI runners and external reproducers that don't have a writable git tree.

---

## 3. Phase B detail — bastion-edge variant

### B1 — Skeleton

```
variants/bastion-edge/
  variant.mk
  blueprint.toml
  bastion-edge-firstboot/
    SPECS/bastion-edge-firstboot.spec
    SOURCES/
      firstboot.sh
      bastion-edge-firstboot.service
  tests/
    smoke.sh
  extra-rpms/               # pickup dir — gitignored except .keep
    .keep
  README.md
```

### B2 — `blueprint.toml`

Fedora 43 minimal + bastion-edge runtime deps. No Homebrew, no dev tools, no nodejs for the OS (bastion-edge embeds its Node runtime in the RPM if needed; this is a runtime choice of the bastion-edge maintainers — validate against their actual `.spec` Requires: list).

```toml
name = "fedora-43-bastion-edge"
description = "Fedora 43 minimal + bastion-edge service"
version = "0.1.0"
distro = "fedora-43"

packages = [
    # --- minimal runtime ---
    { name = "systemd",                 version = "*" },
    { name = "glibc-minimal-langpack",  version = "*" },
    { name = "openssh-server",          version = "*" },
    { name = "sudo",                    version = "*" },
    { name = "ca-certificates",         version = "*" },

    # --- bastion-edge runtime deps (audit against actual Requires:) ---
    { name = "bastion-edge",            version = "*" },   # from extra-rpms/
    # ... add deps declared by the bastion-edge RPM that aren't already pulled transitively
]

[[customizations.user]]
name = "edge-operator"
groups = ["wheel"]
password = "!"   # locked; SSH key required
key = "ssh-ed25519 CHANGEME user@localhost"

[customizations.services]
enabled = ["sshd", "bastion-edge", "bastion-edge-firstboot"]

[customizations.kernel]
# no special args
```

The `{ name = "bastion-edge", version = "*" }` pulls from the local yum repo built by `make VARIANT=bastion-edge repo` (which includes `extra-rpms/*.rpm` in addition to the fedbuild-built firstboot RPM).

### B3 — Firstboot RPM

`bastion-edge-firstboot.spec` is a minimal post-install unit:
- Enables `bastion-edge.service`
- Reads `/var/lib/cloud/data/meta-data` (cidata) for `edge-id`; writes to `/var/lib/bastion-edge/edge-id`
- Runs oneshot; disables itself after success

`bastion-edge-firstboot.service`:
```ini
[Unit]
Description=bastion-edge first-boot setup
ConditionPathExists=!/var/lib/bastion-edge/.firstboot-done
After=cloud-init.target bastion-edge.service
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/bastion-edge-firstboot/firstboot.sh
ExecStartPost=/bin/touch /var/lib/bastion-edge/.firstboot-done
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

### B4 — smoke.sh

Variant-specific assertions (`variants/bastion-edge/tests/smoke.sh`):
- Boot VM via qemu-kvm
- Wait for SSH (cloud-init SSH key substituted at image-build time)
- `systemctl is-active bastion-edge` → `active`
- `systemctl is-active bastion-edge-firstboot` → `inactive` (oneshot completed)
- `test -f /var/lib/bastion-edge/.firstboot-done`
- `test -f /var/lib/bastion-edge/edge-id` — non-empty
- No Homebrew (`test ! -d /home/linuxbrew`), no Claude (`test ! -f ~/.claude/settings.json`)
- Reboot; re-assert `systemctl is-active bastion-edge` stays `active` on second boot

Model the script on `variants/devbox/tests/smoke.sh` (copied+adapted — OK to diverge).

### B5 — `extra-rpms/` pickup

Operator flow before `make VARIANT=bastion-edge image`:
```bash
# In the bastion-edge source repo:
yarn release:rpm
cp packaging/rpm/dist/bastion-edge-*.rpm ~/fedbuild/variants/bastion-edge/extra-rpms/

# In fedbuild:
make VARIANT=bastion-edge image
```

Makefile's `repo` target for `VARIANT=bastion-edge` picks up everything in `extra-rpms/*.rpm` in addition to the fedbuild-built firstboot RPM.

### B6–B8 — Human-gated execution

HG-2 / HG-3 / HG-4 require sudo + KVM. Agent prepares every file; human runs the final three `make` invocations and commits the resulting `tests/bastion-edge/size.baseline`.

---

## 4. Risks + mitigations

| Risk | Mitigation |
|------|------------|
| Phase A file moves break SOURCE_DATE_EPOCH reproducibility because `git mv` adjusts mtimes | `git mv` preserves content hashes but we double-check with the A8 gate. If hashes diverge, bisect the moves and investigate. |
| Variant output directories grow unbounded on developer machines | `make distclean` removes all variant outputs; documented. |
| Brew / toolchain packages leak into bastion-edge variant | Smoke assertions B4 explicitly check absence; `make VARIANT=bastion-edge diff-packages` can be run post-build against a baseline. |
| `extra-rpms/` dependency shape drifts as bastion-edge source evolves | The fedbuild bastion-edge variant is tied to a specific bastion-edge version via the RPM in `extra-rpms/`; downstream Bastion meta's submodule pin captures both sides. |
| CI matrix doubles build time | GitHub matrix runs jobs in parallel; wall-clock impact minimal. |
| Variant `variant.mk` not loaded due to typo → silent fallback to devbox defaults | Add an explicit `test -f $(VARIANT_DIR)/variant.mk || { echo ERROR; exit 1; }` early sanity check in the root Makefile. |

---

## 5. Non-goals (reminder)

- No new variants beyond devbox + bastion-edge.
- No extraction of shared code into `fedbuild-core` library.
- No Ubuntu/DEB support.
- No CI-hosted smoke (requires self-hosted KVM runner).
