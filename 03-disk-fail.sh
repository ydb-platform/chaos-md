#!/usr/bin/env bash
# 03 — «Отказ» диска для YDB: смена GPT partition name (sgdisk) на CHAOS_DISK_LABEL_CHAOS.
# Восстановление — возврат CHAOS_DISK_LABEL_NORMAL + partx -u (таймер или -D).
# В run-all.sh не входит (ручной контроль).

set -euo pipefail
TEST_NAME="03-disk-fail"
TEST_SCOPE="single"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/disk.sh"
source "${SCRIPT_DIR}/nemesis/proc.sh"   # nemesis_proc_ydbd_restart

TEST_DESC="Тест 03 — диск: смена partlabel (sgdisk), устройство по умолчанию vdb."

DEVICE="${DEFAULT_DISK_DEVICE:-vdb}"
RESTART_STORAGE="${CHAOS_DISK_RESTART_STORAGE}"

chaos_usage_extra() {
    cat <<EOF
  -d, --device DEV      Блочное устройство без или с префиксом /dev/ (по умолчанию: ${DEVICE})
  --no-restart          Не делать systemctl restart storage (ни после хаоса, ни после снятия)
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -t 600 -d vdb
  $(basename "$0") -1 -t 600 --no-restart
  $(basename "$0") -D
  $(basename "$0") -C
EOF
}

chaos_parse_common "$@"
i=0
while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        -d|--device)   DEVICE="${CHAOS_REMAINING_ARGS[i+1]}"; ((i+=2)) ;;
        --no-restart)   RESTART_STORAGE=false; ((i+=1)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

if [[ "${MODE_CHECK}" == true ]]; then
    nemesis_disk_check "${CHECK_HOST}" "${DEVICE}"
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    TARGET_HOSTS=("${NODE_HOST}")
    if [[ -n "${EXPLICIT_HOSTS[*]:-}" || "${SCOPE_SINGLE}" == true || "${SCOPE_DC}" == true || "${SCOPE_DC_ALT}" == true ]]; then
        chaos_resolve_teardown_targets || exit 1
    fi
    for host in "${TARGET_HOSTS[@]}"; do
        nemesis_disk_teardown "${host}" "${DEVICE}"
        if [[ "${RESTART_STORAGE}" == true ]]; then
            nemesis_proc_ydbd_restart "${host}"
        fi
    done
    log_tl "CHAOS_CANCEL" "disk fail  hosts=${TARGET_HOSTS[*]}  device=${DEVICE}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets
[[ ${#TARGET_HOSTS[@]} -eq 1 ]] || { echo "disk apply requires one host" >&2; exit 1; }
NODE_HOST="${TARGET_HOSTS[0]}"

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "device=${DEVICE}  timeout=${TIMEOUT}s  host=${NODE_HOST}  restart_storage=${RESTART_STORAGE}"

nemesis_disk_apply "${NODE_HOST}" "${DEVICE}" "${TIMEOUT}"
if [[ "${RESTART_STORAGE}" == true ]]; then
    log "Перезапуск storage после применения хаоса диска"
    nemesis_proc_ydbd_restart "${NODE_HOST}"
fi
log_tl "CHAOS_START" "disk fail  scope=node  host=${NODE_HOST}  device=${DEVICE}  timeout=${TIMEOUT}s"

log_wait_sec "${TIMEOUT}"
chaos_wait_with_timer "${TIMEOUT}" "disk fail  ${NODE_HOST}"

log_tl "CHAOS_END  " "disk fail  scope=node  host=${NODE_HOST}  device=${DEVICE}"

if [[ "${RESTART_STORAGE}" == true ]]; then
    log "Перезапуск storage после автовосстановления метки"
    nemesis_proc_ydbd_restart "${NODE_HOST}"
fi
