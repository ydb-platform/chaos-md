#!/usr/bin/env bash
# 01 — Дефицит CPU (немезис blade) на ноде, основном или альтернативном ДЦ.
# -t — длительность фазы; -T — --timeout в blade (запас, обычно ≥ -t).

set -euo pipefail
TEST_NAME="01-cpu-load"
TEST_SCOPE="node_or_dc_or_alt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/blade.sh"

TEST_DESC="Тест 01 — нагрузка CPU (немезис blade)."

CPU_PERCENT="${DEFAULT_CPU_PERCENT}"
BLADE_TIMEOUT="${DEFAULT_BLADE_TIMEOUT}"

chaos_usage_extra() {
    cat <<EOF
  -p, --cpu-percent N      Процент CPU (по умолчанию: ${DEFAULT_CPU_PERCENT})
  -T, --blade-timeout SEC  --timeout в ChaosBlade, с (по умолчанию: ${DEFAULT_BLADE_TIMEOUT})
     Синтаксис blade см. CHAOS_BLADE_CPU_LOAD_TEMPLATE в env (если «unknown flag»).
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -p 90 -t 1200 -T 1300
  $(basename "$0") -4 -t 600
  $(basename "$0") -A -t 600
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
i=0; while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        -p|--cpu-percent)   CPU_PERCENT="${CHAOS_REMAINING_ARGS[i+1]}";   ((i+=2)) ;;
        -T|--blade-timeout) BLADE_TIMEOUT="${CHAOS_REMAINING_ARGS[i+1]}"; ((i+=2)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

# Apply: blade-команда формируется здесь; немезис blade просто запускает её и сохраняет UID.
_apply() {
    local cmd
    cmd="$(nemesis_blade_cmd_cpu_load)"
    log_chaos_apply "blade cpu (${cmd}) на ${#@} хостах"
    parallel_for_hosts nemesis_blade_run "$@" -- "uid" "${cmd}"
}

if [[ "${MODE_CHECK}" == true ]]; then
    chaos_run_checks nemesis_blade_check
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    if [[ -n "${EXPLICIT_HOSTS[*]:-}" || "${SCOPE_SINGLE}" == true || "${SCOPE_DC}" == true || "${SCOPE_DC_ALT}" == true ]]; then
        chaos_resolve_teardown_targets || exit 1
        nemesis_blade_destroy_all "uid" "${TARGET_HOSTS[@]}"
    else
        nemesis_blade_destroy_all "uid"
        SCOPE_LABEL=all
    fi
    log_tl "CHAOS_CANCEL" "cpu load  scope=${SCOPE_LABEL}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "cpu=${CPU_PERCENT}%  wait=${TIMEOUT}s  blade_timeout=${BLADE_TIMEOUT}s  scope=${SCOPE_LABEL}"

# Хаос завершается сам по --timeout в blade; явный teardown — отдельный запуск с -D.
chaos_run_window_no_teardown "cpu load" _apply
