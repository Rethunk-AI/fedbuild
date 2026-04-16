# fedbuild

Builds a Fedora 43 VM image for use as an isolated coding-agent (Bastion Agent) environment.

Produces two artifacts:
- **`bastion-vm-firstboot` RPM** — systemd oneshot service that runs on first boot to install Homebrew and tools unavailable as RPMs
- **`fedora-43-devbox` image** — full VM image built by `image-builder`, provisioned via `blueprint.toml`

## Quick Start

```bash
# Prerequisites
make deps          # install createrepo_c

# Place your SSH public key
cp ~/.ssh/id_ed25519.pub keys/authorized_key

# Build RPM + local yum repo (default)
make

# Build VM image (requires sudo)
make image
```

## All Targets

| Target | Description |
|--------|-------------|
| `make` / `make repo` | Build RPM and index local yum repo |
| `make rpm` | Build RPM only |
| `make image` | Build Fedora 43 VM image |
| `make shellcheck` | Lint shell scripts |
| `make lint` | Run rpmlint on built RPM |
| `make validate` | Check TOML syntax, SSH key, image-builder target |
| `make clean` | Remove build artifacts (keep images) |
| `make distclean` | Remove everything including images |
| `make deps` | Install createrepo_c |

## Layout

```
fedbuild/
  blueprint.toml                          # osbuild blueprint — packages, repos, customizations
  Makefile                                # orchestration: rpm → repo → image chain
  bastion-vm-firstboot/
    SPECS/bastion-vm-firstboot.spec       # RPM spec
    SOURCES/
      firstboot.sh                        # runs on first boot as 'user', installs Homebrew + tools
      bastion-vm-firstboot.service        # systemd oneshot, User=user
      devbox-profile.sh                   # /etc/profile.d/devbox.sh — GOPATH, PATH, Homebrew
      user-sudoers                        # /etc/sudoers.d/user — NOPASSWD: ALL
  keys/                                   # SSH public key (gitignored)
  repo/                                   # local yum repo (createrepo output)
  output/                                 # built VM images (gitignored)
```

## What First Boot Installs

The `bastion-vm-firstboot` service runs once as `user` and installs via Homebrew:

`actionlint`, `buf`, `kubectl`, `ollama`, `semgrep`, `stripe-cli`, `supabase`, `uv`, `watchexec`

AI coding CLIs via npm: `@anthropic-ai/claude-code`, `@google/gemini-cli`

Progress is visible in the journal: `journalctl -u bastion-vm-firstboot -f`

## License

MIT — Copyright (c) 2026 Rethunk.Tech, LLC
