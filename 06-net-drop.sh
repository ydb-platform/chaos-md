#!/usr/bin/env bash
# 06 — REJECT/DROP YDB-интерконнекта на одной ноде (немезис iptables).

set -euo pipefail
TEST_NAME="06-net-drop"
TEST_SCOPE="single"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/iptables.sh"

TEST_DESC="Тест 06 — блокировка YDB-портов на одной ноде. По умолчанию REJECT (TCP RST), --drop переключает на DROP."

IPT_TARGET="REJECT"

chaos_usage_extra() {
    cat <<EOF
      --drop            DROP вместо REJECT (тихие потери, соединение висит до таймаута)
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -t 600
  $(basename "$0") -1 --drop -t 600
  $(basename "$0") -C
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
i=0; while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        --drop) IPT_TARGET="DROP"; ((i+=1)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

if [[ "${MODE_CHECK}" == true ]]; then
    chaos_run_checks nemesis_iptables_check
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    TARGET_HOSTS=("${NODE_HOST}")
    if [[ -n "${EXPLICIT_HOSTS[*]:-}" || "${SCOPE_SINGLE}" == true || "${SCOPE_DC}" == true || "${SCOPE_DC_ALT}" == true ]]; then
        chaos_resolve_teardown_targets || exit 1
    fi
    nemesis_iptables_teardown_all "${TARGET_HOSTS[@]}"
    log_tl "CHAOS_CANCEL" "net ${IPT_TARGET}  scope=node  host=${NODE_HOST}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "target=${IPT_TARGET}  ports=${YDB_PORTS}  timeout=${TIMEOUT}s  host=${NODE_HOST}"

chaos_run_window "net ${IPT_TARGET}" \
    nemesis_iptables_apply_all \
    nemesis_iptables_teardown_all
