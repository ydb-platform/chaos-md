#!/usr/bin/env bash
# Идемпотентное изменение числа dynamic YDB nodes для демонстрации эластичности.
# Управляет только явно настроенным tenant service; storage service не трогает.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/config.sh"
chaos_load_env "${REPO_ROOT}"
[[ ! -f "${SCRIPT_DIR}/env.local.sh" ]] || source "${SCRIPT_DIR}/env.local.sh"
source "${REPO_ROOT}/lib/term.sh"
source "${REPO_ROOT}/lib/ssh.sh"
source "${REPO_ROOT}/lib/grafana.sh"

COMMAND="${1:-}"
COUNT="${2:-}"
WAIT_SECONDS="${DYNAMIC_NODE_WAIT_SECONDS:-60}"
COMMAND_TIMEOUT="${DYNAMIC_NODE_COMMAND_TIMEOUT_SECONDS:-20}"
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"

usage() {
    cat <<'EOF'
Использование:
  cluster/dynamic-nodes.sh status
  cluster/dynamic-nodes.sh set COUNT [--wait SEC] [--dry-run]

Нужны DYNAMIC_NODE_HOSTS=(...) и YDBD_DYNAMIC_SERVICE в env.sh/env.local.sh
или в локальном cluster/env.local.sh.
Первые COUNT хостов остаются включёнными, остальные выключаются.
EOF
}

shift $(( $# > 0 ? 1 : 0 ))
[[ "${COMMAND}" != set || $# -eq 0 ]] || shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait) WAIT_SECONDS="${2:?--wait требует SEC}"; shift 2 ;;
        --dry-run|-n) CHAOS_DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "${COMMAND}" == status || "${COMMAND}" == set ]] || { usage; exit 2; }
[[ -n "${YDBD_DYNAMIC_SERVICE:-}" ]] || { echo "YDBD_DYNAMIC_SERVICE не задан" >&2; exit 2; }
[[ "${YDBD_DYNAMIC_SERVICE}" =~ ^[A-Za-z0-9_.@-]+$ ]] || { echo "Недопустимое имя service" >&2; exit 2; }
[[ "${YDBD_DYNAMIC_SERVICE}" != "${YDBD_STORAGE_SERVICE:-}" ]] || {
    echo "Отказ: dynamic service совпадает со storage service" >&2; exit 2;
}
declare -p DYNAMIC_NODE_HOSTS >/dev/null 2>&1 || { echo "DYNAMIC_NODE_HOSTS не задан" >&2; exit 2; }
[[ ${#DYNAMIC_NODE_HOSTS[@]} -gt 0 ]] || { echo "DYNAMIC_NODE_HOSTS пуст" >&2; exit 2; }
[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || { echo "--wait должен быть числом" >&2; exit 2; }
[[ "${COMMAND_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || {
    echo "DYNAMIC_NODE_COMMAND_TIMEOUT_SECONDS должен быть положительным числом" >&2
    exit 2
}

node_active() {
    local host="$1" rc=0
    ssh_run_timeout "${COMMAND_TIMEOUT}" "${host}" \
        sudo systemctl is-active --quiet "${YDBD_DYNAMIC_SERVICE}" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        3) return 1 ;;
        *) echo "Не удалось определить состояние ${host}: rc=${rc}" >&2; return 2 ;;
    esac
}

node_service() {
    local host="$1" action="$2"
    ssh_run_timeout "${COMMAND_TIMEOUT}" "${host}" \
        sudo systemctl "${action}" --no-block "${YDBD_DYNAMIC_SERVICE}"
}

status() {
    local host state rc active=0 unknown=0
    for host in "${DYNAMIC_NODE_HOSTS[@]}"; do
        if node_active "${host}"; then
            state=ACTIVE
            active=$((active + 1))
        else
            rc=$?
            if (( rc == 1 )); then state=STOPPED; else state=UNKNOWN; unknown=$((unknown + 1)); fi
        fi
        printf '%-36s %s\n' "${host}" "${state}"
    done
    echo "active dynamic nodes: ${active}/${#DYNAMIC_NODE_HOSTS[@]}"
    (( unknown == 0 ))
}

annotate() {
    local text="$1" marker="dynamic-nodes"
    mkdir -p "${LOG_DIR:-${REPO_ROOT}/logs}"
    printf '%s  %-16s  %s\n' "$(date -Iseconds)" "CLUSTER_SCALE" "${text}" \
        >>"${LOG_DIR:-${REPO_ROOT}/logs}/timeline.log"
    grafana_region_open "${marker}" "CLUSTER_SCALE  ${text}" control
    grafana_region_close "${marker}"
}

if [[ "${COMMAND}" == status ]]; then
    status
    exit 0
fi

[[ "${COUNT}" =~ ^[0-9]+$ ]] || { echo "COUNT должен быть целым числом" >&2; exit 2; }
(( COUNT >= 1 && COUNT <= ${#DYNAMIC_NODE_HOSTS[@]} )) || {
    echo "COUNT должен быть от 1 до ${#DYNAMIC_NODE_HOSTS[@]}" >&2; exit 2;
}

# Сначала запускаем все целевые процессы. Только после проверки останавливаем
# лишние: это не создаёт искусственного окна без вычислительных узлов.
for ((i=0; i<COUNT; i++)); do
    if [[ "${CHAOS_DRY_RUN}" == true ]]; then
        node_service "${DYNAMIC_NODE_HOSTS[i]}" start
    elif node_active "${DYNAMIC_NODE_HOSTS[i]}"; then
        :
    else
        rc=$?
        (( rc == 1 )) || exit 1
        node_service "${DYNAMIC_NODE_HOSTS[i]}" start
    fi
done

if [[ "${CHAOS_DRY_RUN}" != true ]]; then
    deadline=$(( $(date +%s) + WAIT_SECONDS ))
    for ((i=0; i<COUNT; i++)); do
        until node_active "${DYNAMIC_NODE_HOSTS[i]}"; do
            rc=$?
            (( rc == 1 )) || exit 1
            (( $(date +%s) < deadline )) || {
                echo "Узел ${DYNAMIC_NODE_HOSTS[i]} не запустился за ${WAIT_SECONDS}s" >&2
                exit 1
            }
            sleep 2
        done
    done
fi

for ((i=COUNT; i<${#DYNAMIC_NODE_HOSTS[@]}; i++)); do
    if [[ "${CHAOS_DRY_RUN}" == true ]]; then
        node_service "${DYNAMIC_NODE_HOSTS[i]}" stop
    elif node_active "${DYNAMIC_NODE_HOSTS[i]}"; then
        node_service "${DYNAMIC_NODE_HOSTS[i]}" stop
    else
        rc=$?
        (( rc == 1 )) || exit 1
    fi
done

if [[ "${CHAOS_DRY_RUN}" != true ]]; then
    deadline=$(( $(date +%s) + WAIT_SECONDS ))
    for ((i=COUNT; i<${#DYNAMIC_NODE_HOSTS[@]}; i++)); do
        while true; do
            if node_active "${DYNAMIC_NODE_HOSTS[i]}"; then
                (( $(date +%s) < deadline )) || {
                    echo "Узел ${DYNAMIC_NODE_HOSTS[i]} не остановился за ${WAIT_SECONDS}s" >&2
                    exit 1
                }
                sleep 2
                continue
            else
                rc=$?
                (( rc == 1 )) && break
                exit 1
            fi
        done
    done
fi

if [[ "${CHAOS_DRY_RUN}" != true ]]; then
    annotate "dynamic nodes = ${COUNT}"
fi
status
