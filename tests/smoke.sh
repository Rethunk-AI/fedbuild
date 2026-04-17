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
VERBOSE="${VERBOSE:-0}"
SSH_UP=0
FINISHED=0
START_EPOCH=$(date +%s)
BOOT_SECS=""        # populated when SSH comes up
FIRSTBOOT_SECS=""   # populated from Timing summary "total" row
TOOLS_OK=0
TOOLS_TOTAL=0

log() { echo "[smoke] $(date -Iseconds) $*"; }
# sub: indented sub-line without prefix/timestamp — reduces noise under section headers.
sub() { printf '  %s\n' "$*"; }
# row: aligned "label  value" under a section header.
row() { printf '  %-12s %s\n' "$1" "$2"; }
# status: "✓ label" or "✗ label" — glyph + item for pass/fail checks.
status() { printf '  %s %s\n' "$1" "$2"; }

# dump_journal: grab firstboot journal to $FAIL_LOG (best-effort; SSH may be down)
# Always called on exit (success or failure) via EXIT trap below — an empty
# smoke-fail.log that isn't written means SSH never came up, not that we skipped.
# FINISHED=1 means the success path already captured $SUCCESS_LOG and powered
# off the VM; the trap's capture would only produce "connection refused".
dump_journal() {
    [[ "$FINISHED" == "1" ]] && return
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
    # Route the error to both stdout (so wrappers capturing only stdout see it)
    # and stderr (so TTY users see red exit context). Dumps run on stdout via
    # log/sed prefixes; EXIT trap's cleanup will also call dump_journal.
    log "ERROR: $*"
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
    # Always grab the firstboot journal if SSH ever came up — avoids losing
    # diagnostics when the script exits via die() vs normal path.
    dump_journal 2>/dev/null || true
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

# VM host keys regenerate every boot — pin known_hosts to /dev/null so we never
# record them and never trip REMOTE HOST IDENTIFICATION HAS CHANGED on replays.
# LogLevel=ERROR suppresses the resulting "Permanently added" + host-key warnings
# that would otherwise pollute $SUCCESS_LOG (captures ssh stderr via 2>&1).
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -i "$SSH_KEY"
    -p "$SSH_PORT"
    user@localhost
)

# ── Wait for SSH ──────────────────────────────────────────────────────────────
log "Waiting for SSH (up to ${TIMEOUT_SSH}s)"
deadline=$(( $(date +%s) + TIMEOUT_SSH ))
until ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
    (( $(date +%s) < deadline )) || die "SSH not available within ${TIMEOUT_SSH}s"
    sleep 5
done
SSH_UP=1
BOOT_SECS=$(( $(date +%s) - START_EPOCH ))
log "SSH up (${BOOT_SECS}s from start)"

# ── Wait for firstboot sentinel ───────────────────────────────────────────────
# Polls both 'done' (success) and 'failed' (error) so a broken firstboot
# aborts the smoke test in seconds instead of waiting out TIMEOUT_FIRSTBOOT.
# Progress indicator: spinner + elapsed time on stderr when stderr is a TTY,
# so `make smoke | tee log` animates live but the log stays clean.
log "Waiting for firstboot sentinel (up to ${TIMEOUT_FIRSTBOOT}s)"
fb_start=$(date +%s)
deadline=$(( fb_start + TIMEOUT_FIRSTBOOT ))
spin=('|' '/' '-' "\\")
spin_i=0
tty=0; [[ -t 2 ]] && tty=1
# Use 'if' not '&&' — under `set -e` a false arithmetic test at end of the
# function would make clear_spin return non-zero and kill the script.
clear_spin() { if (( tty )); then printf '\r\033[K' >&2; fi; }
while :; do
    state=$(ssh "${SSH_OPTS[@]}" '
        if [ -f /var/lib/bastion-vm-firstboot/failed ]; then echo failed
        elif [ -f /var/lib/bastion-vm-firstboot/done ]; then echo done
        else echo waiting
        fi' 2>/dev/null || echo waiting)
    case "$state" in
        done) clear_spin; break ;;
        failed)
            clear_spin
            log "Dumping firstboot journal for diagnostics:"
            ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager" 2>/dev/null || true
            die "firstboot failed sentinel present — see journal above"
            ;;
    esac
    (( $(date +%s) < deadline )) || { clear_spin; die "firstboot did not complete within ${TIMEOUT_FIRSTBOOT}s"; }
    # Spinner animates every 1s while SSH polls every 5s (keeps load low).
    for _ in 1 2 3 4 5; do
        if (( tty )); then
            elapsed=$(( $(date +%s) - fb_start ))
            printf '\r  %s firstboot running... %ds elapsed' "${spin[spin_i % 4]}" "$elapsed" >&2
            spin_i=$((spin_i + 1))
        fi
        sleep 1
    done
