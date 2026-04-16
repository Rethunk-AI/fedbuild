# Security

## Credentials

`keys/` is gitignored — SSH public keys are never committed.

`blueprint.toml` retains a `CHANGEME` placeholder; the real key is substituted at build time into `blueprint.effective.toml` (also gitignored).

## VM Security Model

The built VM is designed for isolated local use:

- No external IP or inbound network exposure
- `NOPASSWD: ALL` sudo for `user` is intentional — the VM is a sandboxed coding agent, not a multi-user system
- Homebrew and tools installed by `bastion-vm-firstboot` run as `user`, not root

## Reporting Issues

Open an issue at <https://github.com/Rethunk-AI/fedbuild/issues>.
