#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${dir}/config.sh"

warehouses="${TPCC_WAREHOUSES}"
threads="${TPCC_THREADS}"
duration="${TPCC_DURATION_MIN}"
pause="${TPCC_STEP_PAUSE_SEC:-30}"
steps=("$@")
if [[ $# -eq 0 ]]; then steps=(150 180 210 240); fi
for value in "$warehouses" "$threads" "$duration" "${steps[@]}"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Expected positive integer: $value" >&2; exit 2; }
done
[[ "$pause" =~ ^[0-9]+$ ]] || { echo "Invalid pause: $pause" >&2; exit 2; }

grafana_time_ms() {
    date +%s%3N
}

grafana_region_open() {
    local tag="$1" text="$2" time_ms response
    [[ -n "${TPCC_GRAFANA_URL:-}" && -n "${TPCC_GRAFANA_TOKEN:-}" ]] || return 0
    time_ms="$(grafana_time_ms)"
    response="$(curl -sf --max-time 5 -XPOST "${TPCC_GRAFANA_URL}/api/annotations" \
        -H "Authorization: Bearer ${TPCC_GRAFANA_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "{\"time\":${time_ms},\"timeEnd\":${time_ms},\"tags\":[\"tpcc\",\"tpcc-step\",\"tpcc-staircase\",\"${tag}\"],\"text\":\"${text}\"}" 2>/dev/null)" || return 0
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"${response}"
}

grafana_region_close() {
    local annotation_id="$1"
    [[ -n "${annotation_id}" && -n "${TPCC_GRAFANA_URL:-}" && -n "${TPCC_GRAFANA_TOKEN:-}" ]] || return 0
    curl -sf --max-time 5 -XPATCH "${TPCC_GRAFANA_URL}/api/annotations/${annotation_id}" \
        -H "Authorization: Bearer ${TPCC_GRAFANA_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "{\"timeEnd\":$(grafana_time_ms)}" >/dev/null 2>&1 || true
}

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
result_dir="${TPCC_LOG_DIR}/staircase-${run_id}"
mkdir -p "$result_dir"
printf 'step\tinflight\tstart_utc\tend_utc\tlog\trps\tnew_order_rps\tnew_order_p90_ms\tfailed\tinvalid_latency\n' > "$result_dir/manifest.tsv"
step_list="$(IFS=,; echo "${steps[*]}")"
run_annotation=""
if ((${#steps[@]} > 1)); then
    run_annotation="$(grafana_region_open "run-${run_id}" "TPC-C staircase: inflight=${step_list}, no_delays=${TPCC_NO_DELAYS}")"
fi
trap 'grafana_region_close "${run_annotation:-}"' EXIT

for index in "${!steps[@]}"; do
    inflight="${steps[$index]}"
    step=$((index + 1))
    log="$result_dir/step-${step}-inflight-${inflight}.log"
    start="$(date -u +%FT%TZ)"
    annotation_text="TPC-C staircase: warehouses=${warehouses}, threads=${threads}, inflight=${inflight}, step=${step}"
    if ((${#steps[@]} == 1)); then
        annotation_text="TPC-C run: warehouses=${warehouses}, threads=${threads}, inflight=${inflight}, no_delays=${TPCC_NO_DELAYS}, warmup and measurement"
    fi
    step_annotation="$(grafana_region_open "inflight-${inflight}" "$annotation_text")"
    printf 'Step %s/%s: inflight=%s, warehouses=%s, threads=%s, duration=%s min\n' \
        "$step" "${#steps[@]}" "$inflight" "$warehouses" "$threads" "$duration"
    TPCC_LOG_FILE="$log" bash "$dir/tpcc.sh" run "$warehouses" "$threads" "$inflight" "$duration" \
        > "$result_dir/step-${step}.console"
    end="$(date -u +%FT%TZ)"
    grafana_region_close "${step_annotation}"
    summary="$(bash "$dir/analyze-log.sh" "$log")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$step" "$inflight" "$start" "$end" "$log" "$summary" >> "$result_dir/manifest.tsv"
    printf 'rps, new_order_rps, new_order_p90_ms, failed, invalid_latency: %s\n' "$summary"
    if ((index + 1 < ${#steps[@]})); then sleep "$pause"; fi
done
printf 'Results: %s\n' "$result_dir"
