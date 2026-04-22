#!/usr/bin/env bash
# Build all Bastion RPMs needed for the bastion-core fedbuild variant and copy
# them into variants/bastion-core/extra-rpms/.
#
# Usage:
#   ./scripts/build-extra-rpms.sh [--version X.Y.Z] [--parallel]
#
# Run from fedbuild/ root or the variant directory. The Bastion meta-repo
# sibling clones must be present under the parent directory.
set -euo pipefail

VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META_ROOT="$(cd "${VARIANT_DIR}/../../.." && pwd)"   # Bastion meta-repo root
EXTRA_RPMS="${VARIANT_DIR}/extra-rpms"

VERSION="${BASTION_RPM_VERSION:-0.0.0}"
PARALLEL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --parallel)  PARALLEL=true; shift ;;
    *)           echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Sidecar Go repos ─────────────────────────────────────────────────────────
GO_SIDECARS=(
  bastion-credential-keystore
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

build_sidecar() {
  local name="$1"
  local repo_path="${META_ROOT}/${name}"
  if [[ ! -d "$repo_path/packaging/rpm" ]]; then
    echo "SKIP: ${name} — no packaging/rpm/ dir" >&2
    return 0
  fi
  echo "Building ${name} …"
  rm -f "${EXTRA_RPMS}/${name}-"*.rpm
  GOWORK=off \
  BASTION_RPM_VERSION="${VERSION}" \
  BASTION_RPM_OUT_DIR="${EXTRA_RPMS}" \
    "${repo_path}/packaging/rpm/build-rpm.sh"
}

# ── bastion-core (Node.js, different build flow) ─────────────────────────────
build_bastion_core() {
  local repo_path="${META_ROOT}/bastion-core"
  echo "Building bastion-core …"
  rm -f "${EXTRA_RPMS}/bastion-core-"*.rpm
  (
    cd "$repo_path"
    RPM_VERSION="${VERSION}" \
    BASTION_RPM_OUT_DIR="${EXTRA_RPMS}" \
      packaging/rpm/build-rpm.sh
    # build-rpm.sh does not honor BASTION_RPM_OUT_DIR; always copy from rpmbuild output
    find packaging/rpm/rpmbuild/RPMS -name 'bastion-core-*.rpm' \
      -exec cp -v {} "${EXTRA_RPMS}/" \;
  )
}

mkdir -p "${EXTRA_RPMS}"

if [[ "$PARALLEL" == true ]]; then
  pids=()
  for svc in "${GO_SIDECARS[@]}"; do
    build_sidecar "$svc" &
    pids+=($!)
  done
  build_bastion_core &
  pids+=($!)
  for pid in "${pids[@]}"; do wait "$pid"; done
else
  for svc in "${GO_SIDECARS[@]}"; do
    build_sidecar "$svc"
  done
  build_bastion_core
fi

echo ""
echo "Built RPMs in ${EXTRA_RPMS}:"
ls "${EXTRA_RPMS}"/*.rpm 2>/dev/null || echo "  (none — check build errors above)"
echo ""
echo "Next: make VARIANT=bastion-core image"
