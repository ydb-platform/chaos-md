#!/usr/bin/env bash
# 04 — Задержка сети (немезис tc, netem) на исходящем TCP с портами YDB (sport и dport; IPv4/IPv6).

set -euo pipefail
TEST_NAME="04-net-delay"
TEST_SCOPE="either"
CHAOS_RESOURCE_EVIDENCE_FAMILY="tc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/tc.sh"

TEST_DESC="Тест 04 — netem delay на исходящем TCP, если sport или dport из YDB_PORTS. Порты: ${YDB_PORTS}"

DELAY="${DEFAULT_NET_DELAY}"

chaos_usage_extra() {
    cat <<EOF
  -d, --delay MS        Задержка, мс (по умолчанию: ${DEFAULT_NET_DELAY})
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -d 50 -t 600
  $(basename "$0") -4 -d 50 -t 600
  $(basename "$0") -C
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
i=0; while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        -d|--delay) DELAY="${CHAOS_REMAINING_ARGS[i+1]}"; ((i+=2)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

if [[ "${MODE_CHECK}" == true ]]; then
    chaos_run_checks nemesis_tc_check
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    chaos_resolve_teardown_targets || exit 1
    nemesis_tc_teardown_all "${TARGET_HOSTS[@]}" || exit 1
    log_tl "CHAOS_CANCEL" "net delay  scope=${SCOPE_LABEL}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "delay=${DELAY}ms  timeout=${TIMEOUT}s  scope=${SCOPE_LABEL}"

NETEM_PARAMS="delay ${DELAY}ms"
chaos_run_window "net delay [${DELAY}ms]" \
    nemesis_tc_netem_apply_all \
    nemesis_tc_teardown_all
