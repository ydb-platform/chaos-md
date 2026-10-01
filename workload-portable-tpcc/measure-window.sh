#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/config.sh"
[[ $# -eq 2 && "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && "$2" -gt "$1" ]] || {
    echo "Usage: $0 START_EPOCH END_EPOCH" >&2; exit 2;
}
start="$1"
end="$2"
url="${TPCC_VM_QUERY_URL:-http://localhost:8428/api/v1/query_range}"

query() {
    curl --fail --silent --show-error --max-time 10 --get "$url" \
        --data-urlencode "query=$1" --data-urlencode "start=$start" \
        --data-urlencode "end=$end" --data-urlencode 'step=5s'
}

rps="$(query "tpcc_workload_rps{application=\"$TPCC_APPLICATION\"}" | jq -er --argjson end "$end" '
    if ((.data.result[0].values[-1][0] // 0) < ($end - 15)) then
        error("RPS samples are stale")
    else [.data.result[]?.values[][1] | tonumber] as $v |
    if ($v | length) < 3 then error("Too few RPS samples") else
        [($v | length), (($v | add) / ($v | length)), ($v | min), ($v | max)] | @tsv
    end end')"
fail="$(query "tpcc_workload_failed_delta{application=\"$TPCC_APPLICATION\"}" | jq -er '
    [.data.result[]?.values[][1] | tonumber] as $v |
    if ($v | length) < 3 then error("Too few failure samples") else ($v | add) end')"
p90="$(query "tpcc_workload_new_order_p90_ms{application=\"$TPCC_APPLICATION\"}" | jq -er '
    [.data.result[]?.values[][1] | tonumber] as $v |
    if ($v | length) < 3 then error("Too few p90 samples") else (($v | add) / ($v | length)) end')"
printf '%s\t%s\t%s\n' "$rps" "$fail" "$p90"
