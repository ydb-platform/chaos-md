#!/usr/bin/env bash
# 12 — Остановка ydbd-юнитов (немезис systemd) на ноде, ДЦ или альт. ДЦ.
# Юниты автоматически поднимаются по таймеру; -D — поднять руками.

set -euo pipefail
TEST_NAME="12-server-stop"
TEST_SCOPE="node_or_dc_or_alt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
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
    chaos_run_checks nemesis_systemd_check
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
trap 'rc=$?; log_tl "CHAOS_CANCEL" "server stop  (прервано)" || true; chaos_log_script_end "${rc}"' EXIT

chaos_announce "stop ${YDBD_STORAGE_SERVICE} + ${#YDBD_TENANT_SERVICES[@]} tenant  timeout=${TIMEOUT}s  scope=${SCOPE_LABEL}"

# Хаос завершается фоновым recovery-скриптом на хосте (через TIMEOUT секунд).
# Локально ждём то же окно с тикером.
chaos_run_window_no_teardown "server stop" nemesis_systemd_stop_apply_all

trap 'chaos_log_script_end' EXIT
