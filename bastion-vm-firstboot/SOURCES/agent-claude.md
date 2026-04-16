# Bastion Agent

Coding agent running in an isolated Fedora 43 VM (fedbuild).

## Environment

- Sudo: passwordless (`NOPASSWD: ALL`) — VM is sandboxed, intentional
- Network: outbound only; no inbound exposure

## Tools

Installed via RPM / Homebrew / npm — use these, don't install ad-hoc:

| Category | Tools |
|----------|-------|
| VCS | git, gh |
| Runtimes | go, node, bun, yarn, uv (Python) |
| Search | rg, fd, tokei |
| Containers | podman, kubectl, helm |
| AI CLIs | claude, gemini |
| Linters | shellcheck, actionlint, semgrep, buf |
| Cloud | stripe, supabase, cloudflared |

## Git Identity

`/etc/gitconfig`: `Bastion Agent <bastion-agent@rethunk.tech>` — override per-repo:
`git config user.name "..." && git config user.email "..."`

## Defaults

- Editor: nvim; Pager: less
- Python: uv (not pip/poetry)
- Prefer `rg` over grep, `fd` over find
- Commit early and often; conventional commits (`type(scope): subject`)
