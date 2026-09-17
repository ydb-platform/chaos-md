#!/usr/bin/env bash
# Пример конфигурации хаос-тестирования YDB (вымышленные хосты и значения).
# Скопируйте в env.sh и отредактируйте под свой стенд.

# === Sync (читается sync-to-remote.sh) ===
RSYNC_HOST="ydb-chaos-bastion.example.invalid"
RSYNC_DEST="chaos-tests"

# === Топология стенда ===

# Хост для тестирования одной ноды
SINGLE_HOST="ydb-chaos-node-01.example.invalid"

# Хосты для фазы "весь ДЦ" (4 ноды)
DC_HOSTS=(
    ydb-chaos-node-01.example.invalid
    ydb-chaos-node-02.example.invalid
    ydb-chaos-node-03.example.invalid
    ydb-chaos-node-04.example.invalid
)

# Альтернативный ДЦ (вторая группа нод). Тест 01: флаг -A / --dc-alt
DC_ALT_HOSTS=(
    ydb-chaos-node-11.example.invalid
    ydb-chaos-node-12.example.invalid
    ydb-chaos-node-13.example.invalid
    ydb-chaos-node-14.example.invalid
)

# Все хосты кластера
CLUSTER_HOSTS=(
    ydb-chaos-node-01.example.invalid
    ydb-chaos-node-02.example.invalid
    ydb-chaos-node-03.example.invalid
    ydb-chaos-node-04.example.invalid
    ydb-chaos-node-05.example.invalid
    ydb-chaos-node-06.example.invalid
    ydb-chaos-node-07.example.invalid
    ydb-chaos-node-08.example.invalid
    ydb-chaos-node-11.example.invalid
    ydb-chaos-node-12.example.invalid
    ydb-chaos-node-13.example.invalid
    ydb-chaos-node-14.example.invalid
)

BLADE_REMOTE="cd && sudo ./blade"

LOG_TZ="Europe/Moscow"
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs"

DEFAULT_CHAOS_TIMEOUT=1200
DEFAULT_BLADE_TIMEOUT=630
DEFAULT_RUNALL_DUAL_PAUSE=60
DEFAULT_ROLLING_WAIT=0
DEFAULT_CPU_PERCENT=90

# Сетевые стеки для tc и iptables (true/false).
CHAOS_NET_IPV4="${CHAOS_NET_IPV4:-true}"
CHAOS_NET_IPV6="${CHAOS_NET_IPV6:-false}"
CHAOS_TC_STATE_DIR="${CHAOS_TC_STATE_DIR:-/var/lib/chaos-md}"

# Базовый список интерфейсов, если для хоста нет строки в NET_IFACES_TABLE.
NET_IFACE="eth0"
NET_IFACES=( )

# Опционально: «pattern|iface1,iface2». Первое совпадение по хосту;
# «*|…» — если ни один pattern не подошёл. Старое имя: CHAOS_HOST_IFACE_TABLE.
# Для тестов 06/11 (iptables) и tc: укажите все NIC с межнодевым YDB-трафиком, иначе второй линк не попадёт под правила.
NET_IFACES_TABLE=(
    "ydb-chaos-node-06.*|enp101s0,enp101s1"
    "*|eth0,eth1"
)

DEFAULT_NET_DELAY=50
DEFAULT_NET_LOSS=2
DEFAULT_BW_RATE=1

# Порты YDB-интерконнекта: список и/или диапазоны (пример)
YDB_PORTS="2135,2136,19001,8765,31000:32000"

# Цепочка для 06/11; имя можно переопределить (раньше в доках фигурировало YDB_FW).
# Префикс уникальных цепочек операций 06/11. Скрипт ограничивает его до 10 символов.
CHAOS_IPTABLES_CHAIN="${CHAOS_IPTABLES_CHAIN:-YDB_CHAOS_FW}"

# Если ./blade ругается на флаги — задайте свои шаблоны (плейсхолдеры @CPU_PERCENT@ @MEM_PERCENT@ @MEM_RATE@ @TIMEOUT@).
# CHAOS_BLADE_CPU_LOAD_TEMPLATE='create cpu load --cpu-percent @CPU_PERCENT@ --timeout @TIMEOUT@'
# CHAOS_BLADE_MEM_RAM_TEMPLATE='create mem load --mode ram --mem-percent @MEM_PERCENT@ --rate @MEM_RATE@ --avoid-being-killed --include-buffer-cache --timeout @TIMEOUT@'
# CHAOS_BLADE_MEM_CACHE_TEMPLATE='create mem load --mode cache --mem-percent @MEM_PERCENT@ --avoid-being-killed --timeout @TIMEOUT@'

YDBD_STORAGE_SERVICE="ydbd-storage.service"
YDBD_TENANT_SERVICES=(
    ydbd-database-a.service
    ydbd-database-b.service
)
YDBD_TENANT_UNIT_GLOB="ydbd-database-*.service"

chaos_ydb_ports_help_line() {
    echo "${YDB_PORTS}"
}

chaos_ydbd_units_help() {
    echo "  ${YDBD_STORAGE_SERVICE}"
    local _u
    for _u in "${YDBD_TENANT_SERVICES[@]}"; do
        echo "  ${_u}"
    done
}

DEFAULT_MEM_PERCENT=90
DEFAULT_MEM_RATE=500
DEFAULT_DISK_DEVICE="vdb"
CHAOS_DISK_PARTNUM="${CHAOS_DISK_PARTNUM:-1}"
CHAOS_DISK_LABEL_CHAOS="${CHAOS_DISK_LABEL_CHAOS:-test}"
CHAOS_DISK_LABEL_NORMAL="${CHAOS_DISK_LABEL_NORMAL:-ydb_disk_ssd_01}"
CHAOS_DISK_RESTART_STORAGE="${CHAOS_DISK_RESTART_STORAGE:-true}"
DEFAULT_YDBD_BIN="/opt/ydb/bin/ydbd"

SSH_OPTS=(-o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes)
CHAOS_SSH_CONNECT_TIMEOUT="${CHAOS_SSH_CONNECT_TIMEOUT:-8}"
CHAOS_SSH_SERVER_ALIVE_INTERVAL="${CHAOS_SSH_SERVER_ALIVE_INTERVAL:-5}"
CHAOS_SSH_SERVER_ALIVE_COUNT_MAX="${CHAOS_SSH_SERVER_ALIVE_COUNT_MAX:-2}"

GRAFANA_URL="${GRAFANA_URL:-https://grafana.example.invalid/}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"

# === Мониторинг (для install-скриптов в grafana/) ===
MON_HOST="ydb-chaos-bastion.example.invalid"
YDB_MON_PORTS="8765,8767,8768"
YDB_MON_PD_PORT=8765   # порт мониторинга узла хранения (pdisks/vdisks)
NODE_EXPORTER_PORT=9100
NODE_EXPORTER_VERSION="1.8.2"
GRAFANA_DOCKER_IMAGE="grafana/grafana:11.3.0"
VICTORIA_DOCKER_IMAGE="victoriametrics/victoria-metrics:v1.106.1"
VM_DATA_DIR="/var/lib/victoriametrics"
VM_PORT=8428
VM_RETENTION="30d"
GRAFANA_DATA_DIR="/var/lib/grafana"
GRAFANA_PORT=3000
