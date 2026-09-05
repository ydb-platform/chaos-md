#!/usr/bin/env bash
# 12 — Остановка ydbd-юнитов (немезис systemd) на ноде, ДЦ или альт. ДЦ.
# Юниты автоматически поднимаются по таймеру; -D — поднять руками.

set -euo pipefail
TEST_NAME="12-server-stop"
TEST_SCOPE="node_or_dc_or_alt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
[[ ! -f "${SCRIPT_DIR}/reliability/env.local.sh" ]] || source "${SCRIPT_DIR}/reliability/env.local.sh"
source "${SCRIPT_DIR}/nemesis/systemd.sh"

TEST_DESC="Тест 12 — остановка systemd-юнитов ydbd с авто-стартом по таймеру."

chaos_usage_extra() {
    cat <<EOF
  (доп. опций нет — список юнитов в env.sh):
$(chaos_ydbd_units_help)
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -t 600
  $(basename "$0") -1 --hold -t 600
  $(basename "$0") -1 -D
  $(basename "$0") -4 -t 600
  $(basename "$0") -A -t 600
  $(basename "$0") -C
  $(basename "$0") -4 -C
  $(basename "$0") -D
  $(basename "$0") -4 -D
EOF
}

chaos_parse_common "$@"
if (( ${#CHAOS_REMAINING_ARGS[@]} > 0 )); then
    echo "Неизвестные параметры: ${CHAOS_REMAINING_ARGS[*]}" >&2
    chaos_usage >&2; exit 1
fi

if [[ "${MODE_CHECK}" == true ]]; then
    if [[ "${SCOPE_DC}" == true ]]; then
        for h in "${DC_HOSTS[@]}"; do
            echo ">>> ${h}"
            nemesis_systemd_check "${h}"
            echo ""
        done
    elif [[ "${SCOPE_DC_ALT}" == true ]]; then
        for h in "${DC_ALT_HOSTS[@]}"; do
            echo ">>> ${h}"
            nemesis_systemd_check "${h}"
            echo ""
        done
    else
        nemesis_systemd_check "${CHECK_HOST}"
    fi
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    chaos_resolve_teardown_targets || exit 1
    nemesis_systemd_stop_teardown_all "${TARGET_HOSTS[@]}" || exit 1
    log_tl "CHAOS_CANCEL" "server stop  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'log_tl "CHAOS_CANCEL" "server stop  (прервано)" || true; chaos_log_script_end' EXIT

chaos_announce "stop ${YDBD_STORAGE_SERVICE} + ${#YDBD_TENANT_SERVICES[@]} tenant  timeout=${TIMEOUT}s  scope=${SCOPE_LABEL}"

# Recovery-скрипт на хосте страхует восстановление при обрыве управляющей
# сессии. При штатном завершении выполняем тот же идемпотентный teardown явно:
# так CHAOS_END ставится только после фактического старта storage и tenant.
chaos_run_window "server stop" nemesis_systemd_stop_apply_all nemesis_systemd_stop_teardown_all

trap 'chaos_log_script_end' EXIT
