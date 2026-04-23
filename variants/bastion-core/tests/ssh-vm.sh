#!/usr/bin/env bash
# ssh-vm.sh — open an SSH session to the running bastion-core VM.
#
# Usage: bash tests/ssh-vm.sh [output-dir] [-- ssh-args...]
#   or:  make VARIANT=bastion-core ssh-vm
#
# Reads the ephemeral keypair written by run-vm.sh; no password needed.
set -euo pipefail

OUTDIR="${1:-output/bastion-core}"
shift || true

RUN_DIR="$OUTDIR/run"
KEY="$RUN_DIR/ssh-key"
VM_SSH_PORT="${VM_SSH_PORT:-2224}"

[[ -f "$KEY" ]] || {
    echo "ERROR: $KEY not found — run: make VARIANT=bastion-core run-vm first"
    exit 1
}

exec ssh \
    -i "$KEY" \
    -p "$VM_SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    bastion-operator@localhost \
    "$@"
