#!/usr/bin/env bash
# tests/smoke.sh — boot the built VM image in QEMU/KVM, SSH in, verify firstboot.
#
# Usage: bash tests/smoke.sh [output-dir]
#
# Requirements:
#   - qemu-system-x86_64 with KVM (/dev/kvm accessible)
#   - zstd (to decompress .raw.zst image)
#   - ssh + keys/authorized_key
#   - A built image from: make image
#
# The firstboot service can take up to 20 min (Homebrew installs).
# Tune TIMEOUT_FIRSTBOOT if needed.
set -euo pipefail

OUTDIR="${1:-output}"
SSH_KEY="${SSH_KEY:-keys/authorized_key}"
SSH_PORT="${SSH_PORT:-2222}"
TIMEOUT_SSH="${TIMEOUT_SSH:-120}"
TIMEOUT_FIRSTBOOT="${TIMEOUT_FIRSTBOOT:-1200}"

log() { echo "[smoke] $(date -Iseconds) $*"; }
die() { echo "[smoke] ERROR: $*" >&2; exit 1; }

# ── Locate image ──────────────────────────────────────────────────────────────
IMAGE=$(find "$OUTDIR" -name '*.raw.zst' | sort | tail -1)
[[ -n "$IMAGE" ]] || die "no .raw.zst image in $OUTDIR — run: make image"
log "Image: $IMAGE"

# ── Decompress to temp file ───────────────────────────────────────────────────
TMPIMAGE=$(mktemp /tmp/smoke-XXXXXX.raw)
QEMU_PID=""
cleanup() {
    rm -f "$TMPIMAGE"
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

log "Decompressing $(basename "$IMAGE") → $TMPIMAGE"
zstd -d --quiet "$IMAGE" -o "$TMPIMAGE"

# ── Boot VM ───────────────────────────────────────────────────────────────────
log "Booting VM (SSH forwarded to localhost:$SSH_PORT)"
qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 2 \
    -drive "file=$TMPIMAGE,format=raw,if=virtio" \
    -net nic,model=virtio \
    -net "user,hostfwd=tcp::${SSH_PORT}-:22" \
    -nographic \
    -serial none \
    -monitor none \
    -daemonize \
    -pidfile /tmp/smoke-qemu.pid

QEMU_PID=$(cat /tmp/smoke-qemu.pid)
rm -f /tmp/smoke-qemu.pid
log "QEMU PID $QEMU_PID"

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY" -p "$SSH_PORT" user@localhost)

# ── Wait for SSH ──────────────────────────────────────────────────────────────
log "Waiting for SSH (up to ${TIMEOUT_SSH}s)"
deadline=$(( $(date +%s) + TIMEOUT_SSH ))
until ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
    (( $(date +%s) < deadline )) || die "SSH not available within ${TIMEOUT_SSH}s"
    sleep 5
done
log "SSH up"

# ── Wait for firstboot sentinel ───────────────────────────────────────────────
log "Waiting for firstboot sentinel (up to ${TIMEOUT_FIRSTBOOT}s)"
deadline=$(( $(date +%s) + TIMEOUT_FIRSTBOOT ))
until ssh "${SSH_OPTS[@]}" "test -f /var/lib/bastion-vm-firstboot/done" 2>/dev/null; do
    (( $(date +%s) < deadline )) || die "firstboot did not complete within ${TIMEOUT_FIRSTBOOT}s"
    sleep 15
    log "  still waiting..."
done
log "firstboot done"

# ── Assert tools ──────────────────────────────────────────────────────────────
log "Asserting tool presence"
FAIL=""
TOOLS=(claude git gh go node brew semgrep actionlint buf kubectl)
for tool in "${TOOLS[@]}"; do
    # shellcheck disable=SC2029  # $tool intentionally expands client-side
    if ssh "${SSH_OPTS[@]}" "command -v $tool" 2>/dev/null; then
        log "  $tool: OK"
    else
        log "  $tool: MISSING"
        FAIL=1
    fi
done
[[ -z "$FAIL" ]] || die "one or more tools missing"

# ── Assert Claude config ───────────────────────────────────────────────────────
log "Asserting ~/.claude/ config"
for f in /home/user/.claude/CLAUDE.md /home/user/.claude/settings.json; do
    # shellcheck disable=SC2029  # $f intentionally expands client-side
    if ssh "${SSH_OPTS[@]}" "test -f $f" 2>/dev/null; then
        log "  $f: OK"
    else
        log "  $f: MISSING"
        FAIL=1
    fi
done
[[ -z "$FAIL" ]] || die "Claude config files missing"

# ── Shutdown ──────────────────────────────────────────────────────────────────
log "Shutting down VM"
ssh "${SSH_OPTS[@]}" "sudo poweroff" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

log "Smoke test PASSED"
