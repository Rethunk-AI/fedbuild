#!/bin/bash
# bastion-core-firstboot — runs once on first boot as root.
#
# Purpose:
#   1. Roll the PKI (BASTION_PKI_EPOCH_ROLL=1) so each VM gets unique
#      cryptographic identity rather than the image-baked defaults generated
#      during RPM %post at image build time.
#   2. Source /var/lib/bastion/install/bootstrap.env and record the per-VM SAI
#      callsign in /var/lib/bastion-core/core-id.
#   3. Write /etc/bastion-core-release (consumed by smoke + operators).
#
# The bastion-core-firstboot.service unit has:
#   ConditionPathExists=!/var/lib/bastion/firstboot-done
# so this runs at most once per VM lifetime. Delete firstboot-done to re-run.
set -euo pipefail

SENTINEL_DIR=/var/lib/bastion-core
SERIAL=/dev/ttyS0
serial() { [[ -w "$SERIAL" ]] && printf '%s\n' "$*" > "$SERIAL" 2>/dev/null || true; }
log()  { echo "[firstboot] $(date -Iseconds) $*"; serial "[firstboot] $*"; }
mark() { printf 'FEDBUILD_MARK: %s\n' "$*"; serial "FEDBUILD_MARK: $*"; }

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log "FAILED (exit $rc) — writing failure sentinel"
        touch "${SENTINEL_DIR}/failed" 2>/dev/null || true
        printf 'FEDBUILD_FAILED %d\n' "$rc"
        serial "FEDBUILD_FAILED $rc"
    fi
}
trap on_exit EXIT

log "Starting"
mark "firstboot-start"

install -d -m 0755 "$SENTINEL_DIR"

# ── Roll PKI — generate unique SAI + service-ca per VM ──────────────────────
# bastion-package-init ran during RPM %post (image build time) and already
# populated /var/lib/bastion/install/bootstrap.env with a default SAI.
# BASTION_PKI_EPOCH_ROLL=1 forces regeneration so every booted VM gets a
# unique callsign, BASTION_WS_TOKEN, and PKI leaf set.
PACKAGE_INIT=/usr/libexec/bastion-core/bastion-package-init
if [[ ! -x "$PACKAGE_INIT" ]]; then
    log "ERROR: $PACKAGE_INIT not found — is bastion-core RPM installed?"
    exit 1
fi

log "Rolling PKI (BASTION_PKI_EPOCH_ROLL=1) …"
mark "pki-roll-start"
BASTION_PKI_EPOCH_ROLL=1 "$PACKAGE_INIT"
log "PKI rolled"
mark "pki-roll-done"

# ── Provision service-plane CA and sidecar TLS leaves ───────────────────────
# bastion-provision creates /var/lib/bastion/service-ca/{ca.crt,ca.key,
# client.crt,client.key} and issues leaf certs to
# /var/lib/bastion/service-ca/issued/<subject>/{cert.pem,key.pem} for every
# sidecar subject. Must run before any sidecar service starts.
PROVISION_JS=/usr/lib64/bastion-core/apps/server/dist/scripts/bastion-provision.js
if [[ ! -f "$PROVISION_JS" ]]; then
    log "ERROR: $PROVISION_JS not found — is bastion-core RPM installed?"
    exit 1
fi
log "Provisioning service-plane CA and sidecar TLS leaves …"
mark "service-ca-start"
# bastion-core dist is compiled with "module: NodeNext" — Node.js treats .js
# as CJS by default and raises SyntaxError on the ESM import statements unless
# a package.json{"type":"module"} exists in an ancestor of the script path.
# The RPM does not install one; write it here so both the provision scripts
# and the main server (dist/main.js) resolve as ESM.
PKG_JSON_MARKER=/usr/lib64/bastion-core/package.json
if [[ ! -f "$PKG_JSON_MARKER" ]]; then
    printf '{"type":"module"}\n' > "$PKG_JSON_MARKER"
    log "Wrote $PKG_JSON_MARKER (ESM marker for NodeNext dist)"
fi
node "$PROVISION_JS" 2>&1 | tee /dev/ttyS0
log "Service-plane CA provisioned"
mark "service-ca-done"

# bastion-qemu.service ReadWritePaths requires /var/lib/bastion/qemu at exec time.
install -d -m 0750 /var/lib/bastion/qemu
chown bastion-qemu:bastion-qemu /var/lib/bastion/qemu 2>/dev/null || true

# bastion-qemu Go binary references ca.pem; service-ca-bootstrap creates ca.crt.
ln -sf ca.crt /var/lib/bastion/service-ca/ca.pem

# ── Read generated SAI ───────────────────────────────────────────────────────
BOOTSTRAP_ENV=/var/lib/bastion/install/bootstrap.env
if [[ ! -r "$BOOTSTRAP_ENV" ]]; then
    log "ERROR: $BOOTSTRAP_ENV not written by package-init"
    exit 1
fi
# shellcheck source=/dev/null
source "$BOOTSTRAP_ENV"

SAI_CALLSIGN="${BASTION_SAI_CALLSIGN:-UNKNOWN}"
log "SAI callsign: $SAI_CALLSIGN"
printf '%s\n' "$SAI_CALLSIGN" > "${SENTINEL_DIR}/core-id"
chmod 0644 "${SENTINEL_DIR}/core-id"
mark "sai-stamped"

# ── Emit release snapshot ────────────────────────────────────────────────────
if [[ -r /etc/bastion-core-release ]]; then
    sed 's/^/  /' /etc/bastion-core-release
else
    log "WARN: /etc/bastion-core-release missing (RPM %post regression)"
fi

log "Done"
printf 'FEDBUILD_READY\n'
serial "FEDBUILD_READY"
