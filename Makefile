.DEFAULT_GOAL := repo
.PHONY: all deps rpm repo image clean distclean help lint shellcheck validate

FEDBUILD  := $(CURDIR)
TOPDIR    := $(FEDBUILD)/rpmbuild
REPODIR   := $(FEDBUILD)/repo
OUTDIR    := $(FEDBUILD)/output
SRCDIR    := $(FEDBUILD)/bastion-vm-firstboot/SOURCES
SPECFILE  := $(FEDBUILD)/bastion-vm-firstboot/SPECS/bastion-vm-firstboot.spec
BLUEPRINT         := $(FEDBUILD)/blueprint.toml
KEYFILE           := $(FEDBUILD)/keys/authorized_key
BLUEPRINT_EFFECTIVE := $(FEDBUILD)/blueprint.effective.toml

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

## shellcheck: lint all shell scripts in SOURCES
shellcheck:
	shellcheck $(SRCDIR)/firstboot.sh $(SRCDIR)/devbox-profile.sh

## lint: run rpmlint against the built RPM
lint: $(RPM)
	@rpm -q rpmlint >/dev/null 2>&1 || sudo dnf install -y rpmlint
	rpmlint $(RPM)

## validate: check blueprint syntax, SSH key, and target image type
validate: $(BLUEPRINT_EFFECTIVE)
	@echo "Checking TOML syntax..."
	@python3 -c "import tomllib; tomllib.load(open('$(BLUEPRINT_EFFECTIVE)', 'rb'))" && echo "  OK"
	@echo "Checking SSH key placeholder..."
	@! grep -q 'CHANGEME' $(BLUEPRINT_EFFECTIVE) && echo "  OK" || \
		{ echo "  ERROR: SSH key not substituted in blueprint.effective.toml"; exit 1; }
	@echo "Checking target image type..."
	@image-builder list 2>/dev/null | grep -q 'fedora-43.*minimal-raw-zst.*x86_64' && echo "  OK" || \
		{ echo "  ERROR: fedora-43 minimal-raw-zst x86_64 not found in image-builder list"; exit 1; }

## clean: remove rpmbuild tree, local repo, and effective blueprint
clean:
	rm -rf $(TOPDIR) $(REPODIR) $(BLUEPRINT_EFFECTIVE)

## distclean: clean + remove built images
distclean: clean
	rm -rf $(OUTDIR)

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
