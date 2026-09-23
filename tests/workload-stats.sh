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

tmp_dir="$(mktemp -d)"
fake_bin="${tmp_dir}/bin"
fifo="${tmp_dir}/input"
stream_output="${tmp_dir}/output"
writer_done="${tmp_dir}/writer-done"
trap 'rm -rf "${tmp_dir}"' EXIT
mkdir -p "${fake_bin}"

real_awk="$(command -v awk)"
cat >"${fake_bin}/awk" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-W" && "${2:-}" == "version" ]]; then
    printf 'mawk 1.3.4 test\n'
    exit 0
fi
if [[ "${1:-}" != "-W" || "${2:-}" != "interactive" ]]; then
    exit 42
fi
shift 2
exec "${REAL_AWK}" "$@"
EOF
chmod +x "${fake_bin}/awk"

REAL_AWK="${real_awk}" PATH="${fake_bin}:${PATH}" \
    stats_stream_to_lp smoke test-app <<'EOF' >/dev/null
Timestamp Window Txs/Sec Retries Errors p50(ms) p95(ms) p99(ms) pMax(ms)
2026-05-07T13:30:01Z 1 120.5 2 0 5.1 8.3 12.4 15.0
EOF
printf 'workload mawk interactive mode passed\n'

mkfifo "${fifo}"

stats_stream_to_lp smoke test-app <"${fifo}" >"${stream_output}" &
parser_pid=$!
{
    printf '%s\n' 'Timestamp Window Txs/Sec Retries Errors p50(ms) p95(ms) p99(ms) pMax(ms)'
    printf '%s\n' '2026-05-07T13:30:01Z 1 120.5 2 0 5.1 8.3 12.4 15.0'
    sleep 1
    touch "${writer_done}"
} >"${fifo}" &
writer_pid=$!

streamed=false
while [[ ! -e "${writer_done}" ]]; do
    if [[ -s "${stream_output}" ]]; then
        streamed=true
        break
    fi
    sleep 0.05
done

wait "${writer_pid}"
wait "${parser_pid}"
[[ "${streamed}" == true ]]
printf 'workload streaming flush passed\n'
