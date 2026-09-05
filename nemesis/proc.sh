#!/usr/bin/env bash
# Немезис: управление процессами ydbd через сигналы (kill).
# Используется в тестах 08 (freeze: STOP/CONT) и 09 (kill: SIGKILL).
#
# В режиме --hold после SIGKILL останавливаются управляющие systemd-юниты,
# иначе Restart=always немедленно вернёт процессы. Отдельный teardown запускает
# storage и tenant-юниты обратно.
#
# Базовый API (freeze):
#   nemesis_proc_freeze_apply    <host> <timeout>
#   nemesis_proc_freeze_teardown <host>
#
# Базовый API (kill):
#   nemesis_proc_kill_apply      <host>
#   nemesis_proc_kill_hold_apply <host>
#   nemesis_proc_kill_teardown   <host>
#
# Общее:
#   nemesis_proc_check           <host>
#   nemesis_proc_ydbd_restart    <host>

nemesis_proc_freeze_apply() {
    local host="$1" timeout_s="$2"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}"

    log_chaos_apply "SIGSTOP ydbd (${bin}) на ${host}, авто-CONT через ${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  pgrep ydbd → kill -STOP, sleep ${timeout_s}s → kill -CONT"

    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [ -f /tmp/proc-freeze.pid ]; then
    kill \$(cat /tmp/proc-freeze.pid) 2>/dev/null || true
    rm -f /tmp/proc-freeze.pid
fi
pids=\$(pgrep -f '${bin}' || true)
if [ -z "\${pids}" ]; then echo "ОШИБКА: процессы ydbd не найдены" >&2; exit 1; fi
sudo kill -STOP \${pids}
echo "\${pids}" | tr '\n' ' ' > /tmp/proc-freeze.pids
nohup bash -c "sleep ${timeout_s} && sudo kill -CONT \$(cat /tmp/proc-freeze.pids) 2>/dev/null && rm -f /tmp/proc-freeze.pid /tmp/proc-freeze.pids" >/dev/null 2>&1 &
echo \$! > /tmp/proc-freeze.pid
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc freeze, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_proc_freeze_teardown() {
    local host="$1"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}"
    chaos_term_remote_cmd "ssh ${host}  kill -CONT ydbd + remove timer"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [ -f /tmp/proc-freeze.pid ]; then kill \$(cat /tmp/proc-freeze.pid) 2>/dev/null || true; rm -f /tmp/proc-freeze.pid; fi
pids=\$(pgrep -f '${bin}' || true)
[ -n "\${pids}" ] && sudo kill -CONT \${pids} 2>/dev/null || true
rm -f /tmp/proc-freeze.pids
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc freeze teardown, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_proc_kill_apply() {
    local host="$1"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}"
    log_chaos_apply "SIGKILL ydbd на ${host}"
    chaos_term_remote_cmd "ssh ${host}  pgrep ${bin} → kill -9"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
pids=\$(pgrep -f '${bin}' || true)
if [ -z "\${pids}" ]; then echo "ОШИБКА: процессы ydbd не найдены" >&2; exit 1; fi
sudo kill -9 \${pids}
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc kill, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

_proc_tenants_b64() {
    command -v base64 >/dev/null 2>&1 || {
        echo "Нужен base64 на управляющем хосте" >&2
        return 1
    }
    printf '%s\n' "${YDBD_TENANT_SERVICES[@]}" | base64 -w0 2>/dev/null \
        || printf '%s\n' "${YDBD_TENANT_SERVICES[@]}" | base64 | tr -d '\n'
}

