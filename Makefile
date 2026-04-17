.DEFAULT_GOAL := repo
.PHONY: all deps rpm repo image smoke clean distclean help check check-versions check-settings check-size bless-size diff-packages lint shellcheck validate sign verify bump-patch bump-minor bump-major install-hooks changelog

FEDBUILD  := $(CURDIR)
TOPDIR    := $(FEDBUILD)/rpmbuild
REPODIR   := $(FEDBUILD)/repo
OUTDIR    := $(FEDBUILD)/output
SRCDIR    := $(FEDBUILD)/bastion-vm-firstboot/SOURCES
SPECFILE  := $(FEDBUILD)/bastion-vm-firstboot/SPECS/bastion-vm-firstboot.spec
BLUEPRINT         := $(FEDBUILD)/blueprint.toml
KEYFILE           := $(FEDBUILD)/keys/authorized_key
BLUEPRINT_EFFECTIVE := $(FEDBUILD)/blueprint.effective.toml
SHA256SUMS_FILE   := $(OUTDIR)/SHA256SUMS
SHA256SUMS_SIG    := $(OUTDIR)/SHA256SUMS.sig
SHA256SUMS_CERT   := $(OUTDIR)/SHA256SUMS.pem
SIZE_FILE         := $(OUTDIR)/SIZE
SIZE_BASELINE     := $(FEDBUILD)/tests/size.baseline
SIZE_BUDGET_PCT   ?= 10

PKG_NAME    := bastion-vm-firstboot
PKG_VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' $(SPECFILE))
PKG_RELEASE := $(shell sed -n 's/^Release:[[:space:]]*\([^%]*\).*/\1/p' $(SPECFILE))
DIST        := $(shell rpm -E '%{?dist}')
ARCH        := noarch

