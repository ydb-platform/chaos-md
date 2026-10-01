#!/usr/bin/env bash

TPCC_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPCC_OUT_DIR="${TPCC_OUT_DIR:-${TPCC_MODULE_DIR}/../out/workload-portable-tpcc}"
TPCC_SOURCE_DIR="${TPCC_SOURCE_DIR:-${TPCC_OUT_DIR}/source}"
TPCC_REMOTE_HOST="${TPCC_REMOTE_HOST:-}"
TPCC_REMOTE_USER="${TPCC_REMOTE_USER:-${USER:-}}"
TPCC_REMOTE_DEST="${TPCC_REMOTE_DEST:-chaos-tests}"
TPCC_SSH_OPTS=(-o BatchMode=yes)
TPCC_ENDPOINT="${TPCC_ENDPOINT:-grpc://localhost:2135}"
TPCC_DATABASE="${TPCC_DATABASE:-/Root/database}"
TPCC_PATH="${TPCC_PATH:-portable-tpcc}"
TPCC_CA_FILE="${TPCC_CA_FILE:-}"
TPCC_AUTH_SCHEME="${TPCC_AUTH_SCHEME:-anonymous}"
TPCC_USER="${TPCC_USER:-}"
TPCC_PASSWORD_ENV="${TPCC_PASSWORD_ENV:-YDB_PASSWORD}"
TPCC_WAREHOUSES="${TPCC_WAREHOUSES:-3000}"
TPCC_THREADS="${TPCC_THREADS:-5}"
TPCC_TX_MODE="${TPCC_TX_MODE:-serializable-rw}"
TPCC_MAX_INFLIGHT="${TPCC_MAX_INFLIGHT:-256}"
TPCC_DURATION_MIN="${TPCC_DURATION_MIN:-120}"
TPCC_WARMUP_MIN="${TPCC_WARMUP_MIN:-0}"
TPCC_STATS_INTERVAL="${TPCC_STATS_INTERVAL:-5}"
TPCC_NO_DELAYS="${TPCC_NO_DELAYS:-false}"
TPCC_VM_WRITE_URL="${TPCC_VM_WRITE_URL:-http://localhost:8428/write}"
TPCC_GRAFANA_URL="${TPCC_GRAFANA_URL:-}"
TPCC_GRAFANA_TOKEN="${TPCC_GRAFANA_TOKEN:-}"
TPCC_APPLICATION="${TPCC_APPLICATION:-portable-tpcc}"
TPCC_SOURCE_URL="https://github.com/zinal/portable-tpcc.git"
TPCC_SOURCE_COMMIT="fbf3e642d21b9e18e3a80f86613f025bcf906b8a"
TPCC_BIN="${TPCC_BIN:-${TPCC_SOURCE_DIR}/tpcc/app/ydb/tpcc-ydb}"
TPCC_LOG_DIR="${TPCC_LOG_DIR:-${TPCC_OUT_DIR}/logs}"

_tpcc_local="$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
[[ -f "${_tpcc_local}" ]] && source "${_tpcc_local}"
unset _tpcc_local

[[ "$TPCC_REMOTE_DEST" =~ ^[A-Za-z0-9_-]+$ && "$TPCC_APPLICATION" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "TPCC_REMOTE_DEST and TPCC_APPLICATION must contain only letters, digits, underscores or hyphens" >&2
    return 2
}
