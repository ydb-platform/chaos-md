#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${dir}/config.sh"
last_ts=0
last_fail=0

while IFS= read -r line; do
    printf '%s\n' "$line"
    [[ "$line" == *"tpmC:"* && "$line" == *"measure "* ]] || continue
    now="$(date +%s)"
    if [[ "$line" =~ Fail:([0-9]+) ]]; then
        fail="${BASH_REMATCH[1]}"
    else
        continue
    fi
    [[ "$last_ts" -gt 0 ]] || { last_ts="$now"; last_fail="$fail"; continue; }
    interval=$((now - last_ts))
    ((interval > 0)) || continue
    last_ts="$now"

    fail_delta=$((fail - last_fail))
    ((fail_delta >= 0)) || fail_delta="$fail"
    last_fail="$fail"

    rest="$line"
    completed=0
    new_order=0
    new_order_p90=0
    while [[ "$rest" =~ ([A-Za-z]+):([0-9]+)\(p90=([0-9.]+)ms\) ]]; do
        name="${BASH_REMATCH[1]}"
        count="${BASH_REMATCH[2]}"
        p90="${BASH_REMATCH[3]}"
        completed=$((completed + count))
        if [[ "$name" == NewOrder ]]; then
            new_order="$count"
            new_order_p90="$p90"
        fi
        rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    ((completed > 0)) || continue

    rps="$(awk -v n="$completed" -v s="$interval" 'BEGIN { printf "%.3f", n/s }')"
    no_rps="$(awk -v n="$new_order" -v s="$interval" 'BEGIN { printf "%.3f", n/s }')"
    metric="tpcc_workload,application=${TPCC_APPLICATION},phase=measure rps=${rps},new_order_rps=${no_rps},new_order_p90_ms=${new_order_p90},failed_delta=${fail_delta}i,completed_delta=${completed}i ${now}000000000"
    if [[ -n "${TPCC_VM_WRITE_URL}" ]]; then
        curl --fail --silent --show-error --max-time 5 --data-binary "$metric" "${TPCC_VM_WRITE_URL}" >/dev/null || \
            printf 'TPC-C metric write failed; workload continues\n' >&2
    fi
done
