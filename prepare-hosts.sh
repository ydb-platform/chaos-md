#!/usr/bin/env bash
# Разовая подготовка нод кластера под хаос-тесты (после поднятия стенда).
# Вызывать с машины, откуда есть SSH до CLUSTER_HOSTS (как у тестов).
#
# По умолчанию хосты обрабатываются по одному (наглядные логи); см. --parallel.
#   • пакеты: hping3, gdisk (sgdisk), iproute2/ss (tc), iptables (если есть в репозитории);
#   • ChaosBlade: архив в ~/dist/, распаковка, симлинк ~/blade -> …/chaosblade-*/blade;
#   • дистрибутив для теста 10 (rolling upgrade): копия в ~/ как у 10-rolling-upgrade.sh.
#
# Опции отключают шаги. Логи — logs/prepare-hosts.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAME="prepare-hosts"

PREP_NO_BLADE=false
PREP_NO_PKGS=false
PREP_NO_UPGRADE_DIST=false
PREP_PARALLEL=false
BLADE_FILE_OVERRIDE=""
PREP_UPGRADE_FILE_OVERRIDE=""
PREP_SINGLE_HOST=""

usage() {
    cat <<EOF
Использование: $(basename "$0") [ОПЦИИ]

Подготовка хостов к сетевым тестам, Blade, дисковому тесту (sgdisk) и rolling upgrade.

Опции:
  --no-blade          Не ставить ChaosBlade
  --no-packages       Не ставить пакеты (hping3, gdisk, iproute2, …)
  --no-upgrade-dist   Не копировать архив ydbd для теста 10 на хосты
  --parallel          Готовить хосты параллельно (по умолчанию — по одному, нагляднее в логе)
  -f, --file PATH     Архив ChaosBlade (по умолчанию: dist/ или корень репозитория)
  -F, --upgrade-file PATH   Явный путь к архиву rolling upgrade (иначе ROLLING_UPGRADE_DIST)
  -H, --host HOST     Только этот хост (вместо всего CLUSTER_HOSTS)
  -h, --help          Справка

Примеры:
  $(basename "$0")
  $(basename "$0") --no-blade
  $(basename "$0") -f ./dist/chaosblade-1.8.0-linux_amd64.tar.gz
  $(basename "$0") -H ydb-node-01.example.com -F ~/dist/ydbd-nightly.tar.xz
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-blade)        PREP_NO_BLADE=true; shift ;;
        --no-packages)     PREP_NO_PKGS=true; shift ;;
        --no-upgrade-dist) PREP_NO_UPGRADE_DIST=true; shift ;;
        --parallel)       PREP_PARALLEL=true; shift ;;
        -f|--file)        BLADE_FILE_OVERRIDE="$2"; shift 2 ;;
        -F|--upgrade-file) PREP_UPGRADE_FILE_OVERRIDE="$2"; shift 2 ;;
        -H|--host)        PREP_SINGLE_HOST="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"
# shellcheck source=lib/blade_install.sh
source "${SCRIPT_DIR}/lib/blade_install.sh"

PREP_HOSTS=("${CLUSTER_HOSTS[@]}")
if [[ -n "${PREP_SINGLE_HOST}" ]]; then
    PREP_HOSTS=("${PREP_SINGLE_HOST}")
fi