RPM         := $(TOPDIR)/RPMS/$(ARCH)/$(PKG_NAME)-$(PKG_VERSION)-$(PKG_RELEASE)$(DIST).$(ARCH).rpm
REPO_MARKER := $(REPODIR)/repodata/repomd.xml
SOURCES     := $(wildcard $(SRCDIR)/*)

# ── Targets ───────────────────────────────────────────────────────────────────

all: repo

## deps: install createrepo_c (required by the repo target)
deps:
	rpm -q createrepo_c >/dev/null 2>&1 || sudo dnf install -y createrepo_c

## rpm: build bastion-vm-firstboot RPM from spec + sources
## Reproducible build: SOURCE_DATE_EPOCH pins buildtime + clamps mtimes;
## LC_ALL/TZ pinned for deterministic string formatting. Epoch is the ctime
## of the last commit touching spec or sources (falls back to 'now' outside git).
$(RPM): $(SPECFILE) $(SOURCES)
	mkdir -p $(TOPDIR)/{BUILD,RPMS,SRPMS,SPECS,SOURCES}
	@sde=$$(git log -1 --format=%ct -- $(SPECFILE) $(SRCDIR) 2>/dev/null || date +%s); \
	 sha=$$(git rev-parse HEAD 2>/dev/null || echo unknown); \
	 echo "SOURCE_DATE_EPOCH=$$sde GIT_COMMIT=$$sha"; \
	 env LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=$$sde rpmbuild \
		--define "_topdir    $(TOPDIR)"                 \
		--define "_sourcedir $(SRCDIR)"                 \
		--define "_buildhost reproducible.fedbuild"     \
		--define "_git_commit $$sha"                    \
		--define "clamp_mtime_to_source_date_epoch 1"   \
		--define "use_source_date_epoch_as_buildtime 1" \
		--define "source_date_epoch_from_changelog 0"   \
		-ba $(SPECFILE)

rpm: $(RPM)

## repo: copy RPM into local yum repo and index it (default target)
$(REPO_MARKER): $(RPM)
	@command -v createrepo >/dev/null 2>&1 || \
		{ echo "createrepo_c not found — run: make deps"; exit 1; }
	rm -rf $(REPODIR)
	mkdir -p $(REPODIR)
	cp -v $(RPM) $(REPODIR)/
	createrepo $(REPODIR)

repo: $(REPO_MARKER)

## blueprint.effective.toml: substitute local SSH key into blueprint (requires keys/authorized_key)
$(BLUEPRINT_EFFECTIVE): $(BLUEPRINT) $(KEYFILE)
	@test -f $(KEYFILE) || { echo "ERROR: keys/authorized_key not found"; exit 1; }
	sed "s|ssh-ed25519 CHANGEME user@localhost|$$(cat $(KEYFILE))|" $(BLUEPRINT) > $(BLUEPRINT_EFFECTIVE)

## image: build the Fedora 43 VM image (requires sudo)
image: $(REPO_MARKER) $(BLUEPRINT_EFFECTIVE)
	mkdir -p $(OUTDIR)
	sudo image-builder build              \
		--distro     fedora-43            \
		--blueprint  $(BLUEPRINT_EFFECTIVE) \
		--extra-repo file://$(REPODIR)    \
		--extra-repo https://packages.microsoft.com/yumrepos/vscode \
		--extra-repo https://pkg.cloudflare.com/cloudflared/rpm \
		--output-dir $(OUTDIR)            \
		minimal-raw-zst
	cd $(OUTDIR) && sha256sum $$(find . -name '*.raw.zst' -printf '%P\n') > SHA256SUMS
	@echo "Wrote $(OUTDIR)/SHA256SUMS"
	@img=$$(find $(OUTDIR) -name '*.raw.zst' | sort | tail -1); \
	 stat -c%s "$$img" > $(SIZE_FILE); \
	 echo "Wrote $(SIZE_FILE) ($$(cat $(SIZE_FILE)) bytes)"
	@$(MAKE) --no-print-directory check-size

## check: fast pre-push checks — shellcheck, TOML syntax, actionlint, settings schema (no RPM build)
check: check-versions check-settings
	shellcheck $(SRCDIR)/firstboot.sh $(SRCDIR)/devbox-profile.sh tests/smoke.sh tests/diff-packages.sh
	@yq -p toml -oy '.' $(BLUEPRINT) >/dev/null && echo "blueprint.toml: OK"
	actionlint $(FEDBUILD)/.github/workflows/ci.yml

## check-settings: JSON-schema validate baked agent-settings.json
check-settings:
	@command -v check-jsonschema >/dev/null 2>&1 || \
		{ echo "ERROR: check-jsonschema not found — pip install check-jsonschema"; exit 1; }
	check-jsonschema \
		--schemafile $(FEDBUILD)/schemas/agent-settings.schema.json \
		$(SRCDIR)/agent-settings.json

## check-size: fail if built image exceeds baseline * (1 + SIZE_BUDGET_PCT/100)
check-size:
	@test -f $(SIZE_FILE) || { echo "ERROR: $(SIZE_FILE) missing — run: make image"; exit 1; }
	@test -f $(SIZE_BASELINE) || { echo "ERROR: $(SIZE_BASELINE) missing — run: make bless-size"; exit 1; }
	@cur=$$(cat $(SIZE_FILE)); base=$$(cat $(SIZE_BASELINE)); pct=$(SIZE_BUDGET_PCT); \
	 limit=$$(( base + base * pct / 100 )); \
	 delta=$$(( cur - base )); \
	 pct_delta=$$(awk -v c=$$cur -v b=$$base 'BEGIN{printf "%.2f", (c-b)*100.0/b}'); \
	 echo "Image size: $$cur bytes (baseline $$base, $$pct_delta%, budget +$$pct%)"; \
	 if [ "$$cur" -gt "$$limit" ]; then \
	     echo "ERROR: image exceeds baseline by >$$pct% (cur=$$cur, limit=$$limit, delta=$$delta)"; exit 1; \
	 fi

## bless-size: promote current image size to baseline (commit tests/size.baseline)
bless-size:
	@test -f $(SIZE_FILE) || { echo "ERROR: $(SIZE_FILE) missing — run: make image"; exit 1; }
	cp $(SIZE_FILE) $(SIZE_BASELINE)
	@echo "Baseline updated → $(SIZE_BASELINE) ($$(cat $(SIZE_BASELINE)) bytes)"

## check-versions: assert RPM spec Version and blueprint version match
check-versions:
	@spec_ver=$$(sed -n 's/^Version:[[:space:]]*//p' $(SPECFILE)); \
	 bp_ver=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 if [ "$$spec_ver" != "$$bp_ver" ]; then \
	     echo "ERROR: version mismatch — spec=$$spec_ver blueprint=$$bp_ver"; exit 1; \
	 else \
	     echo "Versions match: $$spec_ver"; \
	 fi

## shellcheck: lint all shell scripts in SOURCES and tests/
shellcheck:
	shellcheck $(SRCDIR)/firstboot.sh $(SRCDIR)/devbox-profile.sh tests/smoke.sh tests/diff-packages.sh

## lint: run rpmlint against the built RPM
lint: $(RPM)
	@rpm -q rpmlint >/dev/null 2>&1 || sudo dnf install -y rpmlint
	rpmlint --config $(FEDBUILD)/.rpmlintrc --ignore-unused-rpmlintrc $(RPM)

## validate: check blueprint syntax, SSH key, and target image type
validate: $(BLUEPRINT_EFFECTIVE)
	@echo "Checking TOML syntax..."
	@yq -p toml -oy '.' $(BLUEPRINT_EFFECTIVE) >/dev/null && echo "  OK"
	@echo "Checking SSH key placeholder..."
	@! grep -q 'CHANGEME' $(BLUEPRINT_EFFECTIVE) && echo "  OK" || \
		{ echo "  ERROR: SSH key not substituted in blueprint.effective.toml"; exit 1; }
	@echo "Checking target image type..."
	@image-builder list 2>/dev/null | grep -q 'fedora-43.*minimal-raw-zst.*x86_64' && echo "  OK" || \
		{ echo "  ERROR: fedora-43 minimal-raw-zst x86_64 not found in image-builder list"; exit 1; }

## sign: cosign keyless-sign output/SHA256SUMS (Sigstore OIDC); writes .sig + .pem
sign:
	@command -v cosign >/dev/null 2>&1 || \
		{ echo "ERROR: cosign not found — https://github.com/sigstore/cosign"; exit 1; }
	@test -f $(SHA256SUMS_FILE) || \
		{ echo "ERROR: $(SHA256SUMS_FILE) not found — run: make image"; exit 1; }
	cosign sign-blob --yes \
		--output-signature  $(SHA256SUMS_SIG)  \
		--output-certificate $(SHA256SUMS_CERT) \
		$(SHA256SUMS_FILE)
	@echo "Signed $(SHA256SUMS_FILE) → $(SHA256SUMS_SIG) + $(SHA256SUMS_CERT)"

## verify: cosign verify SHA256SUMS against Rekor (CERT_IDENTITY + CERT_OIDC_ISSUER required)
verify:
	@command -v cosign >/dev/null 2>&1 || { echo "ERROR: cosign not found"; exit 1; }
	@test -f $(SHA256SUMS_FILE) || { echo "ERROR: $(SHA256SUMS_FILE) not found"; exit 1; }
	@test -f $(SHA256SUMS_SIG)  || { echo "ERROR: $(SHA256SUMS_SIG) not found — run: make sign"; exit 1; }
	@test -f $(SHA256SUMS_CERT) || { echo "ERROR: $(SHA256SUMS_CERT) not found — run: make sign"; exit 1; }
	@test -n "$(CERT_IDENTITY)"    || { echo "ERROR: set CERT_IDENTITY=<email|URI>"; exit 1; }
	@test -n "$(CERT_OIDC_ISSUER)" || { echo "ERROR: set CERT_OIDC_ISSUER=<issuer URL>"; exit 1; }
	cosign verify-blob \
		--certificate           $(SHA256SUMS_CERT)  \
		--signature             $(SHA256SUMS_SIG)   \
		--certificate-identity  $(CERT_IDENTITY)    \
		--certificate-oidc-issuer $(CERT_OIDC_ISSUER) \
		$(SHA256SUMS_FILE)

## diff-packages: compare blueprint-declared RPMs against rpm -qa on a running VM
## (override: VM_HOST=user@localhost VM_SSH_PORT=2222 SSH_KEY=keys/authorized_key)
diff-packages:
	@bash tests/diff-packages.sh

## smoke: boot VM in QEMU/KVM and verify firstboot (requires built image + KVM)
smoke:
	@test -d $(OUTDIR) || { echo "ERROR: output/ not found — run: make image first"; exit 1; }
	@command -v qemu-system-x86_64 >/dev/null 2>&1 || \
		{ echo "ERROR: qemu-system-x86_64 not found — install qemu-kvm"; exit 1; }
	bash tests/smoke.sh $(OUTDIR)

## clean: remove rpmbuild tree, local repo, and effective blueprint
clean:
	rm -rf $(TOPDIR) $(REPODIR) $(BLUEPRINT_EFFECTIVE)

## distclean: clean + remove built images
distclean: clean
	rm -rf $(OUTDIR)

## bump-patch: bump Z in X.Y.Z (spec Release=1, blueprint version lockstep)
bump-patch:
	@cur=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 X=$$(echo "$$cur" | cut -d. -f1); \
	 Y=$$(echo "$$cur" | cut -d. -f2); \
	 Z=$$(echo "$$cur" | cut -d. -f3); \
	 new="$$X.$$Y.$$((Z+1))"; \
	 sed -i "s/^Version:[[:space:]].*/Version:        $$new/" $(SPECFILE); \
	 sed -i "s/^version[[:space:]]*=.*/version = \"$$new\"/" $(BLUEPRINT); \
	 echo "Bumped $$cur → $$new"; \
	 $(MAKE) --no-print-directory check-versions

## bump-minor: bump Y in X.Y.Z (resets Z to 0)
bump-minor:
	@cur=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 X=$$(echo "$$cur" | cut -d. -f1); \
	 Y=$$(echo "$$cur" | cut -d. -f2); \
	 new="$$X.$$((Y+1)).0"; \
	 sed -i "s/^Version:[[:space:]].*/Version:        $$new/" $(SPECFILE); \
	 sed -i "s/^version[[:space:]]*=.*/version = \"$$new\"/" $(BLUEPRINT); \
	 echo "Bumped $$cur → $$new"; \
	 $(MAKE) --no-print-directory check-versions

## bump-major: bump X in X.Y.Z (resets Y.Z to 0.0)
bump-major:
	@cur=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 X=$$(echo "$$cur" | cut -d. -f1); \
	 new="$$((X+1)).0.0"; \
	 sed -i "s/^Version:[[:space:]].*/Version:        $$new/" $(SPECFILE); \
	 sed -i "s/^version[[:space:]]*=.*/version = \"$$new\"/" $(BLUEPRINT); \
	 echo "Bumped $$cur → $$new"; \
	 $(MAKE) --no-print-directory check-versions

## changelog: regenerate CHANGELOG.md from Conventional Commits (via git-cliff + cliff.toml)
changelog:
	@command -v git-cliff >/dev/null 2>&1 || \
		{ echo "ERROR: git-cliff not found — brew install git-cliff"; exit 1; }
	git-cliff --config $(FEDBUILD)/cliff.toml --output $(FEDBUILD)/CHANGELOG.md
	@echo "Regenerated CHANGELOG.md"

## install-hooks: install pre-commit hooks from .pre-commit-config.yaml
install-hooks:
	@command -v pre-commit >/dev/null 2>&1 || \
		{ echo "ERROR: pre-commit not found — pip install pre-commit"; exit 1; }
	pre-commit install
	@echo "Installed → .git/hooks/pre-commit"

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
