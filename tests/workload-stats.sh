#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${ROOT}/workload/lib/stats.sh"

output="$(printf '%s\n' \
    'Timestamp Window Txs/Sec Retries Errors p50(ms) p95(ms) p99(ms) pMax(ms)' \
    '2026-05-07T13:30:01Z 1 120.5 2 0 5.1 8.3 12.4 15.0' \
    | stats_stream_to_lp smoke test-app)"

[[ "${output}" == *'ydb_workload,application=test-app,scenario=smoke,statut=ok '* ]]
[[ "${output}" == *' 1778160601000000000'* ]]
[[ "${output}" == *'statut=ko countError=0i 1778160601000000000'* ]]
printf 'workload ISO timestamp conversion passed\n'
