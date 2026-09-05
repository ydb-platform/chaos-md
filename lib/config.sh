#!/usr/bin/env bash
# Единая загрузка конфигурации Chaos MD.
#
# env.sh содержит конфигурацию стенда и остаётся обязательным.
# Необязательный env.local.sh загружается после него и может переопределять
# значения, не заставляя хранить секреты и локальные пути в env.sh.
# Для изолированных тестов пути можно переопределить через CHAOS_ENV_FILE и
# CHAOS_LOCAL_ENV_FILE.

chaos_load_env() {
    local repo_dir="${1:?chaos_load_env: не задан корень репозитория}"
    local env_file="${CHAOS_ENV_FILE:-${repo_dir}/env.sh}"
    local local_env_file="${CHAOS_LOCAL_ENV_FILE:-${repo_dir}/env.local.sh}"

    if [[ ! -f "${env_file}" ]]; then
        echo "Не найден файл конфигурации: ${env_file}" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "${env_file}"

    if [[ "${CHAOS_SKIP_LOCAL_ENV:-false}" != "true" && -f "${local_env_file}" ]]; then
        # shellcheck disable=SC1090
        source "${local_env_file}"
    fi
}
