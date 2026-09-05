#!/usr/bin/env bash
# 03 — «Отказ» диска для YDB: смена GPT partition name (sgdisk) на CHAOS_DISK_LABEL_CHAOS.
# Восстановление — возврат сохранённой исходной метки + partx -u (таймер или -D).
# В run-all.sh не входит (ручной контроль).

set -euo pipefail
TEST_NAME="03-disk-fail"
TEST_SCOPE="single"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
[[ ! -f "${SCRIPT_DIR}/reliability/env.local.sh" ]] || source "${SCRIPT_DIR}/reliability/env.local.sh"
source "${SCRIPT_DIR}/nemesis/disk.sh"
source "${SCRIPT_DIR}/nemesis/proc.sh"   # nemesis_proc_ydbd_restart

TEST_DESC="Тест 03 — диск: проверенная смена partlabel (sgdisk) с восстановлением исходной метки."

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
  $(basename "$0") -1 --hold -t 600 -d vdb
  $(basename "$0") -1 -D -d vdb
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
    nemesis_disk_teardown "${NODE_HOST}" "${DEVICE}"
    if [[ "${RESTART_STORAGE}" == true ]]; then
        log "Перезапуск storage после восстановления метки диска"
        nemesis_proc_ydbd_restart "${NODE_HOST}"
    fi
    log_tl "CHAOS_CANCEL" "disk fail  scope=node  host=${NODE_HOST}  device=${DEVICE}"
    exit 0
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'chaos_log_script_end' EXIT

chaos_announce "device=${DEVICE}  timeout=${TIMEOUT}s  host=${NODE_HOST}  restart_storage=${RESTART_STORAGE}"

nemesis_disk_apply "${NODE_HOST}" "${DEVICE}" "${TIMEOUT}"
if [[ "${RESTART_STORAGE}" == true ]]; then
    log "Перезапуск storage после применения хаоса диска"
    nemesis_proc_ydbd_restart "${NODE_HOST}"
fi
log_tl "CHAOS_START" "disk fail  scope=node  host=${NODE_HOST}  device=${DEVICE}  timeout=${TIMEOUT}s"

if [[ "${MODE_HOLD}" == true ]]; then
    log "Отказ диска оставлен активным; снимите его отдельным вызовом с -D"
    exit 0
fi

log_wait_sec "${TIMEOUT}"
chaos_wait_with_timer "${TIMEOUT}" "disk fail  ${NODE_HOST}"

# Таймер на сервере страхует восстановление при обрыве управляющей сессии.
# Здесь выполняем идемпотентное синхронное восстановление, чтобы CHAOS_END
# означал не истечение таймера, а фактический возврат диска.
nemesis_disk_teardown "${NODE_HOST}" "${DEVICE}"

if [[ "${RESTART_STORAGE}" == true ]]; then
    log "Перезапуск storage после восстановления метки"
    nemesis_proc_ydbd_restart "${NODE_HOST}"
fi

log_tl "CHAOS_END  " "disk fail  scope=node  host=${NODE_HOST}  device=${DEVICE}"
