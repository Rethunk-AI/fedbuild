#!/usr/bin/env bash
# tests/smoke-rerun.sh — idempotency test: boot VM, verify firstboot, reset sentinel,
# restart service, verify second firstboot completes cleanly.
#
# Usage: bash tests/smoke-rerun.sh [output-dir]
#
# Requirements: same as smoke.sh (KVM, zstd, ssh, built image).
#
# Writes:
#   output/smoke-rerun.log  — journal dumps from both firstboot runs
#
# Exit codes: 0 = pass, 1 = fail.
set -euo pipefail

OUTDIR="${1:-output}"
SSH_KEY="${SSH_KEY:-keys/authorized_key}"
SSH_PORT="${SSH_PORT:-2222}"
TIMEOUT_SSH="${TIMEOUT_SSH:-120}"
TIMEOUT_FIRSTBOOT="${TIMEOUT_FIRSTBOOT:-1200}"
FAIL_LOG="${FAIL_LOG:-$OUTDIR/smoke-fail.log}"
RERUN_LOG="${RERUN_LOG:-$OUTDIR/smoke-rerun.log}"
SERIAL_TAIL="${SERIAL_TAIL:-1}"
SSH_UP=0
TAIL_PID=""

log()    { echo "[rerun] $(date -Iseconds) $*"; }
sub()    { printf '  %s\n' "$*"; }
row()    { printf '  %-12s %s\n' "$1" "$2"; }
status() { printf '  %s %s\n' "$1" "$2"; }

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
    echo "[rerun] ERROR: $*" >&2
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
TMPIMAGE=$(mktemp /tmp/rerun-XXXXXX.raw)
QEMU_PID=""
cleanup() {
    [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null || true
    rm -f "$TMPIMAGE" "${TMPVARS:-}"
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

log "Decompressing $(basename "$IMAGE") → $TMPIMAGE"
zstd -df --quiet "$IMAGE" -o "$TMPIMAGE"

OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/ovmf/OVMF_VARS.fd}"
[[ -r "$OVMF_CODE" ]] || die "OVMF_CODE not readable: $OVMF_CODE (install edk2-ovmf)"
[[ -r "$OVMF_VARS_SRC" ]] || die "OVMF_VARS not readable: $OVMF_VARS_SRC"
TMPVARS=$(mktemp /tmp/rerun-vars-XXXXXX.fd)
cp "$OVMF_VARS_SRC" "$TMPVARS"

SERIAL_LOG="${SERIAL_LOG:-$OUTDIR/rerun-serial.log}"
QEMU_LOG="${QEMU_LOG:-$OUTDIR/rerun-qemu.log}"
mkdir -p "$(dirname "$SERIAL_LOG")" "$(dirname "$RERUN_LOG")"
: > "$SERIAL_LOG"
: > "$QEMU_LOG"
: > "$RERUN_LOG"
log "Serial console → $SERIAL_LOG"
log "QEMU stderr    → $QEMU_LOG"
log "Journal log    → $RERUN_LOG"

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

sleep 2
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" 2>/dev/null || true
    dump_qemu
    dump_serial
    die "QEMU exited before VM came up"
fi

# Live VM serial → stdout. See smoke.sh for rationale.
if [[ "$SERIAL_TAIL" == "1" ]]; then
    tail -F "$SERIAL_LOG" 2>/dev/null | sed -u 's/^/[vm] /' &
    TAIL_PID=$!
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

# wait_marker <label> <n> <var>: waits for the Nth FEDBUILD_READY on serial;
# fails on the Nth FEDBUILD_FAILED. N=1 for first boot, N=2 for second run
# after the service restart. Uses tail -F -n +1 so awk sees the full log
# history — restart-run REREADs past READYs but only exits once count==N.
#
# Elapsed time is from call start (post-restart), so SECONDBOOT_SECS reflects
# restart→ready, not total. No SSH dependency: relies on journal+console
# routing in the unit file.
wait_marker() {
    local label="$1" n="$2" var="$3" start rc elapsed
    log "Waiting for ${label} FEDBUILD_READY (occurrence #${n}, up to ${TIMEOUT_FIRSTBOOT}s)"
    start=$(date +%s)
    set +e
    timeout "$TIMEOUT_FIRSTBOOT" awk -v want="$n" '
        /^FEDBUILD_READY/  { ready++;   if (ready  >= want) { print; exit 0 } }
        /^FEDBUILD_FAILED/ { failed++;  if (failed >= want) { print; exit 1 } }
    ' < <(tail -F -n +1 "$SERIAL_LOG" 2>/dev/null) >/dev/null
    rc=$?
    set -e
    case "$rc" in
        0)   ;;
        1)   die "${label} FEDBUILD_FAILED marker seen — see [vm] stream above" ;;
        124) die "${label} FEDBUILD_READY #${n} not seen within ${TIMEOUT_FIRSTBOOT}s" ;;
        *)   die "${label} serial wait returned unexpected rc=${rc}" ;;
    esac
    elapsed=$(( $(date +%s) - start ))
    log "${label} ready in ${elapsed}s"
    printf -v "$var" '%s' "$elapsed"
}

