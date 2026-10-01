#!/usr/bin/env bash
# Немезис: смена GPT partition name (partlabel) через sgdisk + partx -u.
# Эмуляция «не того» диска для YDB без выдёргивания устройства из ядра.
#
# Ожидаются пакеты gdisk на хосте (prepare-hosts ставит gdisk).
#
# Переменные окружения (после source env):
#   CHAOS_DISK_PARTNUM        номер партиции (по умолчанию 1)
#   CHAOS_DISK_LABEL_CHAOS    метка во время хаоса (по умолчанию test)
#   CHAOS_DISK_LABEL_NORMAL   рабочая метка (по умолчанию ydb_disk_ssd_01)
#
# API:
#   nemesis_disk_apply    <host> <device> <timeout_s>   # device: vdb или /dev/vdb
#   nemesis_disk_teardown <host> <device>
#   nemesis_disk_check    <host> <device>

nemesis_disk_part_suffix() {
    local device="$1" part="$2"
    if [[ "${device}" =~ [0-9]$ ]]; then
        printf '%sp%s' "${device}" "${part}"
    else
        printf '%s%s' "${device}" "${part}"
    fi
}

nemesis_disk_apply() {
    local host="$1" device="$2" timeout_s="$3"
    device="${device#/dev/}"
    local part="${CHAOS_DISK_PARTNUM:-1}"
    local lab_off="${CHAOS_DISK_LABEL_CHAOS:-test}"
    local lab_on="${CHAOS_DISK_LABEL_NORMAL:-ydb_disk_ssd_01}"
    local chg_off chg_on disk_q part_q lab_on_q

    chg_off=$(printf '%q' "${part}:${lab_off}")
    chg_on=$(printf '%q' "${part}:${lab_on}")
    disk_q=$(printf '%q' "/dev/${device}")
    part_q=$(printf '%q' "/dev/$(nemesis_disk_part_suffix "$device" "$part")")
    lab_on_q=$(printf '%q' "$lab_on")

    log_chaos_apply "sgdisk partlabel ${lab_off} на ${host} ${disk_q}, авто ${lab_on} через ${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  sgdisk -c … + partx -u + timer restore"

    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [[ ! -b ${disk_q} ]]; then
    echo "ОШИБКА: блочное устройство ${disk_q} не найдено" >&2
    exit 1
fi
command -v sgdisk >/dev/null 2>&1 || { echo "ОШИБКА: нет sgdisk (apt install gdisk / prepare-hosts)" >&2; exit 1; }
current_label=\$(lsblk -no PARTLABEL ${part_q} | head -1)
if [[ "\${current_label}" != ${lab_on_q} ]]; then
    echo "ОШИБКА: неожиданная исходная метка на ${part_q}: \${current_label}" >&2
    exit 1
fi
nohup bash -c "sleep ${timeout_s}; sudo sgdisk -c ${chg_on} ${disk_q}; sudo partx -u ${disk_q}" >/tmp/disk-chaos.log 2>&1 &
echo \$! > /tmp/disk-chaos.pid
if ! sudo sgdisk -c ${chg_off} ${disk_q} || ! sudo partx -u ${disk_q}; then
    sudo sgdisk -c ${chg_on} ${disk_q} || true
    sudo partx -u ${disk_q} || true
    exit 1
fi
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт disk sgdisk, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_disk_teardown() {
    local host="$1" device="$2"
    device="${device#/dev/}"
    local part="${CHAOS_DISK_PARTNUM:-1}"
    local lab_on="${CHAOS_DISK_LABEL_NORMAL:-ydb_disk_ssd_01}"
    local chg_on disk_q
    chg_on=$(printf '%q' "${part}:${lab_on}")
    disk_q=$(printf '%q' "/dev/${device}")

    chaos_term_remote_cmd "ssh ${host}  kill disk timer + sgdisk restore ${lab_on}"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [[ -f /tmp/disk-chaos.pid ]]; then
    kill "\$(cat /tmp/disk-chaos.pid)" 2>/dev/null || true
    rm -f /tmp/disk-chaos.pid
fi
if [[ -b ${disk_q} ]] && command -v sgdisk >/dev/null 2>&1; then
    sudo sgdisk -c ${chg_on} ${disk_q}
    sudo partx -u ${disk_q}
fi
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт disk teardown, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
    log "Метка партиции восстановлена на ${host} (${lab_on})"
}

nemesis_disk_check() {
    local host="$1" device="$2"
    device="${device#/dev/}"
    local part="${CHAOS_DISK_PARTNUM:-1}"
    local lab_off="${CHAOS_DISK_LABEL_CHAOS:-test}"
    local lab_on="${CHAOS_DISK_LABEL_NORMAL:-ydb_disk_ssd_01}"
    local psuffix
    psuffix="$(nemesis_disk_part_suffix "${device}" "${part}")"

    chaos_term_remote_cmd "ssh ${host}  lsblk + by-partlabel"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<REMOTE
echo "=== /dev/${device} ==="
if [[ -b /dev/${device} ]]; then
    lsblk "/dev/${device}" 2>/dev/null || true
    if [[ -b /dev/${psuffix} ]]; then
        echo "=== partition /dev/${psuffix} ==="
        lsblk "/dev/${psuffix}" 2>/dev/null || true
    fi
else
    echo "  устройство отсутствует"
fi
echo "=== /dev/disk/by-partlabel/ (${lab_off} / ${lab_on}) ==="
ls -l "/dev/disk/by-partlabel/${lab_off}" 2>/dev/null || echo "  нет ${lab_off}"
ls -l "/dev/disk/by-partlabel/${lab_on}" 2>/dev/null || echo "  нет ${lab_on}"
REMOTE
}
