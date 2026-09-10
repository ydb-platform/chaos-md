#!/usr/bin/env bash
# 07 — Ограничение полосы (немезис tc, tbf) на корне qdisc: весь исходящий трафик интерфейса (не по портам).

set -euo pipefail
TEST_NAME="07-net-bw"
TEST_SCOPE="either"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/tc.sh"

TEST_DESC="Тест 07 — tbf на весь исходящий трафик каждого iface из NET_IFACES/NET_IFACES_TABLE (порты YDB не используются; при слабом эффекте проверьте все NIC)."

RATE="${DEFAULT_BW_RATE}"
BURST=""

chaos_usage_extra() {
    cat <<EOF
  -r, --rate MBIT       Полоса, мбит/с (по умолчанию: ${DEFAULT_BW_RATE})
  -b, --burst BYTES     Burst, байт (по умолчанию: авто = 15625 × rate)
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -r 500 -t 600
  $(basename "$0") -4 -r 2000 -t 600
  $(basename "$0") -C
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
i=0; while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        -r|--rate)  RATE="${CHAOS_REMAINING_ARGS[i+1]}";  ((i+=2)) ;;
        -b|--burst) BURST="${CHAOS_REMAINING_ARGS[i+1]}"; ((i+=2)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

if [[ -z "${BURST}" ]]; then
    BURST=$(( RATE * 15625 ))
    [[ ${BURST} -lt 1600 ]] && BURST=1600
fi

if [[ "${MODE_CHECK}" == true ]]; then
    chaos_run_checks nemesis_tc_check
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    chaos_resolve_teardown_targets || exit 1
    log "Снятие tc (bandwidth): ${#TARGET_HOSTS[@]} хостов — ${TARGET_HOSTS[*]}"
    nemesis_tc_teardown_all "${TARGET_HOSTS[@]}" || exit 1
    log_tl "CHAOS_CANCEL" "net bw  scope=${SCOPE_LABEL}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "rate=${RATE}mbit  burst=${BURST}b  timeout=${TIMEOUT}s  scope=${SCOPE_LABEL}"

chaos_run_window "net bw [${RATE}mbit]" \
    nemesis_tc_tbf_apply_all \
    nemesis_tc_teardown_all
