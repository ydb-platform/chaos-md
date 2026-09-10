#!/usr/bin/env bash
# SSH port-forwarding туннели к стенду через autossh (с авто-переподключением).
# Читает параметры из env.sh.
#
# Открывает два туннеля:
#   1. Grafana  — localhost:${GRAFANA_PORT:-3000} → ${MON_HOST}:${GRAFANA_PORT:-3000}
#   2. YDB mon  — localhost:${YDB_MON_PD_PORT:-8765} → последняя нода:${YDB_MON_PD_PORT:-8765}
#
# Использование:
#   ./forwards.sh          — открыть туннели
#   ./forwards.sh -k       — закрыть туннели
#   ./forwards.sh -s       — проверить состояние туннелей

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GRAFANA_LOCAL_PORT="${GRAFANA_PORT:-3000}"
MON_PORT="${YDB_MON_PD_PORT:-8765}"
LAST_NODE="${CLUSTER_HOSTS[${#CLUSTER_HOSTS[@]} - 1]}"

# autossh мониторинг-порты (0 = отключить встроенный мониторинг, используем ServerAliveInterval)
AUTOSSH_GRAFANA_MON=0
AUTOSSH_YDB_MON=0

TUNNELS=(
    "grafana|${GRAFANA_LOCAL_PORT}:localhost:${GRAFANA_LOCAL_PORT}|${MON_HOST}|localhost:${GRAFANA_LOCAL_PORT} → ${MON_HOST}:${GRAFANA_LOCAL_PORT}"
    "ydb-mon|${MON_PORT}:${LAST_NODE}:${MON_PORT}|${MON_HOST}|localhost:${MON_PORT} → ${LAST_NODE}:${MON_PORT} (через ${MON_HOST})"
)

is_port_open() {
    local port="$1"
    nc -z localhost "${port}" 2>/dev/null
}

tunnel_pid() {
    local spec="$1"
    pgrep -f "autossh.*-L.*${spec%%:*}:" 2>/dev/null | head -1 || true
}

start_forwards() {
    if ! command -v autossh &>/dev/null; then
        echo "Ошибка: autossh не найден. Установите: brew install autossh" >&2
        exit 1
    fi

    for entry in "${TUNNELS[@]}"; do
        IFS='|' read -r name spec host label <<< "${entry}"
        local pid
        pid=$(tunnel_pid "${spec}")
        if [[ -n "${pid}" ]]; then
            echo "[уже запущен] ${label} (PID ${pid})"
            continue
        fi
        echo "Открываем: ${label}"
        AUTOSSH_PORT=0 autossh -M 0 -f -N \
            -o ServerAliveInterval=30 \
            -o ServerAliveCountMax=3 \
            -o ExitOnForwardFailure=yes \
            -L "${spec}" "${host}"
    done
    echo "Туннели запущены. Проверить: $(basename "$0") -s  Закрыть: $(basename "$0") -k"
}

kill_forwards() {
    local killed=0
    for entry in "${TUNNELS[@]}"; do
        IFS='|' read -r name spec host label <<< "${entry}"
        local pid
        pid=$(tunnel_pid "${spec}")
        if [[ -n "${pid}" ]]; then
            echo "Закрываем PID ${pid}: ${label}"
            kill "${pid}" 2>/dev/null || true
            ((killed++))
        else
            echo "Не запущен: ${label}"
        fi
    done
    echo "Закрыто: ${killed} туннелей"
}

status_forwards() {
    local all_ok=true
    printf "%-10s  %-6s  %-8s  %s\n" "ТУННЕЛЬ" "PID" "ПОРТ" "МАРШРУТ"
    printf '%0.s-' {1..60}; echo
    for entry in "${TUNNELS[@]}"; do
        IFS='|' read -r name spec host label <<< "${entry}"
        local local_port="${spec%%:*}"
        local pid
        pid=$(tunnel_pid "${spec}")
        local pid_str="${pid:--}"
        local port_status="закрыт"
        if is_port_open "${local_port}"; then
            port_status="открыт"
        else
            all_ok=false
        fi
        printf "%-10s  %-6s  %-8s  %s\n" "${name}" "${pid_str}" "${port_status}" "${label}"
    done
    echo
    if ${all_ok}; then
        echo "Все туннели активны."
    else
        echo "Некоторые туннели не отвечают." >&2
        return 1
    fi
}

case "${1:-}" in
    -k) kill_forwards ;;
    -s) status_forwards ;;
    *)  start_forwards ;;
esac
