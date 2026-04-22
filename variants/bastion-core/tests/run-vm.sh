#!/usr/bin/env bash
# run-vm.sh — launch bastion-core qcow2 in QEMU/KVM as a persistent VM.
#
# Usage: bash tests/run-vm.sh [output-dir]
#   or:  make VARIANT=bastion-core run-vm
#
# State lives in output-dir/run/:
#   overlay.qcow2   CoW overlay (writable; base qcow2 untouched)
#   OVMF_VARS.fd    per-VM writable UEFI variable store
#   seed.iso        cloud-init NoCloud seed (contains SSH pubkey)
#   ssh-key         private key for bastion-operator access (no passphrase)
#   ssh-key.pub     public key injected via cloud-init
#   qemu.pid        QEMU process ID (present while VM is running)
#   serial.log      VM serial console output
#   qemu.log        QEMU stderr (startup errors)
#
# The VM is persistent: overlay.qcow2 survives stop/start. To reset to a
# clean image, delete the run/ directory and re-run `make VARIANT=bastion-core run-vm`.
#
# Environment overrides (all optional):
#   VM_SSH_PORT   host port → VM :22    (default: 2224)
#   VM_WEB_PORT   host port → VM :4173  (default: 4173)
#   VM_WS_PORT    host port → VM :8765  (default: 8765)
#   VM_MEM        QEMU RAM in MiB       (default: 16384)
#   VM_SMP        QEMU vCPU count       (default: 8)
#   OVMF_CODE     path to OVMF_CODE.fd  (default: auto-detected)
#   OVMF_VARS_SRC path to OVMF_VARS.fd  (default: auto-detected)
set -euo pipefail

OUTDIR="${1:-output/bastion-core}"
RUN_DIR="$OUTDIR/run"
VM_SSH_PORT="${VM_SSH_PORT:-2224}"
VM_WEB_PORT="${VM_WEB_PORT:-4173}"
VM_WS_PORT="${VM_WS_PORT:-8765}"
VM_MEM="${VM_MEM:-16384}"
VM_SMP="${VM_SMP:-8}"

OVERLAY="$RUN_DIR/overlay.qcow2"
VARS="$RUN_DIR/OVMF_VARS.fd"
SEED="$RUN_DIR/seed.iso"
KEY="$RUN_DIR/ssh-key"
PID_FILE="$RUN_DIR/qemu.pid"
SERIAL_LOG="$RUN_DIR/serial.log"
QEMU_LOG="$RUN_DIR/qemu.log"

log() { echo "[run-vm] $(date -Iseconds) $*"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
[[ -d "$OUTDIR" ]] || { echo "ERROR: $OUTDIR not found — run: make VARIANT=bastion-core image"; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "ERROR: qemu-system-x86_64 not found"; exit 1; }
command -v ssh-keygen           >/dev/null 2>&1 || { echo "ERROR: ssh-keygen not found"; exit 1; }
[[ -e /dev/kvm ]] || { echo "ERROR: /dev/kvm not accessible — KVM required"; exit 1; }

ISOGEN=""
for cmd in genisoimage mkisofs xorrisofs; do
    command -v "$cmd" >/dev/null 2>&1 && { ISOGEN="$cmd"; break; }
done
[[ -n "$ISOGEN" ]] || { echo "ERROR: genisoimage/mkisofs/xorrisofs not found — install genisoimage"; exit 1; }

OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-}"
for d in /usr/share/edk2/ovmf /usr/share/OVMF /usr/share/qemu; do
    [[ -z "$OVMF_CODE"     && -r "$d/OVMF_CODE.fd" ]] && OVMF_CODE="$d/OVMF_CODE.fd"
    [[ -z "$OVMF_VARS_SRC" && -r "$d/OVMF_VARS.fd" ]] && OVMF_VARS_SRC="$d/OVMF_VARS.fd"
done
[[ -r "$OVMF_CODE"     ]] || { echo "ERROR: OVMF_CODE.fd not found (install edk2-ovmf)"; exit 1; }
[[ -r "$OVMF_VARS_SRC" ]] || { echo "ERROR: OVMF_VARS.fd not found (install edk2-ovmf)"; exit 1; }

IMAGE=$(find "$OUTDIR" -maxdepth 1 -name '*.qcow2' ! -path '*/run/*' | sort | tail -1)
[[ -n "$IMAGE" ]] || { echo "ERROR: no .qcow2 in $OUTDIR — run: make VARIANT=bastion-core image"; exit 1; }

