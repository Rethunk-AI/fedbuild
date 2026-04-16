# Contributing

## Getting Started

```bash
git clone git@github.com:Rethunk-AI/fedbuild.git
cd fedbuild
make deps
cp ~/.ssh/id_ed25519.pub keys/authorized_key
make
```

## Before Submitting a PR

Run all local checks:

```bash
make check        # shellcheck + TOML syntax + actionlint (fast, no RPM build)
make rpm          # build RPM
make lint         # rpmlint on built RPM
```

All checks must pass. CI runs the same suite automatically.

## What Goes Where

| Change | File(s) |
|--------|---------|
| New RPM package (available as RPM) | `blueprint.toml` — add `[[packages]]` entry |
| New tool installed via Homebrew | `bastion-vm-firstboot/SOURCES/firstboot.sh` |
| New environment variable or PATH entry | `bastion-vm-firstboot/SOURCES/devbox-profile.sh` |
| New file baked into the image | `blueprint.toml` — add `[[customizations.files]]` entry |
| External RPM repo | `blueprint.toml` — add `[[customizations.repositories]]` entry |
| Build orchestration | `Makefile` |

## Version Bumping

After any change, bump the `version` field in `blueprint.toml` (semver). Also bump `Version:` in `bastion-vm-firstboot/SPECS/bastion-vm-firstboot.spec` if the RPM changed.

## Commit Style

Conventional commits: `type(scope): subject`. Body explains motivation, not file list.

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`.

## Questions

Open a [discussion](https://github.com/Rethunk-AI/fedbuild/discussions) or [issue](https://github.com/Rethunk-AI/fedbuild/issues).
