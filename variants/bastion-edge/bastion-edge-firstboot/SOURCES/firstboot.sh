#!/bin/bash
# bastion-edge-firstboot — runs once on first boot as root.
#
# Purpose: stamp the edge VM with a stable `edge-id` that identifies this host
# to bastion-theatre-manager and the upstream Bastion control plane. Sourced
# from cloud-init NoCloud metadata (cidata) when the VM is booted with one
# attached; falls back to /etc/machine-id (persistent across reboots, unique
# per VM clone) when no cidata datasource is present (e.g. smoke-test runs).
#
# This firstboot unit is intentionally tiny. It does NOT install Homebrew,
# npm packages, or dev tooling. Compare with variants/devbox/.../firstboot.sh
# for the agent-sandbox variant that does all of that.
set -euo pipefail

SENTINEL_DIR=/var/lib/bastion-edge
EDGE_ID_FILE="${SENTINEL_DIR}/edge-id"
log()  { echo "[firstboot] $(date -Iseconds) $*"; }
mark() { printf 'FEDBUILD_MARK: %s\n' "$*"; }

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log "FAILED (exit $rc) — writing failure sentinel"
        touch "${SENTINEL_DIR}/failed" 2>/dev/null || true
        # Terminal marker — smoke greps this to fail fast instead of timing out.
        printf 'FEDBUILD_FAILED %d\n' "$rc"
    fi
}
trap on_exit EXIT

log "Starting"
mark "firstboot-start"

install -d -m 0755 "$SENTINEL_DIR"

# ── Derive edge-id ───────────────────────────────────────────────────────────
# Order of preference (first hit wins):
#   1. cloud-init NoCloud meta-data (field deploy with cidata CD)
#   2. /etc/machine-id (smoke test, bare KVM boot, or cidata-less images)
#
# cloud-init writes the parsed datasource to /run/cloud-init/instance-data.json
# (canonical; JSON) and the original metadata payload to
# /var/lib/cloud/data/instance-data.json + /var/lib/cloud/instances/<id>/.
# We read the simple key instead of taking a hard dep on jq.
edge_id=""

CIDATA_PATHS=(
    /var/lib/cloud/data/instance-id
    /var/lib/cloud/seed/nocloud/meta-data
    /var/lib/cloud/data/meta-data
)
for p in "${CIDATA_PATHS[@]}"; do
    if [[ -r "$p" ]]; then
        case "$p" in
            */instance-id)
                edge_id=$(tr -d '[:space:]' < "$p" || true)
                ;;
            *)
                # YAML: `instance-id: <value>` (quoted or unquoted)
                edge_id=$(awk -F: '
                    /^instance-id[[:space:]]*:/ {
                        sub(/^[^:]*:[[:space:]]*/, "", $0);
                        gsub(/^["'\'']|["'\'']$/, "", $0);
                        gsub(/[[:space:]]+$/, "", $0);
                        print; exit
                    }' "$p" || true)
                ;;
        esac
        if [[ -n "${edge_id:-}" ]]; then
            log "edge-id from $p: $edge_id"
            break
        fi
    fi
done

if [[ -z "${edge_id:-}" ]]; then
    if [[ -r /etc/machine-id ]]; then
        edge_id=$(tr -d '[:space:]' < /etc/machine-id)
        log "edge-id from /etc/machine-id: $edge_id"
    else
        log "ERROR: no cidata and no /etc/machine-id — cannot derive edge-id"
        exit 1
    fi
fi

printf '%s\n' "$edge_id" > "$EDGE_ID_FILE"
chmod 0644 "$EDGE_ID_FILE"
log "Wrote $EDGE_ID_FILE"
mark "edge-id-stamped"

# ── Emit release snapshot ────────────────────────────────────────────────────
log "Release"
if [[ -r /etc/bastion-edge-release ]]; then
    sed 's/^/  /' /etc/bastion-edge-release
else
    log "WARN: /etc/bastion-edge-release missing (RPM %post regression)"
fi

log "Done"
# Terminal success marker — emit LAST so smoke's serial-grep sees edge-id first.
printf 'FEDBUILD_READY\n'