# SIGKILL с удержанием отказа. После аварийного сигнала systemd-юниты явно
# останавливаются, чтобы Restart=always не превратил отказ в секундный всплеск.
nemesis_proc_kill_hold_apply() {
    local host="$1"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}"
    local tenants_b64 remote_env

    [[ -n "${YDBD_STORAGE_SERVICE:-}" ]] || {
        echo "nemesis_proc_kill_hold_apply: задайте YDBD_STORAGE_SERVICE в env." >&2
        return 1
    }
    tenants_b64="$(_proc_tenants_b64)"
    remote_env="$(printf 'export YDBD_BIN=%q STORAGE_SERVICE=%q TENANTS_B64=%q' \
        "${bin}" "${YDBD_STORAGE_SERVICE}" "${tenants_b64}")"

    log_chaos_apply "SIGKILL ydbd на ${host}; удержание отказа через stop systemd-юнитов"
    chaos_term_remote_cmd "ssh ${host}  kill -9 ydbd; systemctl stop tenants+storage"

    local remote_script
    remote_script=$(cat <<'REMOTE'
set -euo pipefail
readarray -t TENANTS < <(printf '%s' "${TENANTS_B64}" | base64 -d | awk 'NF')
pids=$(pgrep -f "${YDBD_BIN}" || true)
if [ -z "${pids}" ]; then echo "ОШИБКА: процессы ydbd не найдены" >&2; exit 1; fi
sudo kill -9 ${pids}
# Unit с Restart=always может успеть перейти в activating. Явный stop отменяет
# дальнейшие автозапуски и оставляет отказ активным до teardown.
if ((${#TENANTS[@]})); then sudo systemctl stop "${TENANTS[@]}"; fi
sudo systemctl stop "${STORAGE_SERVICE}"
printf '%s\n' "${TENANTS[@]}" > /tmp/proc-kill-hold.units
systemctl is-active "${STORAGE_SERVICE}" 2>/dev/null || true
if ((${#TENANTS[@]})); then systemctl is-active "${TENANTS[@]}" 2>/dev/null || true; fi
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc kill hold, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "${remote_env}; bash -s" <<<"${remote_script}"
}

# Идемпотентное восстановление после hold: storage запускается первым, затем
# tenant-процессы. Также подходит как аварийный -D после обычного SIGKILL.
nemesis_proc_kill_teardown() {
    local host="$1"
    local tenants_b64 remote_env

    [[ -n "${YDBD_STORAGE_SERVICE:-}" ]] || {
        echo "nemesis_proc_kill_teardown: задайте YDBD_STORAGE_SERVICE в env." >&2
        return 1
    }
    tenants_b64="$(_proc_tenants_b64)"
    remote_env="$(printf 'export STORAGE_SERVICE=%q TENANTS_B64=%q' \
        "${YDBD_STORAGE_SERVICE}" "${tenants_b64}")"

    chaos_term_remote_cmd "ssh ${host}  systemctl start storage+tenants"
    local remote_script
    remote_script=$(cat <<'REMOTE'
set -euo pipefail
readarray -t TENANTS < <(printf '%s' "${TENANTS_B64}" | base64 -d | awk 'NF')
sudo systemctl reset-failed "${STORAGE_SERVICE}" 2>/dev/null || true
if ((${#TENANTS[@]})); then
    for unit in "${TENANTS[@]}"; do sudo systemctl reset-failed "${unit}" 2>/dev/null || true; done
fi
sudo systemctl start "${STORAGE_SERVICE}"
sleep 3
if ((${#TENANTS[@]})); then sudo systemctl start "${TENANTS[@]}"; fi
rm -f /tmp/proc-kill-hold.units
echo "storage: $(systemctl is-active "${STORAGE_SERVICE}" || true)"
if ((${#TENANTS[@]})); then
    for unit in "${TENANTS[@]}"; do echo "${unit}: $(systemctl is-active "${unit}" || true)"; done
fi
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc kill teardown, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "${remote_env}; bash -s" <<<"${remote_script}"
}

nemesis_proc_check() {
    local host="$1"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}"
    chaos_term_remote_cmd "ssh ${host}  systemctl status storage + pgrep ydbd"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<REMOTE
echo "=== Сервис на ${host} ==="
for svc in kikimr.service ydbd.service; do
    if systemctl cat "\${svc}" >/dev/null 2>&1; then
        systemctl status "\${svc}" --no-pager 2>&1 | head -15 || true
        echo ""
        break
    fi
done
echo "--- процессы ---"
pids=\$(pgrep -f '${bin}' 2>/dev/null || true)
if [ -z "\${pids}" ]; then echo "  нет процессов"; else ps -o pid,stat,pcpu,pmem,etime -p \${pids} 2>/dev/null; fi
REMOTE
}

# Перезапуск storage-юнита YDB через systemctl (имя из YDBD_STORAGE_SERVICE в env.sh).
nemesis_proc_ydbd_restart() {
    local host="$1"
    if [[ -z "${YDBD_STORAGE_SERVICE:-}" ]]; then
        echo "nemesis_proc_ydbd_restart: задайте YDBD_STORAGE_SERVICE в env (см. env.example.sh)." >&2
        return 1
    fi
    local storage_q
    storage_q=$(printf '%q' "${YDBD_STORAGE_SERVICE}")
    log "Перезапуск ${YDBD_STORAGE_SERVICE} на ${host}"
    chaos_term_remote_cmd "ssh ${host}  systemctl restart ${YDBD_STORAGE_SERVICE}"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
sudo systemctl restart ${storage_q}
sleep 3
echo "Статус ${YDBD_STORAGE_SERVICE}: \$(systemctl is-active ${storage_q} || echo inactive)"
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc ydbd restart, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
    log "Перезапуск завершён на ${host}"
}
