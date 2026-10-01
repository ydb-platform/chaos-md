#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${dir}/.." && pwd)"
source "${dir}/config.sh"
[[ "$TPCC_REMOTE_DEST" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Unsafe remote project directory' >&2; exit 2; }
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --dry-run ) ]] || { echo "Usage: $0 [--dry-run]" >&2; exit 2; }

files=(workload-portable-tpcc grafana/dashboards/chaos/portable-tpcc-chaos.json)
tar_args=(--exclude 'workload-portable-tpcc/source' --exclude 'workload-portable-tpcc/logs'
          --exclude 'workload-portable-tpcc/config.local.sh')
if [[ "${1:-}" == --dry-run ]]; then
    tar -C "$root" "${tar_args[@]}" -cf - "${files[@]}" | tar -tf -
    exit 0
fi

: "${TPCC_REMOTE_HOST:?Set TPCC_REMOTE_HOST in config.local.sh}"
mkdir -p "$TPCC_OUT_DIR"

remote_command="mkdir -p \"\$HOME/${TPCC_REMOTE_DEST}\" && tar -C \"\$HOME/${TPCC_REMOTE_DEST}\" -xf -"
tar -C "$root" "${tar_args[@]}" -cf - "${files[@]}" | \
    ssh "${TPCC_SSH_OPTS[@]}" "${TPCC_REMOTE_USER}@${TPCC_REMOTE_HOST}" "$remote_command"
