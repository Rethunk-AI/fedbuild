#!/usr/bin/env bash
# Smoke test for the bastion-core fedbuild variant.
# Invoked by `make VARIANT=bastion-core smoke` after the VM is booted.
# Contract (from root Makefile smoke target):
#   - SSH_TARGET, SSH_PORT, SSH_KEY are set by the Makefile
#   - OUTDIR points to output/bastion-core/ (image + log dir)
#   - FAIL_LOG defaults to $OUTDIR/smoke-fail.log

set -euo pipefail

: "${SSH_TARGET:?SSH_TARGET not set}"
: "${SSH_PORT:=2222}"
: "${SSH_KEY:?SSH_KEY not set}"
: "${OUTDIR:?OUTDIR not set}"
: "${FAIL_LOG:=${OUTDIR}/smoke-fail.log}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=30 -i "$SSH_KEY" -p "$SSH_PORT")

ssh() { command ssh "${SSH_OPTS[@]}" "bastion-operator@${SSH_TARGET}" "$@"; }
fail() {
    echo "SMOKE FAIL: $*" >&2
    ssh "sudo journalctl -u bastion-core-firstboot --no-pager -n 60" > "$FAIL_LOG" 2>&1 || true
    exit 1
}

echo "=== bastion-core smoke: $SSH_TARGET:$SSH_PORT ==="

# ── 1. Wait for FEDBUILD_READY on serial console (via journal) ───────────────
echo "Waiting for FEDBUILD_READY …"
TIMEOUT=240
ELAPSED=0
while true; do
    if ssh "sudo journalctl -u bastion-core-firstboot --no-pager 2>/dev/null | grep -q FEDBUILD_READY"; then
        echo "  FEDBUILD_READY confirmed"
        break
    fi
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        fail "FEDBUILD_READY not seen after ${TIMEOUT}s"
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

# ── 2. core-id written ───────────────────────────────────────────────────────
echo "Checking core-id …"
CORE_ID=$(ssh "cat /var/lib/bastion-core/core-id 2>/dev/null || true")
[[ -n "$CORE_ID" ]] || fail "core-id is empty — firstboot PKI roll may have failed"
echo "  core-id: $CORE_ID"

# ── 3. bootstrap.env has SAI callsign ───────────────────────────────────────
echo "Checking bootstrap.env …"
ssh "sudo grep -q BASTION_SAI_CALLSIGN /var/lib/bastion/install/bootstrap.env" \
    || fail "BASTION_SAI_CALLSIGN missing from bootstrap.env"

# ── 4. bastion-core.service active ──────────────────────────────────────────
echo "Checking bastion-core.service …"
ssh "sudo systemctl is-active bastion-core.service" \
    || fail "bastion-core.service not active"

# ── 5. bastion-web.service active ───────────────────────────────────────────
echo "Checking bastion-web.service …"
ssh "sudo systemctl is-active bastion-web.service" \
    || fail "bastion-web.service not active"

# ── 6. Fatal sidecar: credential-keystore ────────────────────────────────────
echo "Checking bastion-credential-keystore.service …"
ssh "sudo systemctl is-active bastion-credential-keystore.service" \
    || fail "bastion-credential-keystore.service not active (fatal sidecar)"

# ── 7. Check remaining sidecars (warn only) ──────────────────────────────────
SIDECARS=(
    bastion-ssh
    bastion-pack-loader
    bastion-pki-trust
    bastion-adcon-engine
    bastion-qemu
    bastion-adcon-mirror
    bastion-ironlaw-loader
    bastion-mfa
    bastion-intent-ledger-replicator
)
for svc in "${SIDECARS[@]}"; do
    if ssh "sudo systemctl is-active ${svc}.service" 2>/dev/null; then
        echo "  ${svc}: active"
    else
        echo "  WARN: ${svc}.service not active"
    fi
done

# ── 8. bastion-qemu socket present (needed for VM provisioning) ──────────────
echo "Checking bastion-qemu socket …"
ssh "test -S /run/bastion/qemu.sock" \
    || echo "  WARN: /run/bastion/qemu.sock not present (bastion-qemu may still be starting)"

# ── 9. /dev/kvm accessible (nested KVM) ──────────────────────────────────────
echo "Checking /dev/kvm …"
if ssh "test -e /dev/kvm"; then
    echo "  /dev/kvm present — nested KVM available"
else
    echo "  WARN: /dev/kvm missing — VM was not booted with -cpu host,+vmx/+svm"
fi

# ── 10. No SELinux AVC denials since boot ────────────────────────────────────
echo "Checking AVC denials …"
AVCS=$(ssh "sudo ausearch -m avc -ts boot 2>/dev/null | grep -c '^type=AVC' || true")
if [[ "${AVCS:-0}" -gt 0 ]]; then
    echo "  WARN: ${AVCS} AVC denial(s) since boot"
    ssh "sudo ausearch -m avc -ts boot --no-pid 2>/dev/null | tail -20" || true
else
    echo "  No AVC denials"
fi

echo "=== bastion-core smoke: PASS ==="
