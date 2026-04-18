# PROGRESS — multi-variant-refactor (handoff snapshot)

**Snapshot date:** 2026-04-17. **Reason:** session context limit approaching; agent paused mid-Phase-B for re-dispatch with full context.

## Where things stand

### fedbuild repo (`/home/damonblais/fedbuild`, branch `main`, ahead 18)

**Phase A: COMPLETE.** All landed:
- `22681d5` — file moves into `variants/devbox/`, Makefile rewritten with `VARIANT=<name>` dispatch, `variant.mk` include, per-variant `OUTDIR`/`REPODIR`/`tests/`, `extra-rpms/` sweep with optional `EXPECTED_SHA256` verify, `SOURCE_DATE_EPOCH` env override, `check-versions-all`, `variants` listing
- `a390205` — AGENTS.md gains "Reproducibility scope (BDA — 2026-04-17)" section; spec/plan/tasks updated to drop cross-tree byte-identity goal (it's not achievable; rpmbuild bakes `_sourcedir` into the captured `%install` script in the SRPM header — see BDA for full diagnostic)
- `fd99f43` — README/AGENTS/HUMANS/CONTRIBUTING rewritten for multi-variant framing; CI workflow becomes `strategy.matrix.variant: [devbox]`; `variants/devbox/README.md` added

**Verification done:**
- Same-tree determinism preserved post-refactor (two back-to-back `SOURCE_DATE_EPOCH=1776424334 make VARIANT=devbox rpm` produce identical SHA256)
- `make VARIANT=devbox check-versions` green
- `actionlint .github/workflows/ci.yml` green
- `make variants` lists devbox correctly

**Phase B: in flight, NOT YET COMMITTED.** Files written but not yet committed:
- `variants/bastion-edge/variant.mk` ✓ written
- `variants/bastion-edge/.gitignore` ✓ written (excludes `extra-rpms/*.rpm`)
- `variants/bastion-edge/extra-rpms/.keep` ✓ written

**Phase B remaining:**
- `variants/bastion-edge/extra-rpms/EXPECTED_SHA256` — empty stub committable; populated by operator
- `variants/bastion-edge/blueprint.toml` — Fedora 43 minimal + bastion-edge runtime deps; pulls `bastion-edge` from local repo (which folds in `extra-rpms/`)
- `variants/bastion-edge/bastion-edge-firstboot/SPECS/bastion-edge-firstboot.spec` — minimal RPM that enables `bastion-edge.service`, reads cidata for edge-id
- `variants/bastion-edge/bastion-edge-firstboot/SOURCES/firstboot.sh` — oneshot, idempotent, reads `/var/lib/cloud/data/meta-data` → writes `/var/lib/bastion-edge/edge-id`
- `variants/bastion-edge/bastion-edge-firstboot/SOURCES/bastion-edge-firstboot.service` — systemd oneshot, After=cloud-init.target + bastion-edge.service
- `variants/bastion-edge/tests/smoke.sh` — modeled on `variants/devbox/tests/smoke.sh`; asserts `systemctl is-active bastion-edge`, firstboot done sentinel, edge-id populated, no Homebrew/no Claude
- `variants/bastion-edge/README.md` — describes inputs (operator-supplied RPM via `extra-rpms/`), outputs, smoke
- Add `bastion-edge` to CI matrix in `.github/workflows/ci.yml` (initially `if:` skipped; flip after first green build per HG)
- Update `tasks.md` checkboxes

### Bastion meta repo (`/usr/local/src/com.github/Rethunk-Tech/Bastion`, branch `main`, ahead 37)

**packaging-vm retirement spec landed:** `ea8a527 docs(spec): packaging-vm retirement via fedbuild variants` — spec.md + plan.md + tasks.md at `specs/active/packaging-vm-retirement/`. Spec is BLOCKED ON fedbuild Phase B per HB-A.

**Nothing else changed in Bastion meta** during this session.

## What comes next (in order)

1. **Finish Phase B scaffolding (agent-doable).** Write the 6 remaining files listed above. Run `make VARIANT=bastion-edge check-versions` + `make VARIANT=bastion-edge rpm` (the firstboot RPM should build without needing the operator-supplied bastion-edge*.rpm). Commit as `feat(edge): variants/bastion-edge/ blueprint + firstboot scaffold`.

2. **Phase B HG-2/HG-3/HG-4 (human-gated).** Operator drops a `bastion-edge-*.rpm` into `variants/bastion-edge/extra-rpms/`, populates `EXPECTED_SHA256`, runs `make VARIANT=bastion-edge image && make VARIANT=bastion-edge smoke && make VARIANT=bastion-edge bless-size`. Agent cannot do these — sudo + KVM required.

3. **Flip CI matrix** to include `bastion-edge` row (delete the `if:` skip) once HG-3 proves the variant green. Trivial commit.

4. **Bastion meta retirement spec execution.** After fedbuild Phase B fully green, return to `Bastion/specs/active/packaging-vm-retirement/tasks.md` P1–P6:
   - Add fedbuild as Bastion meta submodule pinned at Phase B landing SHA
   - Delete `scripts/packaging-vm/` (3 files, 1,069 lines), 4 shim delegators in bastion-core/bastion-edge, `bastion-core/.github/workflows/packaging-vm.yml`, 5 yarn scripts across 2 `package.json` files
   - Rewrite `bastion-core/HUMANS.md:462/465/472/484`, `bastion-core/AGENTS.md:151`, `bastion-core/deploy/systemd/bastion-core.service` header, `bastion-edge/HUMANS.md:66`
   - Create `Bastion/docs/infra/fedbuild.md`
   - Revert commit `733c304` mechanically (file disappears anyway)
   - NCA ack via `AskUserQuestion` per signoff section

5. **Update REV 13 umbrella `progress.md`** (`Bastion/specs/active/bastion-core-decomposition-rev13/progress.md`) to cross-reference packaging-vm retirement landing. Update `HUMAN_BLOCKERS.md` if any new gates surface.

## Key artifacts to read first when resuming

- **`/home/damonblais/fedbuild/AGENTS.md`** — section "Reproducibility scope (BDA — 2026-04-17)". DO NOT chase cross-tree RPM byte-identity; the BDA explains why and the memory entry `feedback_rpm_byte_identity.md` enforces this rule across future agent sessions.
- **`/home/damonblais/fedbuild/specs/active/multi-variant-refactor/{spec,plan,tasks}.md`** — current authoritative spec. F5/F5a are the operative reproducibility requirements.
- **`/usr/local/src/com.github/Rethunk-Tech/Bastion/specs/active/packaging-vm-retirement/{spec,plan,tasks}.md`** — the downstream spec that consumes Phase B's output.
- **`/home/damonblais/fedbuild/Makefile`** — the new Makefile shape; reference when writing the bastion-edge variant scaffolding.
- **`/home/damonblais/fedbuild/variants/devbox/`** — reference layout. Bastion-edge should mirror this structure, NOT bring in Homebrew / agent-settings / dev tools.

## Memory entries written this session

- `~/.claude/projects/-usr-local-src-com-github-Rethunk-Tech-Bastion/memory/feedback_rpm_byte_identity.md` — RPM cross-tree byte-identity rule + BDA reference
- `MEMORY.md` index updated with the row

## Sandbox notes for the next agent

- fedbuild lives at `/home/damonblais/fedbuild/` which is OUTSIDE the default sandbox write allowlist. All file writes there require `dangerouslyDisableSandbox: true` on Bash; Write/Edit work directly.
- All `git` operations on fedbuild MUST use the rethunk-git MCP tools with `workspaceRoot: "/home/damonblais/fedbuild"` (or chain `cd ... && git ...` with sandbox disabled).
- GitHub push remains blocked until 2026-04-26 per `project_github_ci_billing` memory. Local commits only.
- `bastion-packaging-vm.sh` should NOT be touched — it's about to be deleted by the Bastion retirement spec, not preserved.

## Commit policy reminders (already in CLAUDE.md/feedback memory)

- Conventional commits (`type(scope): subject`).
- One logical unit per commit; commit immediately, don't accumulate.
- Use MCP `batch_commit` with explicit `workspaceRoot` per repo.
- Never push (`project_github_ci_billing`).
- Phase B's `feat(edge): ...` commits should land before any `chore: flip CI matrix` commit.

## DELETE THIS FILE before landing the final Phase B commit

Per the `feedback_cleanup_progress_md.md` memory entry: this PROGRESS.md is a transient handoff doc. Once the next agent finishes Phase B and confirms the user is satisfied, this file is to be removed in the same commit that closes Phase B (or as a tiny `chore: remove progress handoff doc` follow-up). It exists only to bridge a context discontinuity, not to live in repo history.
