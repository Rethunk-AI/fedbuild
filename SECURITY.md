# Security

## Reporting Issues

Open an issue at <https://github.com/Rethunk-AI/fedbuild/issues>. For suspected
credential leaks or supply-chain concerns, email `damon.blais@gmail.com`
directly before filing a public issue.

## Credentials

- `keys/` is gitignored — SSH public keys are never committed.
- `blueprint.toml` retains a `CHANGEME` placeholder; the real key is
  substituted at build time into `blueprint.effective.toml` (also gitignored).
- `/etc/sudoers.d/user` grants `NOPASSWD: ALL` to `user`. This is intentional
  (see trust boundary below) but means an attacker with `user` shell access
  has root.

## Threat Model

### Assets protected

1. **Host system** running the VM (developer laptop / CI runner).
2. **Source tree + repo credentials** the agent is given access to during a
   session.
3. **Outbound reputation / cost**: API calls charged to the operator's
   accounts (Anthropic, Google, GitHub, cloud).

### In scope

| Threat | Mitigation |
|--------|------------|
| VM escape to host | Relies on QEMU/KVM isolation; host runs latest Fedora. Agent has no access to host sockets or filesystem beyond explicitly forwarded ports. |
| Malicious upstream package | All RPMs signed (Fedora, Microsoft, Cloudflare GPG). Homebrew + npm installs are trust-on-first-use; `brew` bottles are checksummed but not GPG-signed. Versions pinned to `*` = "always update" → moving target. |
| Firstboot tampering | RPM reproducible (SOURCE_DATE_EPOCH). `%check` runs `shellcheck`. Image `SHA256SUMS` signed via `cosign` (Sigstore keyless). |
| Agent prompt injection from attacker-controlled content | Agent sandbox is the VM itself: if the agent is tricked into running destructive commands, the blast radius is one VM. No durable state crosses VM sessions. |
| Credential exfiltration | Outbound network is unrestricted (see limits, below). Do not inject long-lived credentials (prod DB, cloud admin) into the VM. Use short-lived, scoped tokens. |

### Out of scope

- **Multi-tenant isolation inside the VM** — there is only one `user` and
  root is a sudo away. Do not run hostile code alongside trusted code.
- **Kernel-level isolation between agent sessions** — use a fresh VM
  snapshot per session if you need this.
- **Side-channel attacks from the guest** against the host CPU (Spectre-class).
  Mitigated only by the host's microcode/kernel; fedbuild does not pin these.
- **Supply-chain attacks against Homebrew formulae or npm packages installed
  at firstboot**. No pinning, no signing, no SBOM today. See "Known Limits".

## Trust Boundary

```
┌──────────────────────────────────────────────────────────────────┐
│ Host OS (developer laptop / CI)                                 │
│  ─ trusts: fedbuild build toolchain, QEMU/KVM, OVMF, cosign      │
│  ─ exposes to VM: forwarded SSH port, optional mounted volumes   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Guest VM (fedora-43-devbox)                               │  │
│  │  ─ user=user, NOPASSWD sudo                                │  │
│  │  ─ trusts: baked RPM, Fedora repos, MS/Cloudflare RPMs,    │  │
│  │           Homebrew formulae, npm globals                   │  │
│  │  ─ network: outbound unrestricted, inbound SSH only        │  │
│  │                                                            │  │
│  │   ┌────────────────────────────────────────────────────┐   │  │
│  │   │ Agent process (claude / gemini CLI)               │   │  │
│  │   │  ─ runs as user                                    │   │  │
│  │   │  ─ permission-gated Bash commands via              │   │  │
│  │   │     ~/.claude/settings.json                        │   │  │
│  │   │  ─ has full sudo via parent shell                  │   │  │
│  │   └────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

- **Host → VM**: one-way; host treats VM as untrusted. Never mount host
  secrets read-write into the VM.
- **VM → Host**: no direct access. Agent cannot reach host localhost
  services unless the host explicitly forwards them in.
- **Agent → VM**: agent can escalate to root trivially. Do not rely on
  the `permissions.allow` list for security — it is for ergonomics, not
  sandboxing.

## Known Limits

- **No SBOM** of what lands in the image. `make diff-packages` gives an
  RPM-level diff but does not cover Homebrew/npm.
- **No SLSA provenance** on built images; only SHA256SUMS is signed.
- **Moving-target versions** — every rebuild can pull different RPM/brew/npm
  versions. Reproducibility is at the spec level, not the artifact level.
- **Homebrew on Linux** installs via `curl | bash`. The installer URL is
  HTTPS-fetched but not pinned to a known SHA.
- **Agent npm globals** (`@anthropic-ai/claude-code`, `@google/gemini-cli`)
  install `latest` at firstboot time.

## VM Security Model (summary)

The built VM is designed for isolated local use:

- No external IP or inbound network exposure (beyond forwarded SSH).
- `NOPASSWD: ALL` sudo for `user` is intentional — the VM is a sandboxed
  coding agent, not a multi-user system.
- Firstboot service runs as `user` (not root), with selected systemd
  sandboxing (`PrivateTmp`, `ProtectKernel*`, etc.).
- SELinux enforcing + targeted policy (asserted by `make smoke`).
- SSH hardened: key-only auth, no root login, no X11, allowlist = `user`.
