#!/usr/bin/env bash
# 02 — Установка node_exporter на ${CLUSTER_HOSTS[@]} как systemd-сервис.
#
# Что делает (параллельно по хостам):
#   1. Скачивает node_exporter v${NODE_EXPORTER_VERSION} с github releases
#      (внутри хоста, не локально). Если уже установлен правильной версии — пропуск.
#   2. Кладёт бинарник в /usr/local/bin/node_exporter, владелец root:root, +x.
#   3. Заводит пользователя node_exporter (--system, без shell).
#   4. Создаёт systemd unit /etc/systemd/system/node_exporter.service.
#   5. systemctl daemon-reload && enable --now node_exporter.
#   6. Проверка: curl localhost:${NODE_EXPORTER_PORT}/metrics | head -1.
#
# Запускать НА ${MON_HOST} ${MON_HOST} — оттуда есть прямой ssh к cluster-хостам.
#
# Опции:
#   --check     Опросить все CLUSTER_HOSTS: статус сервиса + первая строка metrics.
#   --dry-run   Печатать ssh-команды, не выполнять.
#   -h, --help  Справка.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/env.sh"
# shellcheck source=../lib/term.sh
source "${REPO_DIR}/lib/term.sh"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/grafana-02-node-exporter.log"
# shellcheck source=../lib/log.sh
source "${REPO_DIR}/lib/log.sh"
# shellcheck source=../lib/ssh.sh
source "${REPO_DIR}/lib/ssh.sh"
# shellcheck source=../lib/util.sh
source "${REPO_DIR}/lib/util.sh"

MODE_CHECK=false
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"
LOCAL_ARCHIVE=""

usage() {
    cat <<EOF
$(basename "$0") — install node_exporter v${NODE_EXPORTER_VERSION} on cluster hosts.

  --check       Проверка статуса на всех CLUSTER_HOSTS
  --archive F   Локальный архив node_exporter; передать на каждый хост вместо скачивания
  --dry-run     Печатать команды, не выполнять
  -h, --help    Справка

Конфигурация (env.sh):
  CLUSTER_HOSTS=(${CLUSTER_HOSTS[*]})
  NODE_EXPORTER_VERSION=${NODE_EXPORTER_VERSION}
  NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    MODE_CHECK=true; shift ;;
        --archive)  LOCAL_ARCHIVE="$2"; shift 2 ;;
        --dry-run)  CHAOS_DRY_RUN=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -n "${LOCAL_ARCHIVE}" && ! -f "${LOCAL_ARCHIVE}" ]]; then
    echo "Ошибка: локальный архив не найден: ${LOCAL_ARCHIVE}" >&2
    exit 1
fi

NE_VERSION="${NODE_EXPORTER_VERSION}"
NE_PORT="${NODE_EXPORTER_PORT}"

check_host() {
    local host="$1"
    chaos_term_target "${host}"
    chaos_term_remote_cmd "ssh ${host}  systemctl status node_exporter --no-pager | head -5"
    if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
        return 0
    fi
    command ssh "${SSH_OPTS[@]}" "${host}" "
        systemctl is-active node_exporter && echo '  active=ok' || echo '  active=FAIL'
        curl -sf http://localhost:${NE_PORT}/metrics | head -1 || echo '  metrics=FAIL'
    " || true
}

install_host() {
    local host="$1"
    log "[$host] install node_exporter v${NE_VERSION}"
    chaos_term_remote_cmd "ssh ${host} bash -s  # install node_exporter v${NE_VERSION}"
    if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
        return 0
    fi

    local remote_archive=""
    if [[ -n "${LOCAL_ARCHIVE}" ]]; then
        remote_archive="/tmp/node_exporter-${NE_VERSION}.tar.gz"
        command scp "${SSH_OPTS[@]}" "${LOCAL_ARCHIVE}" "${host}:${remote_archive}"
    fi

    # Архитектура определяется на удалённом хосте: архитектура определяется на удалённом хосте (x86_64 / arm64 — вычисляется в скрипте.
    command ssh "${SSH_OPTS[@]}" "${host}" "NE_VER='${NE_VERSION}' NE_PORT='${NE_PORT}' NE_ARCHIVE='${remote_archive}' bash -s" <<'REMOTE'
set -euo pipefail

ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    x86_64)  NE_ARCH=amd64 ;;
    aarch64) NE_ARCH=arm64 ;;
    *) echo "Неизвестная архитектура: ${ARCH_RAW}" >&2; exit 1 ;;
esac

INSTALLED=""
if [ -x /usr/local/bin/node_exporter ]; then
    INSTALLED=$(/usr/local/bin/node_exporter --version 2>&1 | head -1 | awk '{print $3}' || true)
fi

if [ "${INSTALLED}" = "${NE_VER}" ] && systemctl is-active --quiet node_exporter 2>/dev/null; then
    echo "  node_exporter ${NE_VER} уже установлен и запущен — пропуск"
    exit 0
fi

# Пользователь
if ! id -u node_exporter >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
fi

# Получить архив: локально переданный архив нужен изолированным от интернета стендам.
TMPD=$(mktemp -d)
trap 'rm -rf "${TMPD}"' EXIT
if [ -n "${NE_ARCHIVE:-}" ] && [ -f "${NE_ARCHIVE}" ]; then
    echo "  install from ${NE_ARCHIVE}"
    cp "${NE_ARCHIVE}" "${TMPD}/ne.tar.gz"
    rm -f "${NE_ARCHIVE}"
else
    URL="https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.linux-${NE_ARCH}.tar.gz"
    echo "  download ${URL}"
    curl -fsSL "${URL}" -o "${TMPD}/ne.tar.gz"
fi
tar -xzf "${TMPD}/ne.tar.gz" -C "${TMPD}"
sudo install -o root -g root -m 0755 "${TMPD}/node_exporter-${NE_VER}.linux-${NE_ARCH}/node_exporter" /usr/local/bin/node_exporter

# systemd unit
sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<UNIT
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:${NE_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
sleep 1
systemctl is-active --quiet node_exporter && echo "  node_exporter ${NE_VER} активен на :${NE_PORT}"
REMOTE
}

if [[ "${MODE_CHECK}" == "true" ]]; then
    log_section "Проверка node_exporter на CLUSTER_HOSTS"
    for h in "${CLUSTER_HOSTS[@]}"; do
        check_host "${h}"
    done
    exit 0
fi

log_section "Установка node_exporter v${NE_VERSION} на ${#CLUSTER_HOSTS[@]} хостах"
parallel_for_hosts install_host "${CLUSTER_HOSTS[@]}"
log_section "Готово"
