#!/usr/bin/env bash
# 02 — Нагрузка памяти RAM + page cache (немезис blade) на ноде, ДЦ или альт. ДЦ.

set -euo pipefail
TEST_NAME="02-mem-load"
TEST_SCOPE="node_or_dc_or_alt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/blade.sh"

TEST_DESC="Тест 02 — нагрузка памяти RAM + cache (немезис blade)."

MEM_PERCENT="${DEFAULT_MEM_PERCENT:-90}"
MEM_RATE="${DEFAULT_MEM_RATE:-500}"
BLADE_TIMEOUT="${DEFAULT_BLADE_TIMEOUT}"

chaos_usage_extra() {
    cat <<EOF
  -m, --mem-percent N      Процент памяти (по умолчанию: ${MEM_PERCENT})
  -R, --rate MB            Скорость заполнения RAM, МБ/с (по умолчанию: ${MEM_RATE})
  -T, --blade-timeout SEC  --timeout в ChaosBlade, с (по умолчанию: ${BLADE_TIMEOUT})
     Шаблоны CLI: CHAOS_BLADE_MEM_RAM_TEMPLATE / CHAOS_BLADE_MEM_CACHE_TEMPLATE в env.
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -m 90 -t 1200 -T 1300
  $(basename "$0") -4 -t 600
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
i=0; while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        -m|--mem-percent)   MEM_PERCENT="${CHAOS_REMAINING_ARGS[i+1]}";   ((i+=2)) ;;
        -R|--rate)          MEM_RATE="${CHAOS_REMAINING_ARGS[i+1]}";      ((i+=2)) ;;
        -T|--blade-timeout) BLADE_TIMEOUT="${CHAOS_REMAINING_ARGS[i+1]}"; ((i+=2)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

# Apply: на каждом хосте параллельно ram + cache (два UID на хост).
_apply_one_host() {
    local host="$1"
    nemesis_blade_run "${host}" "ram" "$(nemesis_blade_cmd_mem_ram)"
    nemesis_blade_run "${host}" "cache" "$(nemesis_blade_cmd_mem_cache)"
}

_apply() {
    log_chaos_apply "blade mem ram+cache ${MEM_PERCENT}% --timeout ${BLADE_TIMEOUT}s на ${#@} хостах"
    parallel_for_hosts _apply_one_host "$@"
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
        nemesis_blade_destroy_all "ram" "${TARGET_HOSTS[@]}"
        nemesis_blade_destroy_all "cache" "${TARGET_HOSTS[@]}"
    else
        nemesis_blade_destroy_all "ram"
        nemesis_blade_destroy_all "cache"
        SCOPE_LABEL=all
    fi
    log_tl "CHAOS_CANCEL" "mem load  scope=${SCOPE_LABEL}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "mem=${MEM_PERCENT}%  rate=${MEM_RATE}  wait=${TIMEOUT}s  blade_timeout=${BLADE_TIMEOUT}s  scope=${SCOPE_LABEL}"

chaos_run_window_no_teardown "mem load" _apply
