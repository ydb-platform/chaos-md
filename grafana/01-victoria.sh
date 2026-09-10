#!/usr/bin/env bash
# 01 — Установка VictoriaMetrics (single-binary) в Docker на ${MON_HOST}.
#
# Что делает:
#   1. Создаёт каталоги данных и конфигов.
#   2. Записывает статический grafana/scrape.yml в /etc/victoriametrics/scrape.yml
#      и генерирует файлы таргетов:
#        /etc/prometheus/node-exporter.yml — cluster hosts:NODE_EXPORTER_PORT
#        /etc/prometheus/ydbd-mon.yml      — все CLUSTER_HOSTS × каждый порт из YDB_MON_PORTS
#        /etc/prometheus/ydbd-storage.yml  — все хосты × YDB_MON_PD_PORT (порт мониторинга узла хранения, pdisks/vdisks)
#   3. Запускает контейнер ${VICTORIA_DOCKER_IMAGE} с --network host.
#
# Запускать НА ${MON_HOST} ${MON_HOST}. FQDN рабочих хостов резолвятся внутри лаба.
#
# Опции:
#   --check     Показать состояние контейнера и доступность ${VM_PORT}.
#   --dry-run   Печатать команды, не выполнять.
#   -h, --help  Эта справка.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/env.sh"

# shellcheck source=../lib/term.sh
source "${REPO_DIR}/lib/term.sh"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/grafana-01-victoria.log"
# shellcheck source=../lib/log.sh
source "${REPO_DIR}/lib/log.sh"

MODE_CHECK=false
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"

PROM_CFG_DIR="/etc/prometheus"
SCRAPE_CFG="/etc/victoriametrics/scrape.yml"
SCRAPE_SRC="${SCRIPT_DIR}/scrape.yml"

