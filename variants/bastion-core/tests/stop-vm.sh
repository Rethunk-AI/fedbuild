#!/usr/bin/env bash
# stop-vm.sh — gracefully stop the persistent bastion-core VM.
#
# Usage: bash tests/stop-vm.sh [output-dir]
#   or:  make VARIANT=bastion-core stop-vm
set -euo pipefail

OUTDIR="${1:-output/bastion-core}"
PID_FILE="$OUTDIR/run/qemu.pid"

log() { echo "[stop-vm] $(date -Iseconds) $*"; }

if [[ ! -f "$PID_FILE" ]]; then
    echo "No PID file at $PID_FILE — VM not running (or run-vm was not used)"
    exit 0
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
    log "PID $PID not running — removing stale PID file"
    rm -f "$PID_FILE"
    exit 0
fi

log "Sending SIGTERM to QEMU PID $PID"
kill -TERM "$PID" 2>/dev/null || true

# Wait up to 10s for clean exit
for _ in $(seq 1 10); do
    sleep 1
    kill -0 "$PID" 2>/dev/null || { log "QEMU exited cleanly"; rm -f "$PID_FILE"; exit 0; }
done

log "QEMU did not exit within 10s — sending SIGKILL"
kill -KILL "$PID" 2>/dev/null || true
sleep 1
rm -f "$PID_FILE"
log "Done"
