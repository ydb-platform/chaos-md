#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$dir/.." && pwd)"
source "$dir/config.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 cpu|delay|loss|bandwidth node|dc VALUE" >&2; exit 2; }
kind="$1"
scope="$2"
value="$3"
[[ -f "$root/env.sh" ]] || { echo 'Configure env.sh first' >&2; exit 2; }
case "$kind" in
    cpu) script=01-cpu-load.sh; flag=-p ;;
    delay) script=04-net-delay.sh; flag=-d ;;
    loss) script=05-net-loss.sh; flag=-l ;;
    bandwidth) script=07-net-bw.sh; flag=-r ;;
    *) echo "Unknown chaos kind: $kind" >&2; exit 2 ;;
esac
case "$scope" in
    node) scope_flag=-1 ;;
    dc) scope_flag=-4 ;;
    *) echo "Unknown scope: $scope" >&2; exit 2 ;;
esac
[[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid value: $value" >&2; exit 2; }
if [[ "$kind" == cpu || "$kind" == bandwidth ]]; then
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Integer value required: $value" >&2; exit 2; }
fi
if [[ "$kind" == cpu || "$kind" == loss ]]; then
    awk -v v="$value" 'BEGIN { exit !(v > 0 && v <= 100) }' || { echo "Percent must be in (0,100]" >&2; exit 2; }
fi

baseline_sec="${TPCC_BASELINE_SEC:-90}"
impact_sec="${TPCC_IMPACT_SEC:-120}"
recovery_sec="${TPCC_RECOVERY_SEC:-90}"
p90_mode="${TPCC_CALIBRATION_P90_MODE:-window}"
[[ "$p90_mode" == window || "$p90_mode" == phase ]] || {
    echo "TPCC_CALIBRATION_P90_MODE must be window or phase" >&2; exit 2;
}
for seconds in "$baseline_sec" "$impact_sec" "$recovery_sec"; do
    [[ "$seconds" =~ ^[1-9][0-9]*$ && "$seconds" -ge 60 ]] || {
        echo "Each phase must last at least 60 seconds" >&2; exit 2;
    }
done

log_dir="${TPCC_CALIBRATION_LOG_DIR:-$TPCC_OUT_DIR/calibration}"
mkdir -p "$log_dir"
id="$(date -u +%Y%m%dT%H%M%SZ)-$kind-$scope-$value"
run_log="$log_dir/$id.run.log"
teardown_log="$log_dir/$id.teardown.log"
active=false
cleanup() {
    if [[ "$active" == true ]]; then
        bash "$root/$script" "$scope_flag" -D >> "$teardown_log" 2>&1 || true
    fi
}
trap cleanup EXIT

measure() {
    ssh "${TPCC_SSH_OPTS[@]}" "${TPCC_REMOTE_USER}@${TPCC_REMOTE_HOST}" \
        "TPCC_APPLICATION=${TPCC_APPLICATION} bash \$HOME/${TPCC_REMOTE_DEST}/workload-portable-tpcc/measure-window.sh $1 $2"
}

baseline_start="$(date -u +%s)"
sleep "$baseline_sec"
baseline_end="$(date -u +%s)"
baseline="$(measure "$((baseline_start + 10))" "$((baseline_end - 10))")"
baseline_p90="$(printf '%s' "$baseline" | cut -f6)"
if [[ "$p90_mode" == window ]]; then
    awk -v p90="$baseline_p90" 'BEGIN { exit !(p90 <= 5000) }' || {
        printf 'Baseline NewOrder p90 %.2fms exceeds 5000ms; impact skipped\n' "$baseline_p90" >&2
        exit 3
    }
fi

impact_start="$(date -u +%s)"
active=true
extra=()
[[ "$kind" == cpu ]] && extra=(-T "$((impact_sec + 30))")
bash "$root/$script" "$scope_flag" "$flag" "$value" -t "$impact_sec" "${extra[@]}" \
    > "$run_log" 2>&1
impact_end="$(date -u +%s)"
bash "$root/$script" "$scope_flag" -D > "$teardown_log" 2>&1
active=false
if ! bash "$root/$script" "$scope_flag" -C >> "$teardown_log" 2>&1; then
    echo "Read-only post-teardown check failed; stop before recovery or next candidate" >&2
    exit 5
fi

recovery_start="$(date -u +%s)"
sleep "$recovery_sec"
recovery_end="$(date -u +%s)"

impact="$(measure "$((impact_start + 20))" "$((impact_end - 20))")"
recovery="$(measure "$((recovery_start + 10))" "$((recovery_end - 10))")"
baseline_rps="$(printf '%s' "$baseline" | cut -f2)"
impact_rps="$(printf '%s' "$impact" | cut -f2)"
drop="$(awk -v b="$baseline_rps" -v i="$impact_rps" 'BEGIN { if (b <= 0) exit 1; printf "%.2f", 100 * (b - i) / b }')"

result="$log_dir/results.tsv"
if [[ ! -f "$result" ]]; then
    printf 'id\tapplication\tkind\tscope\tvalue\tbaseline_start\timpact_start\timpact_end\trecovery_start\trecovery_end\tbaseline_rps\timpact_rps\trecovery_rps\trps_drop_pct\tbaseline_failed\timpact_failed\trecovery_failed\tbaseline_phase_p90_mean_ms\timpact_phase_p90_mean_ms\trecovery_phase_p90_mean_ms\trecovered\trun_log\tteardown_log\n' > "$result"
fi
recovery_rps="$(printf '%s' "$recovery" | cut -f2)"
baseline_rps="$(printf '%s' "$baseline" | cut -f2)"
recovery_p90="$(printf '%s' "$recovery" | cut -f6)"
recovered=false
if awk -v b="$baseline_rps" -v r="$recovery_rps" -v rf="$(printf '%s' "$recovery" | cut -f5)" \
    'BEGIN { d=(r-b)/b; if (d<0) d=-d; exit !(b>0 && d<=0.05 && rf==0) }'; then
    recovered=true
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$TPCC_APPLICATION" "$kind" "$scope" "$value" "$baseline_start" "$impact_start" "$impact_end" "$recovery_start" "$recovery_end" \
    "$(printf '%s' "$baseline" | cut -f2)" "$(printf '%s' "$impact" | cut -f2)" \
    "$(printf '%s' "$recovery" | cut -f2)" "$drop" \
    "$(printf '%s' "$baseline" | cut -f5)" "$(printf '%s' "$impact" | cut -f5)" \
    "$(printf '%s' "$recovery" | cut -f5)" \
    "$baseline_p90" "$(printf '%s' "$impact" | cut -f6)" \
    "$recovery_p90" "$recovered" "$run_log" "$teardown_log" >> "$result"

annotation_id="$(ssh "${TPCC_SSH_OPTS[@]}" "${TPCC_REMOTE_USER}@${TPCC_REMOTE_HOST}" \
    "bash -s -- ${impact_start} ${impact_end} ${id} ${kind} ${scope} ${value} ${TPCC_APPLICATION} ${TPCC_REMOTE_DEST}" <<'REMOTE'
set -euo pipefail
start_s="$1"
end_s="$2"
id="$3"
kind="$4"
scope="$5"
value="$6"
application="$7"
remote_dest="$8"
cd "$HOME/$remote_dest/workload-portable-tpcc"
source ./config.sh
payload="$(jq -nc --arg text "Chaos candidate ${id}; ${application}; ${kind} ${value}; scope=${scope}" \
    --argjson time "$((start_s * 1000))" --argjson timeEnd "$((end_s * 1000))" \
    '{dashboardUID:"portable-tpcc-chaos",time:$time,timeEnd:$timeEnd,tags:["tpcc","tpcc-step","chaos","chaos-calibration"],text:$text}')"
response="$(curl -sk --fail --max-time 15 -XPOST "${TPCC_GRAFANA_URL%/}/api/annotations" \
    -H "Authorization: Bearer ${TPCC_GRAFANA_TOKEN}" -H 'Content-Type: application/json' -d "$payload")"
printf '%s' "$response" | jq -er '.id'
REMOTE
)" || { echo "Grafana impact annotation failed for ${id}; stop before next candidate" >&2; exit 6; }
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$impact_start" "$impact_end" \
    "$(printf '%s' "$annotation_id" | tr -d '\r\n')" "$kind" "$scope" >> "$log_dir/annotations.tsv"
printf '%s: baseline=%s RPS impact=%s RPS drop=%s%% recovery=%s RPS\n' \
    "$id" "$baseline_rps" "$impact_rps" "$drop" "$(printf '%s' "$recovery" | cut -f2)"
[[ "$recovered" == true ]] || { echo "Recovery did not return within 5%; stop before next candidate" >&2; exit 4; }
