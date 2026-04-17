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
# sub: indented sub-line without prefix/timestamp — reduces noise under section headers.
sub() { printf '  %s\n' "$*"; }
# row: aligned "label  value" under a section header.
row() { printf '  %-12s %s\n' "$1" "$2"; }
# status: "✓ label" or "✗ label" — glyph + item for pass/fail checks.
status() { printf '  %s %s\n' "$1" "$2"; }

# dump_journal: grab firstboot journal to $FAIL_LOG (best-effort; SSH may be down)
dump_journal() {
    [[ "$SSH_UP" == "1" ]] || { log "SSH never came up — no journal to capture"; return; }
    log "Capturing firstboot journal → $FAIL_LOG"
    mkdir -p "$(dirname "$FAIL_LOG")"
    ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager" \
        > "$FAIL_LOG" 2>&1 || log "  (journal capture failed)"
}

dump_serial() {
    [[ -s "${SERIAL_LOG:-}" ]] || { log "No serial output captured"; return; }
    log "Last 80 lines of serial console ($SERIAL_LOG):"
    tail -n 80 "$SERIAL_LOG" | sed 's/^/[serial] /'
}

dump_qemu() {
    [[ -s "${QEMU_LOG:-}" ]] || return
    log "QEMU stderr ($QEMU_LOG):"
    sed 's/^/[qemu] /' "$QEMU_LOG"
}

die() {
    echo "[smoke] ERROR: $*" >&2
    dump_qemu
    dump_serial
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
    rm -f "$TMPIMAGE" "${TMPVARS:-}"
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

log "Decompressing $(basename "$IMAGE") → $TMPIMAGE"
zstd -df --quiet "$IMAGE" -o "$TMPIMAGE"

# OVMF (UEFI) firmware — minimal-raw-zst boots via UEFI only.
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/ovmf/OVMF_VARS.fd}"
[[ -r "$OVMF_CODE" ]] || die "OVMF_CODE not readable: $OVMF_CODE (install edk2-ovmf)"
[[ -r "$OVMF_VARS_SRC" ]] || die "OVMF_VARS not readable: $OVMF_VARS_SRC"
TMPVARS=$(mktemp /tmp/smoke-vars-XXXXXX.fd)
cp "$OVMF_VARS_SRC" "$TMPVARS"

SERIAL_LOG="${SERIAL_LOG:-$OUTDIR/smoke-serial.log}"
QEMU_LOG="${QEMU_LOG:-$OUTDIR/smoke-qemu.log}"
mkdir -p "$(dirname "$SERIAL_LOG")"
: > "$SERIAL_LOG"
: > "$QEMU_LOG"
log "Serial console → $SERIAL_LOG"
log "QEMU stderr    → $QEMU_LOG"

# ── Boot VM ───────────────────────────────────────────────────────────────────
log "Booting VM (SSH forwarded to localhost:$SSH_PORT)"
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host \
    -m 4096 \
    -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$TMPVARS" \
    -drive "file=$TMPIMAGE,format=raw,if=virtio" \
    -net nic,model=virtio \
    -net "user,hostfwd=tcp::${SSH_PORT}-:22" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -monitor none \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
log "QEMU PID $QEMU_PID"

# Give QEMU a moment to exec; if it died immediately, surface the error now.
sleep 2
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" 2>/dev/null || true
    dump_qemu
    dump_serial
    die "QEMU exited before VM came up"
fi

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
TOOLS=(claude gemini git gh go node brew semgrep actionlint buf kubectl uv bun yarn supabase watchexec)
for tool in "${TOOLS[@]}"; do
    # shellcheck disable=SC2029  # $tool intentionally expands client-side
    if ssh "${SSH_OPTS[@]}" "command -v $tool" >/dev/null 2>&1; then
        status "✓" "$tool"
    else
        status "✗" "$tool"
        FAIL=1
    fi
done
[[ -z "$FAIL" ]] || die "one or more tools missing"

# ── Log installed versions ────────────────────────────────────────────────────
# Captures actual version strings so partial/stale installs are visible in CI.
log "Logging installed versions"
# log_version <label> <remote-cmd> — runs remote-cmd via SSH, logs first non-empty line.
# Per-tool cmd lets us handle flag quirks (go version, semgrep --version to stderr, etc.).
log_version() {
    local label="$1" cmd="$2" actual
    # shellcheck disable=SC2029
    actual=$(ssh "${SSH_OPTS[@]}" "$cmd 2>&1 | awk 'NF{print;exit}'" 2>/dev/null) || actual="<error>"
    row "$label" "${actual:-<no output>}"
}
log_version claude     'claude --version'
log_version node       'node --version'
log_version go         'go version'
log_version buf        'buf --version'
log_version semgrep    'semgrep --version'
log_version actionlint 'actionlint -version'
log_version gemini     'gemini --version'

# ── Assert Claude config ───────────────────────────────────────────────────────
log "Asserting ~/.claude/ config"
for f in /home/user/.claude/CLAUDE.md /home/user/.claude/settings.json; do
    # shellcheck disable=SC2029  # $f intentionally expands client-side
    if ssh "${SSH_OPTS[@]}" "test -f $f" 2>/dev/null; then
        status "✓" "$f"
    else
        status "✗" "$f"
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
