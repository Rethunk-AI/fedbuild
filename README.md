# fedbuild

Reproducible Fedora 43 VM image for running Bastion Agent (Claude Code, Gemini CLI) in isolation.

Two artifacts:
- **`bastion-vm-firstboot`** — RPM containing the firstboot systemd service + baked agent config
- **`fedora-43-devbox`** — Fedora 43 image (`.raw.zst`) built via `image-builder`

**Supply chain:** byte-identical RPMs (`SOURCE_DATE_EPOCH`), SHA256SUMS cosign-signed (keyless Sigstore), size budget enforced, `brew bundle` source-of-truth for non-RPM tools.

## Quick Start

```bash
make deps                                   # install createrepo_c (once)
cp ~/.ssh/id_ed25519.pub keys/authorized_key
make && make image && make smoke            # RPM → image → boot + verify
```

## Documentation

| Doc | Audience |
|-----|----------|
| **[HUMANS.md](HUMANS.md)** | Quick start, release flow, what first-boot installs |
| **[AGENTS.md](AGENTS.md)** | LLM reference: commands, architecture, blueprint format, gotchas |
| **[CONTRIBUTING.md](CONTRIBUTING.md)** | PR checklist, file-change map, commit style |
| **[CHANGELOG.md](CHANGELOG.md)** | Auto-generated from Conventional Commits (`make changelog`) |
| **[SECURITY.md](SECURITY.md)** | Vulnerability reporting |

## License

MIT — Copyright (c) 2026 Rethunk.Tech, LLC