# ── First boot ────────────────────────────────────────────────────────────────
FIRSTBOOT_SECS=0
wait_marker "first" 1 FIRSTBOOT_SECS

log "Capturing first-boot journal → $RERUN_LOG"
{
    echo "=== FIRST BOOT JOURNAL ==="
    ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager" 2>/dev/null || true
    echo ""
} >> "$RERUN_LOG"

# Quick tool-presence sanity check (subset) before resetting sentinel
log "Sanity check: tool presence"
FAIL=""
for tool in claude git brew; do
    # shellcheck disable=SC2029  # $tool intentionally expands client-side
    if ssh "${SSH_OPTS[@]}" "command -v $tool" >/dev/null 2>&1; then
        status "✓" "$tool"
    else
        status "✗" "$tool"
        FAIL=1
    fi
done
[[ -z "$FAIL" ]] || die "tool sanity check failed before rerun"

# ── Reset sentinel and trigger second run ────────────────────────────────────
log "Resetting firstboot sentinel for idempotency run"
ssh "${SSH_OPTS[@]}" "sudo rm -f /var/lib/bastion-vm-firstboot/done /var/lib/bastion-vm-firstboot/failed"
log "Restarting bastion-vm-firstboot.service"
ssh "${SSH_OPTS[@]}" "sudo systemctl restart bastion-vm-firstboot.service"

# ── Second boot ───────────────────────────────────────────────────────────────
SECONDBOOT_SECS=0
wait_marker "second" 2 SECONDBOOT_SECS

log "Capturing second-boot journal → $RERUN_LOG"
{
    echo "=== SECOND BOOT JOURNAL ==="
    ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager" 2>/dev/null || true
    echo ""
} >> "$RERUN_LOG"

# Verify second run completed cleanly (done sentinel exists, failed does not)
second_state=$(ssh "${SSH_OPTS[@]}" '
    if [ -f /var/lib/bastion-vm-firstboot/failed ]; then echo failed
    elif [ -f /var/lib/bastion-vm-firstboot/done ]; then echo done
    else echo missing
    fi' 2>/dev/null || echo missing)
[[ "$second_state" == "done" ]] || die "second firstboot did not produce done sentinel (state=$second_state)"
status "✓" "second firstboot done sentinel present"

# ── Idempotency time check (WARN only) ───────────────────────────────────────
# Second run should be faster (cached brew packages) — warn if it's >50% of first.
if (( FIRSTBOOT_SECS > 0 )); then
    half=$(( FIRSTBOOT_SECS / 2 ))
    if (( SECONDBOOT_SECS > half )); then
        log "WARN: second boot (${SECONDBOOT_SECS}s) > 50% of first boot (${FIRSTBOOT_SECS}s) — brew cache may be cold"
    else
        log "Idempotency time OK: second=${SECONDBOOT_SECS}s, first=${FIRSTBOOT_SECS}s"
    fi
fi

# ── Shutdown ──────────────────────────────────────────────────────────────────
log "Shutting down VM"
ssh "${SSH_OPTS[@]}" "sudo poweroff" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

log "PASSED smoke-rerun: firstboot=${FIRSTBOOT_SECS}s secondboot=${SECONDBOOT_SECS}s"
