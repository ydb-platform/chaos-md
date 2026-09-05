#!/usr/bin/env bash
# Унифицированный запуск команд по SSH с подсветкой того, что выполняется
# на удалённом хосте. Все обёртки печатают на stderr ярко-жёлтую строку
# вида "→  ssh <host>  <команда>" перед фактическим запуском.
#
# Dry-run: при CHAOS_DRY_RUN=true (флаг -N|--dry-run у тестов) ssh и scp
# становятся no-op'ами — подсветка показывает, что бы выполнилось, но удалённое
# воздействие не происходит. Используется для отладки.

# Перехват ssh: в dry-run возвращается 0 без выполнения, иначе — обычный ssh.
# Heredoc на stdin закроется автоматически при возврате из функции.
ssh() {
    if [[ "${CHAOS_DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    command ssh "$@"
}

# Перехват scp: аналогично.
scp() {
    if [[ "${CHAOS_DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    command scp "$@"
}

# Запустить простую команду на одном хосте.
# Использование: ssh_run <host> <cmd ...>
ssh_run() {
    local host="$1"; shift
    chaos_term_remote_cmd "ssh ${host}  $*"
    ssh "${SSH_OPTS[@]}" "${host}" "$@"
}

# Run a short control-plane command with a hard client-side deadline. The
# regular ssh_run remains unchanged for long-running commands and backward
# compatibility.
ssh_run_timeout() {
    local seconds="$1" host="$2" ssh_binary
    shift 2
    [[ "${seconds}" =~ ^[1-9][0-9]*$ ]] || {
        echo "ssh_run_timeout: timeout must be a positive integer" >&2
        return 2
    }
    chaos_term_remote_cmd "ssh ${host}  $*  # timeout ${seconds}s"
    if [[ "${CHAOS_DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    ssh_binary="$(type -P ssh)"
    [[ -n "${ssh_binary}" ]] || { echo "ssh binary not found" >&2; return 127; }
    timeout --foreground "${seconds}s" "${ssh_binary}" "${SSH_OPTS[@]}" "${host}" "$@"
}

# Запустить heredoc-скрипт на удалённом хосте через bash -s.
# Использование: ssh_run_script <host> <описание> <<'REMOTE'
#   ... тело скрипта ...
# REMOTE
# Описание печатается в подсветке, чтобы было ясно, что выполняется удалённо
# (сам скрипт может быть длинным; описание — короткая суть).
ssh_run_script() {
    local host="$1" desc="$2"
    chaos_term_remote_cmd "ssh ${host} bash -s  # ${desc}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s"
}

# То же что ssh_run_script, но позволяет передать переменные через env.
# Использование: ssh_run_script_env <host> <описание> <env_string> <<'REMOTE' ...
# env_string — строка вида: 'export KEY=value KEY2=value2;'
ssh_run_script_env() {
    local host="$1" desc="$2" env_str="$3"
    chaos_term_remote_cmd "ssh ${host} bash -s  # ${desc}"
    ssh "${SSH_OPTS[@]}" "${host}" "${env_str}; bash -s"
}

# scp файла на хост.
# Использование: ssh_scp_to <host> <local_path> <remote_path>
ssh_scp_to() {
    local host="$1" src="$2" dst="$3"
    chaos_term_remote_cmd "scp ${src} → ${host}:${dst}"
    scp "${SSH_OPTS[@]}" "${src}" "${host}:${dst}"
}
