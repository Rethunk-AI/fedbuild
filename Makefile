.DEFAULT_GOAL := repo
.PHONY: all deps rpm repo image smoke clean distclean help check check-versions check-settings lint shellcheck validate sign verify

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
$(RPM): $(SPECFILE) $(SOURCES)
	mkdir -p $(TOPDIR)/{BUILD,RPMS,SRPMS,SPECS,SOURCES}
	rpmbuild \
		--define "_topdir    $(TOPDIR)"  \
		--define "_sourcedir $(SRCDIR)"  \
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
		--extra-repo $(REPODIR)           \
		--output-dir $(OUTDIR)            \
		minimal-raw-zst
	cd $(OUTDIR) && sha256sum $$(find . -name '*.raw.zst' -printf '%P\n') > SHA256SUMS
	@echo "Wrote $(OUTDIR)/SHA256SUMS"

## check: fast pre-push checks — shellcheck, TOML syntax, actionlint, settings schema (no RPM build)
check: check-versions check-settings
	shellcheck $(SRCDIR)/firstboot.sh $(SRCDIR)/devbox-profile.sh tests/smoke.sh
	@yq -p toml -oy '.' $(BLUEPRINT) >/dev/null && echo "blueprint.toml: OK"
	actionlint $(FEDBUILD)/.github/workflows/ci.yml

## check-settings: JSON-schema validate baked agent-settings.json
check-settings:
	@command -v check-jsonschema >/dev/null 2>&1 || \
		{ echo "ERROR: check-jsonschema not found — pip install check-jsonschema"; exit 1; }
	check-jsonschema \
		--schemafile $(FEDBUILD)/schemas/agent-settings.schema.json \
		$(SRCDIR)/agent-settings.json

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
	shellcheck $(SRCDIR)/firstboot.sh $(SRCDIR)/devbox-profile.sh tests/smoke.sh

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

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
