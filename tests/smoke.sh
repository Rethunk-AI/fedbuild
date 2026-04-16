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
FAIL_LOG="${FAIL_LOG:-$OUTDIR/smoke-fail.log}"
SSH_UP=0

log() { echo "[smoke] $(date -Iseconds) $*"; }

# dump_journal: grab firstboot journal to $FAIL_LOG (best-effort; SSH may be down)
dump_journal() {
    [[ "$SSH_UP" == "1" ]] || { log "SSH never came up — no journal to capture"; return; }
    log "Capturing firstboot journal → $FAIL_LOG"
    mkdir -p "$(dirname "$FAIL_LOG")"
    ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager" \
        > "$FAIL_LOG" 2>&1 || log "  (journal capture failed)"
}

die() {
    echo "[smoke] ERROR: $*" >&2
    dump_journal
    exit 1
}

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
zstd -df --quiet "$IMAGE" -o "$TMPIMAGE"

# ── Boot VM ───────────────────────────────────────────────────────────────────
log "Booting VM (SSH forwarded to localhost:$SSH_PORT)"
qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 2 \
    -drive "file=$TMPIMAGE,format=raw,if=virtio" \
    -net nic,model=virtio \
    -net "user,hostfwd=tcp::${SSH_PORT}-:22" \
    -display none \
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
SSH_UP=1
log "SSH up"

# ── Wait for firstboot sentinel ───────────────────────────────────────────────
# Polls both 'done' (success) and 'failed' (error) so a broken firstboot
# aborts the smoke test in seconds instead of waiting out TIMEOUT_FIRSTBOOT.
log "Waiting for firstboot sentinel (up to ${TIMEOUT_FIRSTBOOT}s)"
deadline=$(( $(date +%s) + TIMEOUT_FIRSTBOOT ))
while :; do
    state=$(ssh "${SSH_OPTS[@]}" '
        if [ -f /var/lib/bastion-vm-firstboot/failed ]; then echo failed
        elif [ -f /var/lib/bastion-vm-firstboot/done ]; then echo done
        else echo waiting
        fi' 2>/dev/null || echo waiting)
    case "$state" in
        done) log "firstboot done"; break ;;
        failed)
            log "Dumping firstboot journal for diagnostics:"
            ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager" 2>/dev/null || true
            die "firstboot failed sentinel present — see journal above"
            ;;
    esac
    (( $(date +%s) < deadline )) || die "firstboot did not complete within ${TIMEOUT_FIRSTBOOT}s"
    sleep 15
    log "  still waiting..."
done

# ── Assert tools ──────────────────────────────────────────────────────────────
log "Asserting tool presence"
FAIL=""
TOOLS=(claude gemini git gh go node brew semgrep actionlint buf kubectl uv bun yarn stripe supabase watchexec)
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

# ── Log installed versions ────────────────────────────────────────────────────
# Captures actual version strings so partial/stale installs are visible in CI.
log "Logging installed versions"
log_version() {
    local tool="$1" actual
    # shellcheck disable=SC2029
    actual=$(ssh "${SSH_OPTS[@]}" "$tool --version 2>&1 | head -1" 2>/dev/null) || actual="<error>"
    log "  $tool: ${actual:-<no output>}"
}
log_version claude
log_version node
log_version go
log_version buf
log_version semgrep
log_version actionlint
log_version gemini

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
