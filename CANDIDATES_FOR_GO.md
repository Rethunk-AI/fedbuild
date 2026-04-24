# CANDIDATES_FOR_GO

**Verdict:** Not a candidate.

**Scope:** N/A.

**Reasons:**
- `fedbuild` is a Make/shell/osbuild image builder wrapped around Fedora tooling (`rpmbuild`, `image-builder`, `createrepo`, `qemu-img`, `cosign`, `syft`).
- The root is orchestration around external CLIs and declarative RPM/image definitions, which is already idiomatic in Make and shell.
- A Go rewrite would mostly rewrap existing commands and make the build pipeline harder to inspect.

**Evidence:** `Makefile`, `variants/*/README.md`, `variants/*/SOURCES/firstboot.sh`, `variants/*/tests/*.sh`.
