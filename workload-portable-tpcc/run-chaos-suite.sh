#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$dir/.." && pwd)"
source "$dir/config.sh"
export GRAFANA_DASHBOARD_UID="${GRAFANA_DASHBOARD_UID:-portable-tpcc-chaos}"
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --plan ) ]] || { echo "Usage: $0 [--plan]" >&2; exit 2; }
plan_only=false
[[ "${1:-}" == --plan ]] && plan_only=true
[[ -f "$root/env.sh" ]] || { echo 'Configure env.sh first' >&2; exit 2; }
source "$root/env.sh"

for name in CPU_NODE CPU_DC DELAY_NODE DELAY_DC LOSS_NODE LOSS_DC BW_NODE BW_DC; do
    variable="SUITE_$name"
    [[ -n "${!variable:-}" ]] || { echo "Set $variable from live calibration" >&2; exit 2; }
done

baseline_sec="${SUITE_BASELINE_SEC:-60}"
impact_sec="${SUITE_IMPACT_SEC:-120}"
recovery_sec="${SUITE_RECOVERY_SEC:-90}"
for seconds in "$baseline_sec" "$impact_sec" "$recovery_sec"; do
    [[ "$seconds" =~ ^[1-9][0-9]*$ && "$seconds" -ge 60 ]] || {
        echo 'Each phase must last at least 60 seconds' >&2; exit 2;
    }
done

start_at="${SUITE_START_AT:-01-node}"
started=false

log_dir="$TPCC_OUT_DIR/suite-$(date -u +%Y%m%dT%H%M%SZ)"
result="$log_dir/results.tsv"
if [[ "$plan_only" == false ]]; then
    mkdir -p "$log_dir"
    printf 'case\tapplication\tbaseline_start\timpact_start\timpact_end\trecovery_end\tbaseline_rps\timpact_rps\trecovery_rps\trps_drop_pct\tbaseline_failed\timpact_failed\trecovery_failed\tbaseline_p90_ms\timpact_p90_ms\trecovery_p90_ms\tcommand\n' > "$result"
fi

measure() {
    ssh "${TPCC_SSH_OPTS[@]}" "${TPCC_REMOTE_USER}@${TPCC_REMOTE_HOST}" \
        "bash \$HOME/${TPCC_REMOTE_DEST}/workload-portable-tpcc/measure-window.sh $1 $2"
}

run_case() {
    local id="$1" script="$2" scope="$3" teardown="$4"
    shift 4
    if [[ "${started}" == false ]]; then
        if [[ "${id}" != "${start_at}" ]]; then
            printf 'Skipping %s before SUITE_START_AT=%s\n' "${id}" "${start_at}"
            return 0
        fi
        started=true
    fi
    local baseline_start baseline_end impact_start impact_end recovery_start recovery_end
    local baseline impact recovery baseline_rps impact_rps drop
    local command=(bash "$root/$script" "$scope" -t "$impact_sec" "$@")
    printf 'Running %s: ' "$id"
    printf '%q ' "${command[@]}"
    printf '\n'
    [[ "$plan_only" == true ]] && return 0

    baseline_start="$(date -u +%s)"
    sleep "$baseline_sec"
    baseline_end="$(date -u +%s)"
    baseline="$(measure "$((baseline_start + 10))" "$((baseline_end - 10))")"

    impact_start="$(date -u +%s)"
    if ! "${command[@]}" > "$log_dir/$id.run.log" 2>&1; then
        printf '%s failed; see %s\n' "$id" "$log_dir/$id.run.log" >&2
        if [[ "$script" == 01-cpu-load.sh ]]; then
            bash "$root/$script" "$scope" -D > "$log_dir/$id.teardown.log" 2>&1 || true
        fi
        return 1
    fi
    impact_end="$(date -u +%s)"
    if [[ "$teardown" == yes ]]; then
        bash "$root/$script" "$scope" -D > "$log_dir/$id.teardown.log" 2>&1
    fi

    recovery_start="$(date -u +%s)"
    sleep "$recovery_sec"
    recovery_end="$(date -u +%s)"
    impact="$(measure "$((impact_start + 20))" "$((impact_end - 20))")"
    recovery="$(measure "$((recovery_start + 10))" "$((recovery_end - 10))")"
    baseline_rps="$(printf '%s' "$baseline" | cut -f2)"
    impact_rps="$(printf '%s' "$impact" | cut -f2)"
    drop="$(awk -v b="$baseline_rps" -v i="$impact_rps" 'BEGIN { if (b <= 0) exit 1; printf "%.2f", 100 * (b - i) / b }')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$TPCC_APPLICATION" "$baseline_start" "$impact_start" "$impact_end" "$recovery_end" \
        "$baseline_rps" "$impact_rps" "$(printf '%s' "$recovery" | cut -f2)" "$drop" \
        "$(printf '%s' "$baseline" | cut -f5)" "$(printf '%s' "$impact" | cut -f5)" \
        "$(printf '%s' "$recovery" | cut -f5)" \
        "$(printf '%s' "$baseline" | cut -f6)" "$(printf '%s' "$impact" | cut -f6)" \
        "$(printf '%s' "$recovery" | cut -f6)" "$(printf '%q ' "${command[@]}")" >> "$result"
    printf '%s: baseline=%s impact=%s drop=%s%% recovery=%s RPS\n' \
        "$id" "$baseline_rps" "$impact_rps" "$drop" "$(printf '%s' "$recovery" | cut -f2)"
}

run_case 01-node 01-cpu-load.sh -1 yes -p "$SUITE_CPU_NODE" -T "$((impact_sec + 30))"
run_case 01-dc 01-cpu-load.sh -4 yes -p "$SUITE_CPU_DC" -T "$((impact_sec + 30))"
run_case 03-node 03-disk-fail.sh -1 no -d "${SUITE_DISK_DEVICE:?Set SUITE_DISK_DEVICE to the dedicated data disk}"
run_case 04-node 04-net-delay.sh -1 no -d "$SUITE_DELAY_NODE"
run_case 04-dc 04-net-delay.sh -4 no -d "$SUITE_DELAY_DC"
run_case 05-node 05-net-loss.sh -1 no -l "$SUITE_LOSS_NODE"
run_case 05-dc 05-net-loss.sh -4 no -l "$SUITE_LOSS_DC"
run_case 06-node 06-net-drop.sh -1 no
run_case 07-node 07-net-bw.sh -1 no -r "$SUITE_BW_NODE"
run_case 07-dc 07-net-bw.sh -4 no -r "$SUITE_BW_DC"
run_case 08-node 08-proc-freeze.sh -1 no
run_case 09-node 09-proc-kill.sh -1 no -r
# The suite excludes RAM pressure and rolling upgrades.
run_case 11-dc 11-dc-drop.sh -4 no
run_case 12-node 12-server-stop.sh -1 yes

[[ "$plan_only" == true ]] || printf 'Results: %s\n' "$result"