usage() {
    cat <<EOF
$(basename "$0") — install VictoriaMetrics (single) on ${MON_HOST}.

  --check       Показать статус контейнера и доступность http://localhost:${VM_PORT}/-/ready
  --dry-run     Печатать команды, не выполнять
  -h, --help    Справка

Конфигурация (env.sh):
  MON_HOST=${MON_HOST}
  VICTORIA_DOCKER_IMAGE=${VICTORIA_DOCKER_IMAGE}
  VM_DATA_DIR=${VM_DATA_DIR}
  VM_PORT=${VM_PORT}
  VM_RETENTION=${VM_RETENTION}
  Cluster hosts (${#CLUSTER_HOSTS[@]}): ${CLUSTER_HOSTS[*]}
    YDB_MON_PORTS:   ${YDB_MON_PORTS}
    YDB_MON_PD_PORT: ${YDB_MON_PD_PORT} (порт мониторинга узла хранения, pdisks/vdisks)
    node_exporter:   ${NODE_EXPORTER_PORT}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    MODE_CHECK=true; shift ;;
        --dry-run)  CHAOS_DRY_RUN=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

run_cmd() {
    chaos_term_remote_cmd "$*"
    if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
        return 0
    fi
    eval "$@"
}

if [[ "${MODE_CHECK}" == "true" ]]; then
    log_section "Проверка VictoriaMetrics на ${MON_HOST}"
    run_cmd "docker ps --filter name=^vm$ --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'"
    run_cmd "curl -sf http://localhost:${VM_PORT}/-/ready && echo '  ready=ok' || echo '  ready=FAIL'"
    run_cmd "curl -sf 'http://localhost:${VM_PORT}/api/v1/targets?state=unhealthy' | jq . 2>/dev/null | head -40 || true"
    exit 0
fi

log_section "Установка VictoriaMetrics на ${MON_HOST}"
log "Образ: ${VICTORIA_DOCKER_IMAGE}, retention: ${VM_RETENTION}, port: ${VM_PORT}"
log "Хосты (${#CLUSTER_HOSTS[@]}): ${CLUSTER_HOSTS[*]}"
log "YDB mon: YDB_MON_PORTS=${YDB_MON_PORTS}, pdisks/vdisks: YDB_MON_PD_PORT=${YDB_MON_PD_PORT}"

# Сгенерировать файл таргетов в формате file_sd_configs (одна группа).
build_targets_yml() {
    local port="$1" container_label="$2"
    echo "- targets:"
    local h
    for h in "${CLUSTER_HOSTS[@]}"; do
        printf '    - %s:%s\n' "${h}" "${port}"
    done
    cat <<EOF
  labels:
    container: ${container_label}
    database: ${YDB_DATABASE:-/Root/db1}
EOF
}

# Несколько групп: каждый порт из YDB_MON_PORTS × все хосты (см. grafana/scrape.yml → ydbd-mon.yml).
build_ydbd_mon_yml() {
    local p h container raw
    local -a _ports_arr=()
    IFS=',' read -ra _ports_arr <<< "${YDB_MON_PORTS// /}"
    for raw in "${_ports_arr[@]}"; do
        p="${raw// /}"
        [[ -z "${p}" ]] && continue
        if [[ "${p}" == "8765" ]]; then
            container="ydb-static"
        else
            container="ydb-dynamic"
        fi
        echo "- targets:"
        for h in "${CLUSTER_HOSTS[@]}"; do
            printf '    - %s:%s\n' "${h}" "${p}"
        done
        cat <<EOF
  labels:
    container: ${container}
    mon_port: "${p}"
    database: ${YDB_DATABASE:-/Root/db1}
EOF
    done
}

# Только YDB_MON_PD_PORT (порт мониторинга узла хранения) — job'ы pdisks/vdisks в scrape.yml.
build_ydbd_pd_yml() {
    local port="${YDB_MON_PD_PORT}" h
    echo "- targets:"
    for h in "${CLUSTER_HOSTS[@]}"; do
        printf '    - %s:%s\n' "${h}" "${port}"
    done
    cat <<EOF
  labels:
    container: ydb-static
    mon_port: "${port}"
    database: ${YDB_DATABASE:-/Root/db1}
EOF
}

if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
    chaos_term_remote_cmd "sudo mkdir -p $(dirname "${SCRAPE_CFG}") ${PROM_CFG_DIR} ${VM_DATA_DIR}"
    log "  --- dry-run node-exporter.yml ---"
    build_targets_yml "${NODE_EXPORTER_PORT}" "node" | sed 's/^/  | /'
    log "  --- dry-run ydbd-mon.yml ---"
    build_ydbd_mon_yml | sed 's/^/  | /'
    log "  --- dry-run ydbd-storage.yml (pdisks/vdisks, YDB_MON_PD_PORT=${YDB_MON_PD_PORT}) ---"
    build_ydbd_pd_yml | sed 's/^/  | /'
else
    sudo mkdir -p "$(dirname "${SCRAPE_CFG}")" "${PROM_CFG_DIR}" "${VM_DATA_DIR}"

    sudo cp "${SCRAPE_SRC}" "${SCRAPE_CFG}"
    log "  ${SCRAPE_CFG} скопирован из ${SCRAPE_SRC}"

    build_targets_yml "${NODE_EXPORTER_PORT}" "node" | sudo tee "${PROM_CFG_DIR}/node-exporter.yml" >/dev/null
    build_ydbd_mon_yml | sudo tee "${PROM_CFG_DIR}/ydbd-mon.yml" >/dev/null
    build_ydbd_pd_yml  | sudo tee "${PROM_CFG_DIR}/ydbd-storage.yml" >/dev/null
    log "  Файлы таргетов записаны в ${PROM_CFG_DIR}/ (ydbd-mon.yml: ${YDB_MON_PORTS})"
fi

# --network host: доступ к node_exporter и ydb по FQDN из лаб-сети.
# /etc/prometheus монтируется для file_sd_configs из scrape.yml.
log "Запуск контейнера vm"
run_cmd "docker rm -f vm 2>/dev/null || true"
run_cmd "docker run -d --name vm --restart unless-stopped \
    --network host \
    -v ${VM_DATA_DIR}:/victoria-metrics-data \
    -v ${SCRAPE_CFG}:/etc/scrape.yml:ro \
    -v ${PROM_CFG_DIR}:${PROM_CFG_DIR}:ro \
    ${VICTORIA_DOCKER_IMAGE} \
    -storageDataPath=/victoria-metrics-data \
    -httpListenAddr=:${VM_PORT} \
    -retentionPeriod=${VM_RETENTION} \
    -promscrape.config=/etc/scrape.yml"

if [[ "${CHAOS_DRY_RUN}" != "true" ]]; then
    sleep 2
    if curl -sf "http://localhost:${VM_PORT}/-/ready" >/dev/null; then
        log "✓ VictoriaMetrics готов на http://${MON_HOST}:${VM_PORT}"
    else
        log "ПРЕДУПРЕЖДЕНИЕ: /-/ready пока недоступен. Проверьте: docker logs vm"
    fi
fi

log_section "Готово"
