# fedbuild

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
| `make check` | Fast pre-push: shellcheck + TOML syntax + actionlint |
| `make shellcheck` | Lint shell scripts |
| `make lint` | Run rpmlint on built RPM |
| `make validate` | Check TOML syntax, SSH key, image-builder target |
| `make clean` | Remove build artifacts (keep images) |
| `make distclean` | Remove everything including images |
| `make deps` | Install createrepo_c |

## What First Boot Installs

The `bastion-vm-firstboot` service runs once as `user` and installs via Homebrew:

`actionlint`, `buf`, `kubectl`, `ollama`, `semgrep`, `stripe-cli`, `supabase`, `uv`, `watchexec`

AI coding CLIs via npm: `@anthropic-ai/claude-code`, `@google/gemini-cli`

Progress is visible in the journal: `journalctl -u bastion-vm-firstboot -f`
