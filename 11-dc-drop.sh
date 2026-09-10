#!/usr/bin/env bash
# 11 — REJECT/DROP YDB-интерконнекта на всём ДЦ (немезис iptables).
# Для одной ноды используйте 06-net-drop.sh.

set -euo pipefail
TEST_NAME="11-dc-drop"
TEST_SCOPE="dc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/iptables.sh"

TEST_DESC="Тест 11 — блокировка YDB-портов на всех хостах ДЦ. По умолчанию REJECT, --drop переключает на DROP."

IPT_TARGET="REJECT"

chaos_usage_extra() {
    cat <<EOF
      --drop            DROP вместо REJECT (тихие потери)
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -4 -t 600
  $(basename "$0") -4 --drop -t 600
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
    if [[ -n "${CHECK_HOST}" ]]; then
        nemesis_iptables_check "${CHECK_HOST}"
    else
        for h in "${DC_HOSTS[@]}"; do
            echo ">>> ${h}"; nemesis_iptables_check "${h}"; echo ""
        done
    fi
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    TARGET_HOSTS=("${DC_HOSTS[@]}")
    if [[ -n "${EXPLICIT_HOSTS[*]:-}" || "${SCOPE_SINGLE}" == true || "${SCOPE_DC}" == true || "${SCOPE_DC_ALT}" == true ]]; then
        chaos_resolve_teardown_targets || exit 1
    fi
    nemesis_iptables_teardown_all "${TARGET_HOSTS[@]}"
    log_tl "CHAOS_CANCEL" "net ${IPT_TARGET}  scope=dc"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "target=${IPT_TARGET}  ports=${YDB_PORTS}  timeout=${TIMEOUT}s  scope=dc"

chaos_run_window "net ${IPT_TARGET}" \
    nemesis_iptables_apply_all \
    nemesis_iptables_teardown_all
