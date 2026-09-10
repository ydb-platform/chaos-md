#!/usr/bin/env bash
# 08 — Заморозка процессов ydbd (немезис proc, SIGSTOP/SIGCONT) на ноде или во всём основном ДЦ.

set -euo pipefail
TEST_NAME="08-proc-freeze"
TEST_SCOPE="either"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/proc.sh"

TEST_DESC="Тест 08 — заморозка процессов ydbd (немезис proc): -1 одна нода или -4 весь ДЦ."

YDBD_BIN="${DEFAULT_YDBD_BIN:-/opt/ydb/bin/ydbd}"

chaos_usage_extra() {
    cat <<EOF
  (доп. опций нет — заморозка всех процессов pgrep -f ${YDBD_BIN})
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -t 600
  $(basename "$0") -4 -t 600
  $(basename "$0") -C
  $(basename "$0") -4 -D
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
if (( ${#CHAOS_REMAINING_ARGS[@]} > 0 )); then
    echo "Неизвестные параметры: ${CHAOS_REMAINING_ARGS[*]}" >&2
    chaos_usage >&2; exit 1
fi

if [[ "${MODE_CHECK}" == true ]]; then
    if [[ "${SCOPE_SINGLE}" == true || "${SCOPE_DC}" == true || "${SCOPE_DC_ALT}" == true ]]; then
        chaos_resolve_targets
        _h=""
        for _h in "${TARGET_HOSTS[@]}"; do
            nemesis_proc_check "${_h}"
        done
    else
        nemesis_proc_check "${CHECK_HOST}"
    fi
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    chaos_resolve_teardown_targets || exit 1
    parallel_for_hosts nemesis_proc_freeze_teardown "${TARGET_HOSTS[@]}" --
    log_tl "CHAOS_CANCEL" "proc freeze  scope=${SCOPE_LABEL}  hosts=${TARGET_HOSTS[*]}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'rc=$?; log_tl "CHAOS_CANCEL" "proc freeze  scope=${SCOPE_LABEL}  hosts=${TARGET_HOSTS[*]}  (прервано)" || true; chaos_log_script_end "${rc}"' EXIT

chaos_announce "freeze ydbd timeout=${TIMEOUT}s scope=${SCOPE_LABEL} hosts=${#TARGET_HOSTS[@]}"

# chaos_run_window передаёт сюда все TARGET_HOSTS как позиционные аргументы.
_apply()    { parallel_for_hosts nemesis_proc_freeze_apply "$@" -- "${TIMEOUT}"; }
_teardown() { parallel_for_hosts nemesis_proc_freeze_teardown "$@"; }

chaos_run_window "proc freeze" _apply _teardown

trap 'chaos_log_script_end' EXIT