if [[ ${#PREP_HOSTS[@]} -eq 0 ]]; then
    echo "prepare-hosts: ОШИБКА: список хостов пуст (CLUSTER_HOSTS в env.sh или используйте -H HOST)." >&2
    echo "  Задайте массив CLUSTER_HOSTS=( node1 node2 … ) или запустите: $0 -H <имя_ноды>" >&2
    exit 2
fi

_prep_hosts_ok=()
for _h in "${PREP_HOSTS[@]}"; do
    _h="${_h#"${_h%%[![:space:]]*}"}"
    _h="${_h%"${_h##*[![:space:]]}"}"
    if [[ -n "${_h}" ]]; then
        _prep_hosts_ok+=("${_h}")
    fi
done
if [[ ${#_prep_hosts_ok[@]} -eq 0 ]]; then
    echo "prepare-hosts: ОШИБКА: после обрезки пробелов не осталось ни одного имени хоста." >&2
    exit 2
fi
PREP_HOSTS=("${_prep_hosts_ok[@]}")
unset _h _prep_hosts_ok

BLADE_LOCAL="${BLADE_FILE_OVERRIDE}"
if [[ -z "${BLADE_LOCAL}" ]]; then
    BLADE_LOCAL="$(blade_default_archive_path "${SCRIPT_DIR}")"
fi

if [[ "${PREP_NO_BLADE}" == false && ! -f "${BLADE_LOCAL}" ]]; then
    echo "prepare-hosts: ОШИБКА: архив ChaosBlade не найден: ${BLADE_LOCAL}" >&2
    echo "  Укажите путь: $0 -f /path/to/chaosblade-…-linux_amd64.tar.gz" >&2
    echo "  или положите tarball в dist/ (имя по умолчанию или chaosblade-*linux*.tar.gz), либо --no-blade" >&2
    exit 1
fi

UPGRADE_DIST_LOCAL="${PREP_UPGRADE_FILE_OVERRIDE:-${ROLLING_UPGRADE_DIST:-${SCRIPT_DIR}/dist/ydbd-package.tar.xz}}"
UPGRADE_DIST_NAME="$(basename "${UPGRADE_DIST_LOCAL}")"

_prepare_packages() {
    local host="$1"
    log "[${host}] пакеты (apt/dnf/yum): hping3, gdisk, tc, iptables"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<'REMOTE'
set -euo pipefail
echo "prepare-hosts: установка пакетов на $(hostname -f 2>/dev/null || hostname) ..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y iproute2 iptables gdisk hping3 \
        || sudo apt-get install -y iproute iptables gdisk hping3 \
        || {
            sudo apt-get install -y gdisk hping3 || true
            sudo apt-get install -y iproute2 || sudo apt-get install -y iproute || true
            sudo apt-get install -y iptables || true
        }
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y iproute iptables gdisk hping3 || sudo dnf install -y gdisk hping3 || true
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y iproute iptables gdisk hping3 || sudo yum install -y gdisk hping3 || true
else
    echo "ПРЕДУПРЕЖДЕНИЕ: не найден apt-get/dnf/yum — пакеты не ставились" >&2
fi
command -v hping3 >/dev/null 2>&1 && echo "hping3: ok" || echo "ПРЕДУПРЕЖДЕНИЕ: hping3 не найден"
command -v sgdisk >/dev/null 2>&1 && echo "sgdisk: ok" || echo "ПРЕДУПРЕЖДЕНИЕ: sgdisk не найден"
command -v tc >/dev/null 2>&1 && echo "tc: ok" || echo "ПРЕДУПРЕЖДЕНИЕ: tc не найден"
REMOTE
}

_prepare_blade() {
    local host="$1"
    if [[ ! -f "${BLADE_LOCAL}" ]]; then
        log "[${host}] ChaosBlade: пропуск — нет архива: ${BLADE_LOCAL}"
        return 1
    fi
    log "[${host}] ChaosBlade: ${BLADE_LOCAL}"
    blade_install_on_host "${host}" "${BLADE_LOCAL}"
}

_prepare_upgrade_dist() {
    local host="$1"
    if [[ ! -f "${UPGRADE_DIST_LOCAL}" ]]; then
        log "[${host}] rolling-upgrade dist: пропуск — нет файла ${UPGRADE_DIST_LOCAL}"
        return 0
    fi
    local local_size remote_size
    local_size=$(wc -c < "${UPGRADE_DIST_LOCAL}" | tr -d ' ')
    chaos_term_remote_cmd "ssh ${host}  wc -c ~/${UPGRADE_DIST_NAME}"
    remote_size=$(ssh "${SSH_OPTS[@]}" "${host}" "[ -f ~/${UPGRADE_DIST_NAME} ] && wc -c < ~/${UPGRADE_DIST_NAME} | tr -d ' ' || echo 0")
    if [[ "${remote_size}" != "${local_size}" ]]; then
        log "[${host}] копирование ${UPGRADE_DIST_NAME} (local=${local_size}, remote=${remote_size:-0})"
        ssh_scp_to "${host}" "${UPGRADE_DIST_LOCAL}" "~/${UPGRADE_DIST_NAME}"
    else
        log "[${host}] ${UPGRADE_DIST_NAME} уже на хосте (${local_size} байт)"
    fi
}

_prepare_one_host() {
    local host="$1"
    log_section "${host}"
    [[ "${PREP_NO_PKGS}" == false ]] && _prepare_packages "${host}"
    [[ "${PREP_NO_BLADE}" == false ]] && _prepare_blade "${host}"
    [[ "${PREP_NO_UPGRADE_DIST}" == false ]] && _prepare_upgrade_dist "${host}"
    log "[${host}] готово"
}

log_section "prepare-hosts: ${#PREP_HOSTS[@]} хостов"
log "Хосты: ${PREP_HOSTS[*]}"
log "Режим: $([[ "${PREP_PARALLEL}" == true ]] && echo параллельно || echo последовательно)"
log "Опции: no_pkg=${PREP_NO_PKGS} no_blade=${PREP_NO_BLADE} no_upg=${PREP_NO_UPGRADE_DIST}"
log "Blade архив: ${BLADE_LOCAL}"
log "Rolling dist: ${UPGRADE_DIST_LOCAL}"

failed=0
if [[ "${PREP_PARALLEL}" == true ]]; then
    pids=()
    for host in "${PREP_HOSTS[@]}"; do
        _prepare_one_host "${host}" &
        pids+=($!)
    done
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            log "ОШИБКА: ${PREP_HOSTS[$i]}"
            failed=$((failed + 1))
        fi
    done
else
    for host in "${PREP_HOSTS[@]}"; do
        if ! _prepare_one_host "${host}"; then
            log "ОШИБКА: ${host}"
            failed=$((failed + 1))
        fi
    done
fi

if [[ "${failed}" -gt 0 ]]; then
    log_section "prepare-hosts завершён с ошибками (${failed})"
    exit 1
fi
log_section "prepare-hosts успешно"
