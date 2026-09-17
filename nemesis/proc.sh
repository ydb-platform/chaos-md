#!/usr/bin/env bash
# Немезис: управление процессами ydbd через сигналы (kill).
# Используется в тестах 08 (freeze: STOP/CONT) и 09 (kill: SIGKILL).
#
# Восстановление после SIGKILL (тест 09) — отдельная операция:
# nemesis_proc_ydbd_restart: systemctl restart юнита из YDBD_STORAGE_SERVICE (env).
#
# Базовый API (freeze):
#   nemesis_proc_freeze_apply    <host> <timeout>
#   nemesis_proc_freeze_teardown <host>
#
# Базовый API (kill):
#   nemesis_proc_kill_apply      <host>
#
# Общее:
#   nemesis_proc_check           <host>
#   nemesis_proc_ydbd_restart    <host>

nemesis_proc_freeze_apply() {
    local host="$1" timeout_s="$2"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}" bin_q
    printf -v bin_q '%q' "${bin}"
    [[ "${timeout_s}" =~ ^[1-9][0-9]*$ ]] || return 1

    log_chaos_apply "SIGSTOP ydbd (${bin}) на ${host}, авто-CONT через ${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  pgrep ydbd → kill -STOP, sleep ${timeout_s}s → kill -CONT"

    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [ -f /tmp/proc-freeze.pid ]; then
    kill \$(cat /tmp/proc-freeze.pid) 2>/dev/null || true
    rm -f /tmp/proc-freeze.pid
fi
pids=\$(pgrep -f -- ${bin_q} || true)
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
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}" bin_q
    printf -v bin_q '%q' "${bin}"
    chaos_term_remote_cmd "ssh ${host}  kill -CONT ydbd + remove timer"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [ -f /tmp/proc-freeze.pid ]; then kill \$(cat /tmp/proc-freeze.pid) 2>/dev/null || true; rm -f /tmp/proc-freeze.pid; fi
pids=\$(pgrep -f -- ${bin_q} || true)
[ -n "\${pids}" ] && sudo kill -CONT \${pids} 2>/dev/null || true
rm -f /tmp/proc-freeze.pids
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc freeze teardown, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_proc_kill_apply() {
    local host="$1"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}" bin_q
    printf -v bin_q '%q' "${bin}"
    log_chaos_apply "SIGKILL ydbd на ${host}"
    chaos_term_remote_cmd "ssh ${host}  pgrep ${bin} → kill -9"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
pids=\$(pgrep -f -- ${bin_q} || true)
if [ -z "\${pids}" ]; then echo "ОШИБКА: процессы ydbd не найдены" >&2; exit 1; fi
sudo kill -9 \${pids}
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт proc kill, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_proc_check() {
    local host="$1"
    local bin="${YDBD_BIN:-/opt/ydb/bin/ydbd}" bin_q
    printf -v bin_q '%q' "${bin}"
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
pids=\$(pgrep -f -- ${bin_q} 2>/dev/null || true)
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
