#!/usr/bin/env bash
# SSH port-forwarding туннели к стенду.
# Читает параметры из env.sh.
#
# Открывает два туннеля:
#   1. Grafana  — localhost:${GRAFANA_PORT:-3000} → ${MON_HOST}:${GRAFANA_PORT:-3000}
#   2. YDB mon  — localhost:${YDB_MON_PD_PORT:-8765} → последняя нода:${YDB_MON_PD_PORT:-8765} (порт мониторинга узла хранения)
#
# Использование:
#   ./all-forwards.sh        — открыть туннели
#   ./all-forwards.sh -k     — закрыть туннели

echo -e "\033[1;31m[DEPRECATED] all-forwards.sh устарел. Используйте forwards.sh\033[0m" >&2

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GRAFANA_LOCAL_PORT="${GRAFANA_PORT:-3000}"
MON_PORT="${YDB_MON_PD_PORT:-8765}"

# Последняя нода кластера как репрезентативная точка.
LAST_NODE="${CLUSTER_HOSTS[${#CLUSTER_HOSTS[@]} - 1]}"

SLEEP_CMD="sleep infinity"

start_forwards() {
    echo "Grafana:  localhost:${GRAFANA_LOCAL_PORT} → ${MON_HOST}:${GRAFANA_LOCAL_PORT}"
    ssh -fNL "${GRAFANA_LOCAL_PORT}:localhost:${GRAFANA_LOCAL_PORT}" "${MON_HOST}" ${SLEEP_CMD} &

    echo "YDB mon:  localhost:${MON_PORT} → ${LAST_NODE}:${MON_PORT}  (через ${MON_HOST})"
    ssh -fNL "${MON_PORT}:${LAST_NODE}:${MON_PORT}" "${MON_HOST}" ${SLEEP_CMD} &

    echo "Туннели открыты. Для закрытия: $(basename "$0") -k"
}

kill_forwards() {
    local killed=0
    local pattern
    for pattern in \
        "${GRAFANA_LOCAL_PORT}:localhost:${GRAFANA_LOCAL_PORT} ${MON_HOST}" \
        "${MON_PORT}:${LAST_NODE}:${MON_PORT} ${MON_HOST}"
    do
        local pid
        pid=$(pgrep -f "ssh.*-fNL.*${pattern%%' '*}" 2>/dev/null || true)
        if [[ -n "${pid}" ]]; then
            echo "Закрываем PID ${pid}: ${pattern}"
            kill "${pid}" 2>/dev/null || true
            ((killed++))
        else
            echo "Не найдено: ${pattern}"
        fi
    done
    echo "Закрыто: ${killed} туннелей"
}

if [[ "${1:-}" == "-k" ]]; then
    kill_forwards
else
    start_forwards
fi
