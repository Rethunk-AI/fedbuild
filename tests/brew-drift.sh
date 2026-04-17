#!/usr/bin/env bash
# tests/brew-drift.sh — compare two brew-versions.txt snapshots, report drift.
#
# Usage:
#   bash tests/brew-drift.sh OLD NEW
#
# Inputs are files in `brew list --versions` format: "formula version..." per
# line. Produced by firstboot.sh and dumped to
# /var/lib/bastion-vm-firstboot/brew-versions.txt inside the VM; retrieve via
# scp or captured from a running VM before running this script.
#
# Output categories:
#   + added    — formula present in NEW, absent in OLD
#   - removed  — formula present in OLD, absent in NEW
#   ~ bumped   — same formula, different version (old → new)
#
# Exit status: always 0. Drift is informational; CVE scan + smoke tests gate
# promotion. Intended for release-notes generation + forensic comparison.
set -euo pipefail

OLD="${1:-}"
NEW="${2:-}"

if [[ -z "$OLD" || -z "$NEW" ]]; then
    echo "Usage: $0 OLD NEW" >&2
    echo "  OLD, NEW: paths to brew-versions.txt files" >&2
    exit 2
fi

[[ -r "$OLD" ]] || { echo "ERROR: $OLD not readable" >&2; exit 1; }
[[ -r "$NEW" ]] || { echo "ERROR: $NEW not readable" >&2; exit 1; }

# Pull "formula -> first version token" into associative arrays. brew reports
# multiple versions when keg-only installs pile up ("foo 1.2 1.3"); we take
# the first which is the active one.
declare -A old_ver new_ver
while read -r formula version _; do
    [[ -z "$formula" ]] && continue
    old_ver["$formula"]="$version"
done < "$OLD"

while read -r formula version _; do
    [[ -z "$formula" ]] && continue
    new_ver["$formula"]="$version"
done < "$NEW"

added=(); removed=(); bumped=()

for f in "${!new_ver[@]}"; do
    if [[ -z "${old_ver[$f]:-}" ]]; then
        added+=("$f ${new_ver[$f]}")
    elif [[ "${old_ver[$f]}" != "${new_ver[$f]}" ]]; then
        bumped+=("$f ${old_ver[$f]} → ${new_ver[$f]}")
    fi
done

for f in "${!old_ver[@]}"; do
    if [[ -z "${new_ver[$f]:-}" ]]; then
        removed+=("$f ${old_ver[$f]}")
    fi
done

# Sort each group for stable output. mapfile -t splits on newlines only,
# avoiding the global IFS mutation that word-splitting command substitution
# would need.
mapfile -t added_sorted < <(printf '%s\n' "${added[@]:-}" | LC_ALL=C sort)
mapfile -t removed_sorted < <(printf '%s\n' "${removed[@]:-}" | LC_ALL=C sort)
mapfile -t bumped_sorted < <(printf '%s\n' "${bumped[@]:-}" | LC_ALL=C sort)

echo "# brew drift"
echo "# OLD: $OLD"
echo "# NEW: $NEW"
echo "# added=${#added[@]} removed=${#removed[@]} bumped=${#bumped[@]}"
echo

if (( ${#added[@]} > 0 )); then
    echo "## Added (${#added[@]})"
    for line in "${added_sorted[@]}"; do
        [[ -n "$line" ]] && echo "+ $line"
    done
    echo
fi

if (( ${#removed[@]} > 0 )); then
    echo "## Removed (${#removed[@]})"
    for line in "${removed_sorted[@]}"; do
        [[ -n "$line" ]] && echo "- $line"
    done
    echo
fi

if (( ${#bumped[@]} > 0 )); then
    echo "## Bumped (${#bumped[@]})"
    for line in "${bumped_sorted[@]}"; do
        [[ -n "$line" ]] && echo "~ $line"
    done
    echo
fi

if (( ${#added[@]} + ${#removed[@]} + ${#bumped[@]} == 0 )); then
    echo "No drift."
fi