# ── Check if already running ──────────────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        log "VM already running (PID $PID)"
        echo ""
        echo "  SSH:     ssh -i $KEY -p $VM_SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null bastion-operator@localhost"
        echo "  Web UI:  http://localhost:$VM_WEB_PORT"
        echo "  WS:      ws://localhost:$VM_WS_PORT"
        echo "  Stop:    make VARIANT=bastion-core stop-vm"
        echo ""
        exit 0
    fi
    log "Stale PID file ($PID no longer running) — cleaning up"
    rm -f "$PID_FILE"
fi

mkdir -p "$RUN_DIR"

# ── SSH keypair (stable; survives stop/start) ─────────────────────────────────
if [[ ! -f "$KEY" ]]; then
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "bastion-core-run" -q
    log "Generated SSH key: $KEY"
else
    log "Reusing existing SSH key: $KEY"
fi
PUBKEY=$(cat "${KEY}.pub")

# ── Cloud-init seed (rebuild if key changed or seed missing) ──────────────────
if [[ ! -f "$SEED" || "$KEY.pub" -nt "$SEED" ]]; then
    SEEDTMP=$(mktemp -d "${TMPDIR:-/tmp}/bastion-seed-XXXXXX")
    cat > "$SEEDTMP/meta-data" <<EOF
instance-id: bastion-core-run
local-hostname: bastion-core
EOF
    cat > "$SEEDTMP/user-data" <<EOF
#cloud-config
users:
  - name: bastion-operator
    ssh_authorized_keys:
      - ${PUBKEY}
EOF
    "$ISOGEN" -output "$SEED" -volid cidata -joliet -rock \
        "$SEEDTMP/meta-data" "$SEEDTMP/user-data" 2>/dev/null
    rm -rf "$SEEDTMP"
    log "Built cloud-init seed: $SEED"
fi

# ── CoW overlay (create fresh if base image is newer) ────────────────────────
if [[ ! -f "$OVERLAY" || "$IMAGE" -nt "$OVERLAY" ]]; then
    [[ -f "$OVERLAY" ]] && log "Base image updated — recreating overlay"
    qemu-img create -f qcow2 -b "$IMAGE" -F qcow2 "$OVERLAY" 2>/dev/null
    log "Created CoW overlay: $OVERLAY"
else
    log "Reusing existing overlay: $OVERLAY"
fi

# ── OVMF VARS (copy if missing) ───────────────────────────────────────────────
[[ -f "$VARS" ]] || cp "$OVMF_VARS_SRC" "$VARS"

# ── Launch QEMU ───────────────────────────────────────────────────────────────
: > "$SERIAL_LOG"
: > "$QEMU_LOG"

log "Booting bastion-core (SSH :$VM_SSH_PORT, web :$VM_WEB_PORT, ws :$VM_WS_PORT, ${VM_MEM}MiB, ${VM_SMP} vCPUs)"

setsid qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host,+svm \
    -m "$VM_MEM" \
    -smp "$VM_SMP" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$VARS" \
    -drive "file=$OVERLAY,format=qcow2,if=virtio" \
    -drive "file=$SEED,format=raw,if=virtio,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22,hostfwd=tcp::${VM_WEB_PORT}-:4173,hostfwd=tcp::${VM_WS_PORT}-:8765" \
    -device "virtio-net-pci,netdev=net0" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    >"$QEMU_LOG" 2>&1 &

QEMU_PID=$!
echo "$QEMU_PID" > "$PID_FILE"

sleep 2
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "ERROR: QEMU exited immediately"
    [[ -s "$QEMU_LOG" ]] && sed 's/^/[qemu] /' "$QEMU_LOG"
    exit 1
fi

log "QEMU PID $QEMU_PID — VM is starting"
log "Serial log: $SERIAL_LOG"
echo ""
echo "  SSH:     ssh -i $KEY -p $VM_SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null bastion-operator@localhost"
echo "  Web UI:  http://localhost:$VM_WEB_PORT  (available after firstboot ~5min)"
echo "  WS:      ws://localhost:$VM_WS_PORT"
echo "  Logs:    tail -f $SERIAL_LOG"
echo "  Stop:    make VARIANT=bastion-core stop-vm"
echo ""
echo "  Waiting for FEDBUILD_READY (up to 300s) ..."
set +e
timeout 300 awk '
    /^FEDBUILD_READY/  { print; exit 0 }
    /^FEDBUILD_FAILED/ { print; exit 1 }
' < <(tail -F -n +1 "$SERIAL_LOG" 2>/dev/null) >/dev/null
FB_RC=$?
set -e
case "$FB_RC" in
    0)   log "FEDBUILD_READY — bastion-core is up" ;;
    1)   log "FEDBUILD_FAILED on serial — check: journalctl -u bastion-core-firstboot" ;;
    124) log "Timeout waiting for FEDBUILD_READY — VM may still be booting; check: tail -f $SERIAL_LOG" ;;
    *)   log "Serial wait returned rc=$FB_RC" ;;
esac
