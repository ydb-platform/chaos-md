#!/usr/bin/env bash
# 10 — Rolling upgrade бинарника ydbd на одной ноде (немезис systemd, upgrade-API)
# с автооткатом по таймеру:
#   1. Копируем дистрибутив на хост (если нужно).
#   2. Распаковка нового бинарника в /tmp/ydbd.new.
#   3. systemctl stop tenants → storage.
#   4. Бэкап текущего ydbd → ~/${BACKUP_FILE}; установка нового.
#   5. systemctl start storage → tenants; на хосте взводится фоновый таймер автооткара.
#   6. Локально ждём окно -t.
#   7. Снимаем таймер; явный откат бинарника; перезапуск сервисов.

set -euo pipefail
TEST_NAME="10-rolling-upgrade"
TEST_SCOPE="single"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/init.sh"
source "${SCRIPT_DIR}/nemesis/systemd.sh"

TEST_DESC="Тест 10 — rolling upgrade ydbd на одной ноде с автооткатом."

DIST_FILE="${ROLLING_UPGRADE_DIST:-${SCRIPT_DIR}/dist/ydbd-package.tar.xz}"
DIST_NAME="$(basename "${DIST_FILE}")"
YDBD_BIN="${DEFAULT_YDBD_BIN:-/opt/ydb/bin/ydbd}"
BACKUP_DIR="ydbd_backup"
BACKUP_FILE="${BACKUP_DIR}/ydbd.orig"

chaos_usage_extra() {
    cat <<EOF
  -f, --file PATH       Локальный архив с */bin/ydbd внутри (по умолчанию: ${DIST_FILE})
EOF
}
chaos_usage_examples() {
    cat <<EOF
  $(basename "$0") -1 -t 1200
  $(basename "$0") -1 -f ./dist/ydbd-package.tar.xz -t 1200
  $(basename "$0") -C
  $(basename "$0") -D
EOF
}

chaos_parse_common "$@"
i=0; while (( i < ${#CHAOS_REMAINING_ARGS[@]} )); do
    case "${CHAOS_REMAINING_ARGS[i]}" in
        -f|--file) DIST_FILE="${CHAOS_REMAINING_ARGS[i+1]}"; DIST_NAME="$(basename "${DIST_FILE}")"; ((i+=2)) ;;
        *) echo "Неизвестный параметр: ${CHAOS_REMAINING_ARGS[i]}" >&2; chaos_usage >&2; exit 1 ;;
    esac
done

if [[ "${MODE_CHECK}" == true ]]; then
    nemesis_systemd_upgrade_check "${CHECK_HOST}"
    exit 0
fi

if [[ "${MODE_TEARDOWN}" == true ]]; then
    chaos_log_script_start
    trap 'chaos_log_script_end' EXIT
    log "Досрочный откат на ${NODE_HOST}"
    nemesis_systemd_upgrade_disarm_timer "${NODE_HOST}"
    nemesis_systemd_upgrade_svc_stop    "${NODE_HOST}"
    nemesis_systemd_upgrade_restore     "${NODE_HOST}"
    nemesis_systemd_upgrade_svc_start   "${NODE_HOST}"
    log_tl "CHAOS_CANCEL" "rolling upgrade  scope=node  host=${NODE_HOST}"
    exit 0
fi

# Архив нужен только для основного сценария.
if [[ ! -f "${DIST_FILE}" ]]; then
    echo "Ошибка: дистрибутив не найден: ${DIST_FILE}" >&2
    exit 1
fi

chaos_require_scope || { chaos_usage >&2; exit 1; }
chaos_resolve_targets

chaos_log_script_start
trap 'rc=$?; log_tl "CHAOS_CANCEL" "rolling upgrade  scope=node  host=${NODE_HOST}  (прервано; nohup-откат через ${TIMEOUT}с)" || true; chaos_log_script_end "${rc}"' EXIT

chaos_announce "host=${NODE_HOST}  dist=${DIST_NAME}  timeout=${TIMEOUT}s"

# Копируем архив, если на хосте отсутствует или отличается размером.
LOCAL_SIZE=$(wc -c < "${DIST_FILE}" | tr -d ' ')
chaos_term_remote_cmd "ssh ${NODE_HOST}  wc -c ~/${DIST_NAME}"
REMOTE_SIZE=$(ssh "${SSH_OPTS[@]}" "${NODE_HOST}" "[ -f ~/${DIST_NAME} ] && wc -c < ~/${DIST_NAME} | tr -d ' ' || echo 0")
if [[ "${REMOTE_SIZE}" != "${LOCAL_SIZE}" ]]; then
    log "Копирование дистрибутива на хост (local=${LOCAL_SIZE}, remote=${REMOTE_SIZE:-0})"
    ssh_scp_to "${NODE_HOST}" "${DIST_FILE}" "~/${DIST_NAME}"
else
    log "Дистрибутив уже на хосте (${LOCAL_SIZE} байт)"
fi

# Целостность архива до остановки сервисов.
log "Проверка целостности архива и наличия */bin/ydbd"
YDBD_PATH=$(ssh "${SSH_OPTS[@]}" "${NODE_HOST}" "tar tf ~/${DIST_NAME} 2>/dev/null | grep '.*/bin/ydbd$'" || true)
if [[ -z "${YDBD_PATH}" ]]; then
    echo "ОШИБКА: архив повреждён или не содержит '*/bin/ydbd'" >&2
    exit 1
fi
log "Найден: ${YDBD_PATH}"

nemesis_systemd_upgrade_extract   "${NODE_HOST}" "${YDBD_PATH}"
nemesis_systemd_upgrade_svc_stop  "${NODE_HOST}"
nemesis_systemd_upgrade_backup    "${NODE_HOST}"
nemesis_systemd_upgrade_place     "${NODE_HOST}"
nemesis_systemd_upgrade_svc_start "${NODE_HOST}"
nemesis_systemd_upgrade_arm_timer "${NODE_HOST}"

log_tl "CHAOS_START" "rolling upgrade  scope=node  host=${NODE_HOST}  timeout=${TIMEOUT}s"

log_wait_sec "${TIMEOUT}"
chaos_wait_with_timer "${TIMEOUT}" "rolling upgrade  ${NODE_HOST}"

log "Ручной откат после ожидания (отмена фонового таймера)"
nemesis_systemd_upgrade_disarm_timer "${NODE_HOST}"
nemesis_systemd_upgrade_svc_stop     "${NODE_HOST}"
nemesis_systemd_upgrade_restore      "${NODE_HOST}"
nemesis_systemd_upgrade_svc_start    "${NODE_HOST}"

trap 'chaos_log_script_end' EXIT
log_tl "CHAOS_END  " "rolling upgrade  scope=node  host=${NODE_HOST}"
