# Contributing

## Getting Started

Clone the repo, then follow the [Quick Start in HUMANS.md](HUMANS.md#quick-start).

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
| New RPM package | `blueprint.toml` — add `[[packages]]` entry |
| New Homebrew formula | `bastion-vm-firstboot/SOURCES/Brewfile` |
| New env var or PATH entry | `bastion-vm-firstboot/SOURCES/devbox-profile.sh` |
| New file baked into the image | `blueprint.toml` — `[[customizations.files]]` |
| External RPM repo | `blueprint.toml` — `[[customizations.repositories]]` |
| Build orchestration | `Makefile` |

## Version Bumping

Use `make bump-patch` / `bump-minor` / `bump-major` — they update spec + blueprint in lockstep and run `check-versions`. Then `make changelog` regenerates `CHANGELOG.md` from Conventional Commits (requires `brew install git-cliff`).

## Commit Style

Conventional commits: `type(scope): subject`. Body explains motivation, not file list. `git-cliff` groups them into changelog sections (`feat`→Added, `fix`→Fixed, `refactor`/`perf`→Changed, `docs`→Docs, `test`→Tests, `ci`→CI; `chore` is skipped).

## Questions

Open a [discussion](https://github.com/Rethunk-AI/fedbuild/discussions) or [issue](https://github.com/Rethunk-AI/fedbuild/issues).
