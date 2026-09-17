#!/usr/bin/env bash
# Bootstrap для всех тестов хаоса.
# Подключение:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/init.sh"
#
# До source init.sh тест должен задать TEST_NAME (имя файла без расширения).

if [[ -z "${TEST_NAME:-}" ]]; then
    echo "lib/init.sh: TEST_NAME не задан" >&2
    return 1 2>/dev/null || exit 1
fi

CHAOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAOS_REPO_DIR="$(cd "${CHAOS_LIB_DIR}/.." && pwd)"

# env.sh должен лежать рядом с lib/.
# shellcheck source=../env.sh
source "${CHAOS_REPO_DIR}/env.sh"

# Интерфейсы по хосту, CHAOS_NET_IPV4 / CHAOS_NET_IPV6 (после env).
# shellcheck source=net.sh
source "${CHAOS_LIB_DIR}/net.sh"

# Каталог логов (env.sh уже задал LOG_DIR).
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${TEST_NAME}.log"

# Командная строка запуска — для логов и красивой подсветки в начале.
CHAOS_CMDLINE=("$0" "$@")

# Подключаем компоненты в правильном порядке.
# shellcheck source=term.sh
source "${CHAOS_LIB_DIR}/term.sh"
# shellcheck source=log.sh
source "${CHAOS_LIB_DIR}/log.sh"
# shellcheck source=operation.sh
source "${CHAOS_LIB_DIR}/operation.sh"
# shellcheck source=json.sh
source "${CHAOS_LIB_DIR}/json.sh"
# shellcheck source=grafana.sh
source "${CHAOS_LIB_DIR}/grafana.sh"
# shellcheck source=timeline.sh
source "${CHAOS_LIB_DIR}/timeline.sh"
# shellcheck source=ssh.sh
source "${CHAOS_LIB_DIR}/ssh.sh"
# shellcheck source=ports.sh
source "${CHAOS_LIB_DIR}/ports.sh"
# shellcheck source=util.sh
source "${CHAOS_LIB_DIR}/util.sh"
# shellcheck source=cli.sh
source "${CHAOS_LIB_DIR}/cli.sh"
# shellcheck source=hosts.sh
source "${CHAOS_LIB_DIR}/hosts.sh"
# shellcheck source=test_runner.sh
source "${CHAOS_LIB_DIR}/test_runner.sh"