done
log "firstboot done ($(( $(date +%s) - fb_start ))s)"

# ── Tool versions (combined presence + version check) ─────────────────────────
# A missing binary means log_version prints "<MISSING>" and marks FAIL — so
# this single section replaces the old separate "Asserting tool presence" loop.
log "Tool versions"
FAIL=""
# log_version <label> <remote-cmd> — runs remote-cmd via SSH; records MISSING
# when the binary isn't on PATH, otherwise prints first non-empty line.
log_version() {
    local label="$1" cmd="$2" bin actual head="$2"
    # Walk off leading "VAR=value " env-var prefixes (may be chained), then take
    # the first remaining whitespace token as the binary name. Previous logic
    # took the first token (an env var) and returned its value — making
    # `SEMGREP_ENABLE_VERSION_CHECK=0 semgrep --version` probe `0` instead of
    # `semgrep`, producing a false <MISSING>.
    while [[ "$head" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        head="${head#* }"
    done
    bin=${head%% *}
    TOOLS_TOTAL=$((TOOLS_TOTAL+1))
    # shellcheck disable=SC2029
    if ! ssh "${SSH_OPTS[@]}" "command -v $bin" >/dev/null 2>&1; then
        row "$label" "<MISSING>"
        FAIL=1
        return
    fi
    # shellcheck disable=SC2029
    actual=$(ssh "${SSH_OPTS[@]}" "$cmd 2>&1 | awk 'NF{print;exit}'" 2>/dev/null) || actual="<error>"
    TOOLS_OK=$((TOOLS_OK+1))
    row "$label" "${actual:-<no output>}"
}
log_version claude     'claude --version'
log_version gemini     'gemini --version'
log_version git        'git --version'
log_version gh         'gh --version'
log_version go         'go version'
log_version node       'node --version'
log_version brew       'brew --version'
log_version semgrep    'SEMGREP_ENABLE_VERSION_CHECK=0 semgrep --version'
log_version actionlint 'actionlint -version'
log_version buf        'buf --version'
log_version kubectl    'kubectl version --client=true'
log_version uv         'uv --version'
log_version bun        'bun --version'
log_version yarn       'yarn --version'
log_version supabase   'supabase --version'
log_version watchexec  'watchexec --version'
[[ -z "$FAIL" ]] || die "one or more tools missing"

# ── Dump firstboot journal on success ─────────────────────────────────────────
# Full journal (not just timing summary) so any warnings, brew bundle output,
# and per-section durations are visible alongside the smoke log.
SUCCESS_LOG="${SUCCESS_LOG:-$OUTDIR/smoke-firstboot.log}"
log "Capturing firstboot journal → $SUCCESS_LOG"
ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager -o cat" \
    > "$SUCCESS_LOG" 2>&1 || log "  (journal capture failed)"
if [[ -s "$SUCCESS_LOG" ]]; then
    log "Firstboot timing summary"
    sed -n '/Timing summary/,$p' "$SUCCESS_LOG" | sed 's/^/  /'
    # Extract "total" row (last column) for the final banner; tolerates spaces + 's' suffix.
    FIRSTBOOT_SECS=$(awk '/^ *total +[0-9]+s *$/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$SUCCESS_LOG")
fi

# ── SELinux enforcement ───────────────────────────────────────────────────────
# VM images must ship with SELinux enforcing + targeted policy. A permissive
# or disabled enforce state means a misconfiguration (kernel args, relabel,
# /etc/selinux/config). Custom labels aren't expected — just the defaults.
log "SELinux"
selinux_mode=$(ssh "${SSH_OPTS[@]}" 'getenforce 2>/dev/null || echo unknown')
selinux_policy=$(ssh "${SSH_OPTS[@]}" 'sestatus 2>/dev/null | awk -F: "/Loaded policy name/{gsub(/ /,\"\",\$2); print \$2}"' || true)
row "enforce" "$selinux_mode"
row "policy"  "${selinux_policy:-<unknown>}"
if [[ "$selinux_mode" != "Enforcing" ]]; then
    FAIL=1
    status "✗" "SELinux not enforcing (got: $selinux_mode)"
fi
if [[ "$selinux_policy" != "targeted" ]]; then
    FAIL=1
    status "✗" "SELinux policy != targeted (got: ${selinux_policy:-<unknown>})"
fi
[[ -z "$FAIL" ]] || die "SELinux assertions failed"

# ── Fedbuild release file ─────────────────────────────────────────────────────
# /etc/fedbuild-release is emitted by the RPM %post at image-build time.
# Missing file = RPM install regression.
log "Release file"
if ssh "${SSH_OPTS[@]}" 'test -f /etc/fedbuild-release' 2>/dev/null; then
    release_line=$(ssh "${SSH_OPTS[@]}" 'cat /etc/fedbuild-release' 2>/dev/null | awk -F= '/^VERSION=/{v=$2}/^GIT_COMMIT=/{g=$2}END{printf "v%s @ %s", v, substr(g,1,10)}')
    row "release" "$release_line"
else
    FAIL=1
    status "✗" "/etc/fedbuild-release missing"
fi

# ── Ready JSON ────────────────────────────────────────────────────────────────
# /var/log/fedbuild-ready.json is emitted by firstboot.sh on success.
log "Ready JSON"
if ssh "${SSH_OPTS[@]}" 'test -f /var/log/fedbuild-ready.json' 2>/dev/null; then
    ready=$(ssh "${SSH_OPTS[@]}" 'cat /var/log/fedbuild-ready.json' 2>/dev/null)
    if echo "$ready" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
        sub "valid JSON, $(echo -n "$ready" | wc -c) bytes"
    else
        FAIL=1
        status "✗" "ready JSON parse failed"
    fi
else
    FAIL=1
    status "✗" "/var/log/fedbuild-ready.json missing"
fi
[[ -z "$FAIL" ]] || die "release/ready assertions failed"

# ── Assert Claude config (show only failures unless VERBOSE=1) ───────────────
log "Claude config"
CONFIG_MISSING=0
for f in /home/user/.claude/CLAUDE.md /home/user/.claude/settings.json; do
    # shellcheck disable=SC2029
    if ssh "${SSH_OPTS[@]}" "test -f $f" 2>/dev/null; then
        [[ "$VERBOSE" == "1" ]] && status "✓" "$f"
    else
        status "✗" "$f"
        CONFIG_MISSING=1
        FAIL=1
    fi
done
[[ "$CONFIG_MISSING" == 0 && "$VERBOSE" != "1" ]] && sub "2/2 present"
[[ -z "$FAIL" ]] || die "Claude config files missing"

# ── Shutdown + final banner ───────────────────────────────────────────────────
# FINISHED=1 tells dump_journal (EXIT trap) to skip — $SUCCESS_LOG is already
# written and the VM is about to go down, so re-dumping would just log
# "connection refused" over a working capture.
FINISHED=1
ssh "${SSH_OPTS[@]}" "sudo poweroff" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

TOTAL_SECS=$(( $(date +%s) - START_EPOCH ))
IMG_SIZE=$(stat -c%s "$IMAGE" 2>/dev/null | awk '{printf "%.1fG", $1/1024/1024/1024}')
log "PASSED  image=$(basename "$IMAGE")  size=${IMG_SIZE:-?}  boot=${BOOT_SECS:-?}s  firstboot=${FIRSTBOOT_SECS:-?}s  tools=${TOOLS_OK}/${TOOLS_TOTAL}  total=${TOTAL_SECS}s"
