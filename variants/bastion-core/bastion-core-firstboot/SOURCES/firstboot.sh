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

# Sidecar service units declare ReadWritePaths=/var/log/bastion; systemd
# namespace setup fails (226/NAMESPACE) if the directory doesn't exist.
install -d -m 0755 /var/log/bastion
chown root:bastion /var/log/bastion
chmod 0775 /var/log/bastion

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

# Grant bastion user ownership of service-ca (created as root by provision).
# Directories: 755 so bastion group members (non-bastion service accounts
# carrying SupplementaryGroups=bastion) can traverse and reach their leaf certs.
# Files: 640 (rw-r-----) — read-service-ca.ts enforces exactly 0600 or 0640;
# 0644 is rejected with "invalid-mode". bastion group read (r) lets service
# accounts with SupplementaryGroups=bastion read ca.crt, client.crt, leaf certs.
chown -R bastion:bastion /var/lib/bastion/service-ca
find /var/lib/bastion/service-ca -type d -exec chmod 755 {} +
find /var/lib/bastion/service-ca -type f \
    \( -name '*.crt' -o -name '*.key' -o -name '*.pem' \) \
    -exec chmod 640 {} + 2>/dev/null || true

# bastion-qemu.service ReadWritePaths requires /var/lib/bastion/qemu at exec time.
install -d -m 0750 /var/lib/bastion/qemu
chown bastion-qemu:bastion-qemu /var/lib/bastion/qemu 2>/dev/null || true

# bastion-qemu Go binary references ca.pem; service-ca-bootstrap creates ca.crt.
ln -sf ca.crt /var/lib/bastion/service-ca/ca.pem

# ── Generate at-rest encryption key for credential-keystore ─────────────────
install -d -m 0755 /etc/bastion
AT_REST_KEY=$(openssl rand -hex 32)
printf 'BASTION_HOST_CREDENTIAL_AT_REST_KEY=%s\n' "$AT_REST_KEY" \
    >> /etc/bastion/bastion.env
# Opt out of bastion-pki-trust gRPC health so the session gate uses the
# permissive no-origins path instead of criticalTrustHealthSnapshot().
# bastion-pki-trust only supports -uds; the mTLS dial fails and the cache
# stays empty, which would cause every session to see no_active_manifest.
printf 'BASTION_TRUST_HEALTH_FROM_GRPC=false\n' >> /etc/bastion/bastion.env
chmod 0640 /etc/bastion/bastion.env
chown root:bastion /etc/bastion/bastion.env
log "Generated BASTION_HOST_CREDENTIAL_AT_REST_KEY; set BASTION_TRUST_HEALTH_FROM_GRPC=false"

# ── Fix bastion-credential-keystore.service (RPM bug: wrong TLS flag names) ──
# The packaged ExecStart uses -cert/-key (at-rest key name) instead of
# -tls-cert/-tls-key, causing the binary to print usage and exit 2.
# Also overrides -storage to a bastion-owned subdirectory — the default
# /var/lib/bastion/host-credentials.enc.jsonl cannot be created by the bastion
# user because /var/lib/bastion is root:root 755.
SERVICE_CA=/var/lib/bastion/service-ca
KEYSTORE_STORAGE_DIR=/var/lib/bastion/credential-keystore
install -d -m 0750 "$KEYSTORE_STORAGE_DIR"
chown bastion:bastion "$KEYSTORE_STORAGE_DIR"
DROPIN_DIR=/etc/systemd/system/bastion-credential-keystore.service.d
install -d -m 0755 "$DROPIN_DIR"
cat > "$DROPIN_DIR/10-fix-flags.conf" <<DROPIN
[Service]
ExecStart=
ExecStart=/usr/bin/bastion-credential-keystore \
  -sock=/run/bastion/credential-keystore.sock \
  -storage=${KEYSTORE_STORAGE_DIR}/host-credentials.enc.jsonl \
  -tls-cert=${SERVICE_CA}/issued/bastion-credential-keystore/cert.pem \
  -tls-key=${SERVICE_CA}/issued/bastion-credential-keystore/key.pem \
  -tls-ca=${SERVICE_CA}/ca.crt
EnvironmentFile=/etc/bastion/bastion.env
DROPIN
systemctl daemon-reload

# ── Fix bastion-qemu ReadWritePaths ──────────────────────────────────────────
# bastion-qemu creates/removes /run/bastion/qemu.sock but the packaged unit
# only lists ReadWritePaths=/var/lib/bastion/qemu ... not /run/bastion.
# With ProtectSystem=strict the sock dir is read-only → ENOENT/EROFS on bind.
install -d -m 0755 /etc/systemd/system/bastion-qemu.service.d
printf '[Service]\nReadWritePaths=/run/bastion\n' \
    > /etc/systemd/system/bastion-qemu.service.d/30-run-bastion.conf

# Pre-create images directory so bastion-qemu can read staged qcow2s
# (bastion-edge.qcow2 → TheatreManager VMs, staged post-boot by operator).
# Mode 0775 + bastion-operator in bastion-qemu group allows the operator to
# scp images directly without sudo (make stage-tm-image target).
install -d -m 0775 /var/lib/bastion/qemu/images
chown bastion-qemu:bastion-qemu /var/lib/bastion/qemu/images 2>/dev/null || true
usermod -aG bastion-qemu bastion-operator 2>/dev/null || true

systemctl daemon-reload

# ── Create sidecar state and config directories ──────────────────────────────
# Services with ReadWritePaths or ReadOnlyPaths pointing at non-existent paths
# fail systemd namespace setup with 226/NAMESPACE before their ExecStart runs.

# bastion-ironlaw-loader
#   ReadWritePaths=/var/lib/bastion/ironlaw-loader
#   ReadOnlyPaths=/etc/bastion/ironlaw-loader
install -d -m 0750 /var/lib/bastion/ironlaw-loader
chown bastion-ironlaw-loader:bastion-ironlaw-loader /var/lib/bastion/ironlaw-loader 2>/dev/null || true
install -d -m 0755 /etc/bastion/ironlaw-loader

# bastion-intent-ledger-replicator
#   ReadWritePaths=/var/lib/bastion/intent-ledger-replicator
#   ReadOnlyPaths=/etc/bastion/intent-ledger-replicator
install -d -m 0750 /var/lib/bastion/intent-ledger-replicator
chown bastion-intent-ledger-replicator:bastion-intent-ledger-replicator /var/lib/bastion/intent-ledger-replicator 2>/dev/null || true
install -d -m 0755 /etc/bastion/intent-ledger-replicator

log "Created sidecar state directories"

# ── Symlinks for Go sidecars expecting tls.crt / tls.key ────────────────────
# bastion-provision emits cert.pem / key.pem; adcon-engine and adcon-mirror Go
# binaries look for tls.crt / tls.key. Create relative symlinks to bridge.
for subj in bastion-adcon-engine bastion-adcon-mirror; do
    issued_dir=/var/lib/bastion/service-ca/issued/${subj}
    [[ -d "$issued_dir" ]] || { log "WARN: $issued_dir missing — adcon provision may have failed"; continue; }
    ln -sf cert.pem "${issued_dir}/tls.crt"
    ln -sf key.pem  "${issued_dir}/tls.key"
done
log "Created tls.crt/tls.key symlinks for adcon sidecars"

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
