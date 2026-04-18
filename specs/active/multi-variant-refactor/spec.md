# fedbuild multi-variant refactor + bastion-edge variant

**Status:** `ready` — scope is mechanical refactor + one new variant. fedbuild's pipeline (reproducible RPM → osbuild image-builder → cosign → SBOM → smoke → size budget) is already variant-agnostic in spirit; only the inputs (blueprint + firstboot SPEC/SOURCES + baselines + smoke assertions) are variant-specific.

**Companion spec:** [`Bastion/specs/active/packaging-vm-retirement/`](https://github.com/Rethunk-Tech/Bastion) — the downstream consumer that will retire 1,069 lines of qcow2-overlay harness in favour of the bastion-edge variant produced here.

**Tracking:** [`CHANGELOG.md`](../../../CHANGELOG.md) entry will reference this spec on landing.

---

## What & why

- **Problem:** fedbuild today hard-codes a single artifact (`bastion-vm-firstboot` RPM + `fedora-43-devbox` image). The downstream `Bastion` meta-repo needs a **second** image (field-deployable bastion-edge) and — eventually — a third (bastion-core). Forking fedbuild per target would duplicate the signing / SBOM / size-budget / reproducibility pipeline. Option A from the downstream retirement analysis: reshape fedbuild to support multiple named variants in one repo.
- **Users:** Bastion release engineers; Bastion field operators; anyone downstream who wants to add a new Fedora-based image variant (distribution engineers could add `bastion-core`, `bastion-training`, `bastion-demo`, etc.).
- **Value:** Every variant inherits the same hardened pipeline for free — SOURCE_DATE_EPOCH reproducibility, cosign keyless signing, SLSA v1 provenance, CycloneDX + SPDX SBOMs, size budget enforcement, drift detection, boot-time regression tracking. Adding a variant is a new directory, not a new CI pipeline.

---

## Requirements

### Must have

| ID | Requirement | Acceptance |
| --- | --- | --- |
| F1 | **Variant directory layout** — `variants/<name>/` contains `blueprint.toml`, `<firstboot-pkg-name>/SPECS/<firstboot-pkg-name>.spec`, `<firstboot-pkg-name>/SOURCES/`, `tests/smoke.sh`, `tests/size.baseline`, optional `tests/boot-time.baseline`, optional `tests/cve-allowlist.yaml`, optional `extra-rpms/` for upstream-built RPMs to fold into the local yum repo. | `tree variants/` shows the structure for both `devbox` and `bastion-edge`. |
| F2 | **Per-variant `variant.mk` include** — each variant dir ships a `variant.mk` file that overrides variant-specific Makefile variables (e.g. `PKG_NAME`, `PKG_BLUEPRINT_NAME`, `PKG_IMAGE_FORMAT`, optional `EXTRA_REPOS`). Root Makefile `-includes` it. | Root Makefile works unchanged if a variant's `variant.mk` is absent (fallback defaults); works correctly if present. |
| F3 | **Root Makefile dispatches via `VARIANT=<name>`** — default `VARIANT=devbox` preserves current behaviour; `make VARIANT=bastion-edge image` builds the edge variant. | `make` (no arg) produces byte-identical devbox RPM vs pre-refactor (verified via `SOURCE_DATE_EPOCH` identical inputs → identical output hash). |
| F4 | **Per-variant `OUTDIR` and `REPODIR`** — `output/<variant>/` and `repo/<variant>/` — so two variants can coexist on disk without clobbering each other. | `make VARIANT=devbox image && make VARIANT=bastion-edge image` both succeed; neither clobbers the other's artifacts. |
| F5 | **Devbox variant rebuild-determinism preserved** — within a single working tree, two consecutive `make VARIANT=devbox rpm` runs (with the same `SOURCE_DATE_EPOCH`, same git SHA, same `_sourcedir` path, same SOURCES mtimes) must produce byte-identical RPMs. **Cross-tree byte-identity is explicitly NOT a goal** — RPM headers embed the absolute `_sourcedir` path in the captured `%install` scriptlet, so two trees at different filesystem locations (or before vs after a `git mv`) inevitably produce different RPM bytes. fedbuild's existing reproducibility hardening (SOURCE_DATE_EPOCH, `_buildhost` pin, clamp_mtime, LC_ALL/TZ) targets *same-tree* determinism, which is the consumer-relevant property. See `AGENTS.md` § Reproducibility scope (BDA — 2026-04-17) for the full diagnostic. | Two back-to-back `make clean && SOURCE_DATE_EPOCH=<X> make VARIANT=devbox rpm` runs in the post-refactor tree produce identical SHA256. Verified during execution. |
| F5a | **Makefile honours `SOURCE_DATE_EPOCH` env override** — the RPM target must respect an operator-supplied `SOURCE_DATE_EPOCH` rather than always deriving from `git log`. Enables CI runners and external reproducers to pin SDE explicitly without depending on a writable git tree. | `sde=$${SOURCE_DATE_EPOCH:-$$(git log ...)}` pattern in the rpm recipe; `SOURCE_DATE_EPOCH=<fixed> make rpm` honours the pin. |
| F6 | **bastion-edge variant added** — `variants/bastion-edge/` with blueprint for Fedora 43 minimal + bastion-edge runtime deps + the pre-built bastion-edge RPM folded in via `extra-rpms/`. Includes `bastion-edge-firstboot.spec` that enables `bastion-edge.service`. | `make VARIANT=bastion-edge rpm` builds the firstboot RPM; `make VARIANT=bastion-edge image` (sudo) builds the image; `make VARIANT=bastion-edge smoke` (KVM) boots the image and asserts `systemctl is-active bastion-edge` returns `active`. |
| F7 | **`extra-rpms/` pickup** — a variant may declare a directory of upstream RPMs to fold into its local yum repo alongside the fedbuild-built firstboot RPM. Operator populates this before `make image`. The `repo` target **must** be extended to sweep `$(VARIANT_DIR)/extra-rpms/*.rpm` into `$(REPODIR)` before `createrepo`. Missing directory is fine for variants that don't need it. | bastion-edge variant `extra-rpms/` is the pickup point for the output of `yarn release:rpm` in the bastion-edge source repo; `make VARIANT=bastion-edge repo` includes those RPMs in the createrepo metadata. |
| F7a | **`extra-rpms/` provenance pinning (should-have)** — each variant that consumes extra RPMs ships an `extra-rpms/EXPECTED_SHA256` file listing `<sha256>  <rpm-filename>` pairs. `make repo` verifies each dropped RPM against this manifest before `createrepo` and fails on mismatch. Caller is still responsible for originally fetching the RPM from an authenticated source; this check only pins what was accepted into fedbuild's supply chain. | `variants/bastion-edge/extra-rpms/EXPECTED_SHA256` exists; tampered RPM fails `make repo` with a named error. |
| F8 | **CI matrix expands to both variants** — `.github/workflows/ci.yml` runs the fast pre-push checks (`make check`, `make rpm`, `make lint`, `shellcheck`) for each variant in parallel matrix jobs. | `ci.yml` has a `strategy.matrix.variant: [devbox, bastion-edge]`; both job rows green. |
| F9 | **README + AGENTS + HUMANS rewritten for multi-variant framing** — fedbuild's framing shifts from "builds the devbox image" to "builds Bastion VM images, one variant per artifact". | No prose still claims fedbuild is single-purpose; variant table added to README. |
| F10 | **Version lockstep stays per-variant** — `make check-versions` verifies each variant's SPEC `Version:` matches its blueprint `version = "X.Y.Z"`. `make bump-patch|minor|major VARIANT=<name>` scoped to a single variant. | `check-versions` runs across all variants; bumping one variant doesn't alter another. |
| F11 | **Per-variant size + boot-time baselines** — all variant-specific test assets live under `variants/<variant>/tests/` (`size.baseline`, `boot-time.baseline`, `baselines.csv`, `smoke.sh`, optional `cve-allowlist.yaml`). `tests/` at repo root keeps only the generic helpers (`smoke-rerun.sh`, `diff-packages.sh`, `brew-drift.sh`, default `cve-allowlist.yaml` fallback). | `make VARIANT=bastion-edge check-size` reads `variants/bastion-edge/tests/size.baseline`; `make VARIANT=devbox check-size` reads `variants/devbox/tests/size.baseline`. Single root for variant-specific state. |
| F12 | **No DEB/Ubuntu support added** — out of scope. osbuild-composer supports Ubuntu distros; a future variant can opt in per-variant. This spec explicitly does not add that. | No Ubuntu references anywhere in variants/ or Makefile after landing. |
| F13 | **License stays MIT; each variant directory includes no separate license** — fedbuild is a build harness; the artifacts it produces may have distinct licenses (bastion-edge RPM is proprietary; fedbuild's firstboot RPMs inherit MIT). | `variants/<name>/LICENSE` absent; single top-level `LICENSE` remains authoritative for fedbuild's build code. |

### Should have

| ID | Requirement | Acceptance |
| --- | --- | --- |
| F14 | **Variant README** — each `variants/<name>/README.md` explains what the variant produces, what upstream inputs it needs, and how to build+smoke it. | README exists for both variants. |
| F15 | **`make variants` listing target** — prints known variants with one-line descriptions. | `make variants` output. |
| F16 | **Boot-time regression check gracefully handles per-variant baselines** — `check-boot-time` reads `tests/<variant>/baselines.csv` if present, else falls back to the shared `tests/baselines.csv`. | Devbox retains existing baselines.csv pathway; edge starts with its own once enough data accumulates. |

### Must NOT

| ID | Non-requirement | Rationale |
| --- | --- | --- |
| F17 | **Do not extract a separate `fedbuild-core` shared library.** | Premature abstraction — only two consumers today. Revisit when a third or fourth emerges. |
| F18 | **Do not make fedbuild pull from Bastion's submodules.** | Dependency direction: fedbuild is a peer, not a subordinate. Upstream RPMs arrive via `extra-rpms/` pickup, populated by the operator before build. |
| F19 | **Do not rename `fedora-43-devbox` to `fedora-43-agent-sandbox` or similar.** | Tag / release / submodule-pin stability. Devbox is a stable name downstream consumers have referenced. |
| F20 | **Do not add a per-variant cosign identity.** | Single keyless identity suffices; the blob being signed (SHA256SUMS) distinguishes the variant by filename convention. |

---

## User stories

| Role | Story | Acceptance |
| ---- | ----- | ---------- |
| fedbuild maintainer | I add a new variant by creating `variants/<name>/` with blueprint + firstboot spec + smoke; CI picks it up via the matrix without pipeline edits. | F1 + F8 |
| Bastion release engineer | I produce a bootable bastion-edge field image with one command: `make VARIANT=bastion-edge image && make VARIANT=bastion-edge smoke`. | F6 |
| Bastion meta consumer | I pin fedbuild at a specific SHA and know that both variants at that SHA are mutually compatible (shared pipeline, shared signing identity, version-lockstep enforced). | F10 |
| Field operator (edge) | I receive `fedora-bastion-edge-<ver>.raw.zst`, verify it with cosign, `dd` to media, boot — bastion-edge is live. | F6 + inherited supply-chain guarantees |

---

## Success metrics

| Metric | Target |
| ------ | ------ |
| Refactor byte-fidelity | Pre-refactor devbox RPM SHA256 == post-refactor devbox RPM SHA256 (same git SHA input). |
| Variant parallelism | `make VARIANT=devbox rpm && make VARIANT=bastion-edge rpm` produces two coexisting RPMs under `rpmbuild/RPMS/`. |
| CI duration | Matrix job wall time stays within 2× single-variant job (variants build in parallel). |
| New-variant onboarding | Adding a third variant requires only dropping `variants/<name>/` content and a one-line CI matrix edit. |

---

## Dependencies

- **Upstream:** `bastion-edge` source repo must be able to emit an RPM via `yarn release:rpm` for the bastion-edge variant to consume via `extra-rpms/`. Already true.
- **Consumers:** `Bastion` meta-repo's `specs/active/packaging-vm-retirement/` (submodule pin after Phase B green).
- **External tools:** `osbuild-composer` / `image-builder`, `rpmbuild`, `createrepo_c`, `cosign`, `syft`, `qemu-system-x86_64` / KVM, `git-cliff`, `shellcheck`, `actionlint`, `yq`, `check-jsonschema`. All already fedbuild runtime deps.

---

## Human gates

| ID | Gate | Why human |
| --- | --- | --- |
| HG-1 | Devbox byte-fidelity verification after Phase A | Requires running `make rpm` before + after refactor and diffing SHA256. Agent can execute both but only on a machine where the rpm build environment is set up (`rpmbuild`, `createrepo_c` via `make deps` which uses sudo). |
| HG-2 | `make VARIANT=bastion-edge image` | `image-builder` requires sudo. |
| HG-3 | `make VARIANT=bastion-edge smoke` | `qemu-system-x86_64` + KVM — requires KVM host. |
| HG-4 | bastion-edge size.baseline bless | First successful image build sets the initial baseline. Human runs `make VARIANT=bastion-edge bless-size` to commit the baseline. |

---

## Non-goals

- Not CI-hosted smoke (GitHub hosted runners can't do nested KVM; out of scope).
- Not extracting shared Makefile fragments into a standalone library repo.
- Not changing the cosign signing identity or key-handling posture.
- Not adding Ubuntu / DEB / Arch / NixOS variants.
- Not altering blueprint.toml format — osbuild blueprint schema is upstream-owned.

---

## CARRY-FORWARD

- **Self-hosted CI runner with KVM** — required for CI-gated smoke. Trigger: first missed regression that smoke would have caught, or Bastion GitHub Actions billing restored (post-2026-04-26) + decision to invest in a runner.
- **bastion-core variant** — same pattern as bastion-edge. Defer until bastion-edge is proven in field use. Trigger: NCA request or first field-deploy of packaged bastion-core.
- **Shared-library extraction (`fedbuild-core`)** — revisit if a third or fourth variant consumer emerges outside the Bastion ecosystem.
