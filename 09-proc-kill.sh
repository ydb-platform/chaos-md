#!/usr/bin/env bash
# 09 — SIGKILL всем процессам ydbd на ноде или во всём основном ДЦ (немезис proc).

set -euo pipefail
TEST_NAME="09-proc-kill"
TEST_SCOPE="either"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/proc.sh"

TEST_DESC="Тест 09 — SIGKILL процессов ydbd (-1 одна нода или -4 весь ДЦ); затем наблюдение и опц. явный рестарт."

YDBD_BIN="${DEFAULT_YDBD_BIN:-/opt/ydb/bin/ydbd}"
RESTART_YDBD=false

chaos_usage_extra() {
    cat <<EOF
  -r, --restart         После -t — явный systemctl restart storage
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -t 600
  $(basename "$0") -4 -t 600
  $(basename "$0") -1 -t 600 -r
  $(basename "$0") -4 -D
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
i=0; while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        -r|--restart) RESTART_YDBD=true; ((i+=1)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

if [[ "${MODE_CHECK}" == true ]]; then
    chaos_run_checks nemesis_proc_check
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    chaos_resolve_teardown_targets || exit 1
    parallel_for_hosts nemesis_proc_ydbd_restart "${TARGET_HOSTS[@]}" --
    log_tl "CHAOS_CANCEL" "proc kill  scope=${SCOPE_LABEL}  hosts=${TARGET_HOSTS[*]}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "SIGKILL ydbd timeout=${TIMEOUT}s scope=${SCOPE_LABEL} hosts=${#TARGET_HOSTS[@]} restart_after=${RESTART_YDBD}"

parallel_for_hosts nemesis_proc_kill_apply "${TARGET_HOSTS[@]}" --
log_tl "CHAOS_START" "proc kill  scope=${SCOPE_LABEL}  hosts=${TARGET_HOSTS[*]}  timeout=${TIMEOUT}s"

log_wait_sec "${TIMEOUT}"
if [[ "${SCOPE_LABEL}" == node ]]; then
    chaos_wait_with_timer "${TIMEOUT}" "proc kill  ${TARGET_HOSTS[0]}"
else
    chaos_wait_with_timer "${TIMEOUT}" "proc kill  scope=${SCOPE_LABEL} (${#TARGET_HOSTS[@]} хостов)"
fi

log_tl "CHAOS_END  " "proc kill  scope=${SCOPE_LABEL}  hosts=${TARGET_HOSTS[*]}"

if [[ "${RESTART_YDBD}" == true ]]; then
    log "Явный перезапуск storage после наблюдения (${#TARGET_HOSTS[@]} хостов)"
    parallel_for_hosts nemesis_proc_ydbd_restart "${TARGET_HOSTS[@]}" --
fi
