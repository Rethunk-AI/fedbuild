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

# Derived paths (all variant-scoped; no root-level per-variant state)
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

Fedora 43 minimal + bastion-edge runtime deps. No Homebrew, no dev tools. Nodejs is required because `bastion-theatre` + `bastion-theatre-manager` both `Requires: nodejs >= 22` (Fedora 43 default satisfies this).

**Naming correction (2026-04-17):** The `bastion-edge` source repo does not ship a single `bastion-edge` RPM. It ships two version-matched RPMs from `packaging/rpm/`:
- `bastion-theatre` — Node payload, no systemd unit
- `bastion-theatre-manager` — the daemon; ships `bastion-theatre-manager.service`; `Requires: bastion-theatre = %{version}-%{release}`

fedbuild's variant slot is still named `bastion-edge` (the Bastion tier-3+4 concept per `bastion-edge/CLAUDE.md`, stable regardless of RPM naming), but blueprint/services/smoke reference the real RPM + service names.

```toml
name = "fedora-43-bastion-edge"
description = "Fedora 43 minimal + Bastion TheatreManager (field-deployable edge image)"
version = "0.1.0"
distro = "fedora-43"

packages = [
    # --- minimal runtime ---
    { name = "systemd",                 version = "*" },
    { name = "openssh-server",          version = "*" },
    { name = "sudo",                    version = "*" },
    { name = "ca-certificates",         version = "*" },
    { name = "glibc-minimal-langpack",  version = "*" },
    { name = "cloud-init",              version = "*" },   # cidata -> edge-id
    { name = "audit",                   version = "*" },
    { name = "dnf5-plugin-automatic",   version = "*" },

    # --- bastion-theatre-manager.spec Requires: ---
    { name = "nodejs",                  version = "*" },   # >= 22 (F43 default)
    { name = "openssl",                 version = "*" },

    # --- operator-supplied via extra-rpms/ ---
    { name = "bastion-theatre",         version = "*" },
    { name = "bastion-theatre-manager", version = "*" },

    # --- built by this variant ---
    { name = "bastion-edge-firstboot",  version = "*" },
]

[[customizations.user]]
name = "edge-operator"
key = "ssh-ed25519 CHANGEME user@localhost"
groups = ["wheel"]

[customizations.services]
enabled = ["sshd", "bastion-theatre-manager", "bastion-edge-firstboot", "dnf5-automatic.timer", "auditd.service"]
```

Both `bastion-theatre*` RPMs come from the local yum repo built by `make VARIANT=bastion-edge repo` (which folds in `extra-rpms/*.rpm` alongside the fedbuild-built firstboot RPM). The `theatremanager` sysuser is auto-created by the `bastion-theatre-manager` RPM's `%post`; firstboot does not need to handle it.

### B3 — Firstboot RPM

`bastion-edge-firstboot.spec` is a minimal post-install unit. It does NOT manage `bastion-theatre-manager.service` — that unit's lifecycle is owned by the upstream `bastion-theatre-manager` RPM (systemd-preset/enabled via blueprint `services.enabled`). firstboot's only job is stamping an `edge-id`:

- Reads cidata if present (`/var/lib/cloud/data/instance-id`, `…/nocloud/meta-data`, `…/meta-data`); falls back to `/etc/machine-id`
- Writes `/var/lib/bastion-edge/edge-id` (0644, root-owned)
- Runs oneshot; `ExecStartPost` touches `/var/lib/bastion-edge/done`

`bastion-edge-firstboot.service`:
```ini
[Unit]
Description=Bastion edge VM first-boot setup (edge-id stamp)
After=cloud-init.target bastion-theatre-manager.service
Wants=cloud-init.target
Before=multi-user.target
ConditionPathExists=!/var/lib/bastion-edge/done

[Service]
Type=oneshot
ExecStart=/usr/libexec/bastion-edge-firstboot/firstboot.sh
ExecStartPost=/usr/bin/touch /var/lib/bastion-edge/done
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

### B4 — smoke.sh

Variant-specific assertions (`variants/bastion-edge/tests/smoke.sh`):
- Boot VM via qemu-kvm; SSH as `edge-operator` on port 2232 (distinct from devbox's 2222 so both can run concurrently)
- Wait for `FEDBUILD_READY` on serial (same marker protocol as devbox)
- `systemctl is-active bastion-theatre-manager` → `active`
- `systemctl is-active bastion-edge-firstboot` → `active` (RemainAfterExit=yes; becomes `inactive` after reboot)
- `test -f /var/lib/bastion-edge/done` — sentinel written by `ExecStartPost`
- `test -f /var/lib/bastion-edge/edge-id` — non-empty
- No Homebrew (`test ! -d /home/linuxbrew`), no agent config (`test ! -d /home/edge-operator/.claude`)
- `command -v node` succeeds (TheatreManager requires it)
- SELinux enforcing; zero AVC denials since boot
- Reboot; re-assert `bastion-theatre-manager` stays `active`, firstboot does not re-run (sentinel mtime unchanged)

Model the script on `variants/devbox/tests/smoke.sh` (copied+adapted — OK to diverge).

### B5 — `extra-rpms/` pickup

Operator flow before `make VARIANT=bastion-edge image`:
```bash
# In the bastion-edge source repo — two RPMs, version-matched:
yarn release:rpm:theatre
yarn release:rpm:theatre-manager
cp packaging/rpm/rpmbuild/RPMS/x86_64/bastion-theatre{,-manager}-*.rpm \
   ~/fedbuild/variants/bastion-edge/extra-rpms/

# Pin what was accepted into the supply chain (F7a):
cd ~/fedbuild/variants/bastion-edge/extra-rpms
sha256sum bastion-theatre*.rpm bastion-theatre-manager*.rpm > EXPECTED_SHA256

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
