#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${dir}/config.sh"

usage() {
    printf 'Usage: %s info|schema|import|indexes|check-import|run|check-test|drop [warehouses] [threads] [inflight] [duration_minutes]\n' "$0"
}
[[ $# -gt 0 ]] || { usage; exit 2; }
command_name="$1"; shift
warehouses="${1:-$TPCC_WAREHOUSES}"
threads="${2:-$TPCC_THREADS}"
inflight="${3:-$TPCC_MAX_INFLIGHT}"
duration="${4:-$TPCC_DURATION_MIN}"
for value in "$warehouses" "$threads" "$inflight" "$duration" "$TPCC_STATS_INTERVAL"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Expected positive integer: $value" >&2; exit 2; }
done

if [[ "$command_name" == info ]]; then
    printf 'source=%s\nendpoint=%s\ndatabase=%s\npath=%s\nwarehouses=%s\nthreads=%s\ninflight=%s\nduration_min=%s\ntx_mode=%s\n' \
        "$TPCC_SOURCE_COMMIT" "$TPCC_ENDPOINT" "$TPCC_DATABASE" "$TPCC_PATH" \
        "$warehouses" "$threads" "$inflight" "$duration" "$TPCC_TX_MODE"
    exit 0
fi
[[ -x "$TPCC_BIN" ]] || { echo "Build tpcc-ydb first: $dir/build.sh" >&2; exit 1; }
[[ "$TPCC_PATH" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "Unsafe TPCC_PATH" >&2; exit 2;
}
[[ -z "$TPCC_CA_FILE" || -f "$TPCC_CA_FILE" ]] || { echo "Missing CA: $TPCC_CA_FILE" >&2; exit 1; }

args=(--endpoint="$TPCC_ENDPOINT" --database="$TPCC_DATABASE" --path="$TPCC_PATH"
      --auth-scheme="$TPCC_AUTH_SCHEME" -w "$warehouses")
[[ -z "$TPCC_CA_FILE" ]] || args+=(--ca-file="$TPCC_CA_FILE")
[[ "$TPCC_TX_MODE" == serializable-rw || "$TPCC_TX_MODE" == snapshot-rw ]] || {
    echo "Invalid TPCC_TX_MODE: $TPCC_TX_MODE" >&2; exit 2;
}
if [[ "$TPCC_AUTH_SCHEME" == login ]]; then
    [[ -n "$TPCC_USER" && -n "${!TPCC_PASSWORD_ENV:-}" ]] || {
        echo "Login needs TPCC_USER and a value in $TPCC_PASSWORD_ENV" >&2; exit 1;
    }
    args+=(--user="$TPCC_USER" --password-env="$TPCC_PASSWORD_ENV")
elif [[ "$TPCC_AUTH_SCHEME" != anonymous ]]; then
    echo "Configure anonymous or login auth explicitly" >&2; exit 2
fi

case "$command_name" in
    schema)       exec "$TPCC_BIN" schema "${args[@]}" ;;
    import)       exec "$TPCC_BIN" import "${args[@]}" -t "$threads" ;;
    indexes)      exec "$TPCC_BIN" indexes "${args[@]}" ;;
    check-import) exec "$TPCC_BIN" check "${args[@]}" -t "$threads" --after-import ;;
    check-test)   exec "$TPCC_BIN" check "${args[@]}" -t "$threads" --after-test ;;
    drop)
        [[ "${TPCC_CONFIRM_DROP:-}" == YES ]] || { echo 'Set TPCC_CONFIRM_DROP=YES to drop the dedicated TPCC tables' >&2; exit 2; }
        exec "$TPCC_BIN" drop "${args[@]}" ;;
    run)
        mkdir -p "$TPCC_LOG_DIR"
        log="${TPCC_LOG_FILE:-$TPCC_LOG_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)-w${warehouses}-t${threads}-m${inflight}.log}"
        mkdir -p "$(dirname "$log")"
        run_args=(run "${args[@]}" --tx-mode="$TPCC_TX_MODE" --duration="$duration" -t "$threads"
                  --max-inflight="$inflight" --warmup="$TPCC_WARMUP_MIN"
                  --stats-interval="$TPCC_STATS_INTERVAL")
        [[ "$TPCC_NO_DELAYS" == true ]] && run_args+=(--no-delays)
        printf 'log=%s\n' "$log"
        "$TPCC_BIN" "${run_args[@]}" 2>&1 | tee "$log" | bash "$dir/metrics.sh"
        ;;
    *) usage >&2; exit 2 ;;
esac
