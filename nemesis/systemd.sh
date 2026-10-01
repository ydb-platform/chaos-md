#!/usr/bin/env bash
# Немезис: управление systemd-юнитами ydbd (storage + tenant).
# Используется в:
#   - тесте 12: остановка с авто-стартом по таймеру + явный teardown;
#   - тесте 10: rolling upgrade бинарника ydbd с автооткатом;
#   - rolling-restart.sh: последовательный перезапуск всех нод кластера.
#
# Список tenant-юнитов берётся из YDBD_TENANT_SERVICES (env.sh).
# Stop: tenant → storage. Start: storage → sleep 3 → tenant.
#
# ============================================================================
# 1) Остановка ydbd-юнитов с авто-стартом по таймеру (тест 12)
# ============================================================================
#   nemesis_systemd_stop_apply        <host> <timeout>
#   nemesis_systemd_stop_teardown     <host>
#   nemesis_systemd_stop_apply_all    <hosts...>
#   nemesis_systemd_stop_teardown_all <hosts...>
#
# ============================================================================
# 2) Rolling restart кластера (rolling-restart.sh)
# ============================================================================
#   nemesis_systemd_rolling_restart   <host> <idx> <total>
#
# ============================================================================
# 3) Rolling upgrade бинарника (тест 10)
# ============================================================================
#   nemesis_systemd_upgrade_svc_stop      <host>
#   nemesis_systemd_upgrade_svc_start     <host>
#   nemesis_systemd_upgrade_backup        <host>  # globals: YDBD_BIN, BACKUP_FILE
#   nemesis_systemd_upgrade_extract       <host> <ydbd_path_in_archive>
#   nemesis_systemd_upgrade_place         <host>
#   nemesis_systemd_upgrade_restore       <host>
#   nemesis_systemd_upgrade_arm_timer     <host>  # globals: TIMEOUT, YDBD_BIN, BACKUP_FILE
#   nemesis_systemd_upgrade_disarm_timer  <host>
#   nemesis_systemd_upgrade_check         <host>
#
# Общая проверка состояния юнитов:
#   nemesis_systemd_check                 <host>

# Общий хелпер: статус ydbd/kikimr-юнитов на хосте.
nemesis_systemd_check() {
    local host="$1"
    chaos_term_remote_cmd "ssh ${host}  systemctl list-units --type=service kikimr|ydbd"
    ssh "${SSH_OPTS[@]}" "${host}" \
        "systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -E 'kikimr|ydbd' || true"
}

# ----------------------------------------------------------------------------
# 1) Тест 12: stop с авто-стартом по таймеру.
# ----------------------------------------------------------------------------

_systemd_tenants_b64() {
    if command -v base64 >/dev/null 2>&1; then
        printf '%s\n' "${YDBD_TENANT_SERVICES[@]}" | base64 -w0 2>/dev/null \
            || printf '%s\n' "${YDBD_TENANT_SERVICES[@]}" | base64 | tr -d '\n'
    else
        echo "Нужен base64 на управляющем хосте" >&2
        exit 1
    fi
}

nemesis_systemd_stop_apply() {
    local host="$1" timeout_s="$2"
    local _t64 _env
    _t64="$(_systemd_tenants_b64)"
    _env="$(printf 'export CHAOS_SLEEP=%q TENANTS_B64=%q STORAGE_SERVICE=%q' \
                "${timeout_s}" "${_t64}" "${YDBD_STORAGE_SERVICE}")"

    log_chaos_apply "Остановка ydbd-юнитов на ${host} (storage + ${#YDBD_TENANT_SERVICES[@]} tenant), авто-старт через ${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  systemctl stop tenants+storage; nohup sleep ${timeout_s} && systemctl start"

    local remote_script
    remote_script=$(cat <<'REMOTE'
set -euo pipefail
readarray -t TENANTS < <(printf '%s' "${TENANTS_B64}" | base64 -d)
printf '%s\n' "${TENANTS[@]}" > /tmp/svc-chaos.units
if ((${#TENANTS[@]})); then
    sudo systemctl stop "${TENANTS[@]}"
fi
sudo systemctl stop "${STORAGE_SERVICE}"
cat > /tmp/svc-chaos-recover.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
trap 'rm -f /tmp/svc-chaos.pid /tmp/svc-chaos.units /tmp/svc-chaos-recover.sh' EXIT
sleep "${CHAOS_SLEEP}"
readarray -t _u < <(awk 'NF' /tmp/svc-chaos.units 2>/dev/null || true)
sudo systemctl reset-failed "${STORAGE_SERVICE}" 2>/dev/null || true
if ((${#_u[@]})); then
    for _x in "${_u[@]}"; do sudo systemctl reset-failed "${_x}" 2>/dev/null || true; done
fi
sudo systemctl start "${STORAGE_SERVICE}"
sleep 3
if ((${#_u[@]})); then sudo systemctl start "${_u[@]}"; fi
EOS
chmod +x /tmp/svc-chaos-recover.sh
nohup /tmp/svc-chaos-recover.sh >/dev/null 2>&1 &
_rec_pid=$!
disown -h "${_rec_pid}" 2>/dev/null || disown 2>/dev/null || true
echo "${_rec_pid}" > /tmp/svc-chaos.pid
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт systemd stop+timer, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "${_env}; bash -s" <<<"${remote_script}"
}

nemesis_systemd_stop_teardown() {
    local host="$1"
    local _t64 _env
    _t64="$(_systemd_tenants_b64)"
    _env="$(printf 'export TENANTS_B64=%q STORAGE_SERVICE=%q' "${_t64}" "${YDBD_STORAGE_SERVICE}")"
    chaos_term_remote_cmd "ssh ${host}  kill bg-timer; systemctl reset-failed; systemctl start storage+tenants"
    local remote_script
    remote_script=$(cat <<'REMOTE'
set -euo pipefail
readarray -t TENANTS < <(printf '%s' "${TENANTS_B64}" | base64 -d)
if [ -f /tmp/svc-chaos.pid ]; then
    _rp="$(tr -d '[:space:]' < /tmp/svc-chaos.pid || true)"
    if [[ -n "${_rp}" ]] && kill -0 "${_rp}" 2>/dev/null; then
        kill "${_rp}" 2>/dev/null || true
    fi
    rm -f /tmp/svc-chaos.pid
fi
rm -f /tmp/svc-chaos.units /tmp/svc-chaos-recover.sh
sudo systemctl reset-failed "${STORAGE_SERVICE}" 2>/dev/null || true
if ((${#TENANTS[@]})); then
    for _u in "${TENANTS[@]}"; do sudo systemctl reset-failed "${_u}" 2>/dev/null || true; done
fi
sudo systemctl start "${STORAGE_SERVICE}"
sleep 3
if ((${#TENANTS[@]})); then sudo systemctl start "${TENANTS[@]}"; fi
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт systemd stop teardown, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "${_env}; bash -s" <<<"${remote_script}"
}

nemesis_systemd_stop_apply_all() {
    parallel_for_hosts nemesis_systemd_stop_apply "$@" -- "${TIMEOUT}"
}

nemesis_systemd_stop_teardown_all() {
    log "Подъём ydbd-юнитов на ${#@} хостах"
    parallel_for_hosts nemesis_systemd_stop_teardown "$@" || return $?
}

# ----------------------------------------------------------------------------
# 2) Rolling restart одной ноды (rolling-restart.sh).
# ----------------------------------------------------------------------------

nemesis_systemd_rolling_restart() {
    local host="$1" idx="$2" total="$3"
    log "Нода ${idx}/${total}: ${host}"
    chaos_term_remote_cmd "ssh ${host}  rolling-restart ydbd units"

    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
multi_units=\$(systemctl list-units '${YDBD_TENANT_UNIT_GLOB}' --state=running --no-legend 2>/dev/null \
    | awk '{print \$1}' | tr '\n' ' ')
if [ -z "\${multi_units}" ]; then
    multi_units=\$(systemctl list-units '${YDBD_TENANT_UNIT_GLOB}' --all --no-legend 2>/dev/null \
        | awk '{print \$1}' | tr '\n' ' ')
fi
echo "  Остановка tenant: \${multi_units:-'(нет)'}"
[ -n "\${multi_units}" ] && sudo systemctl stop \${multi_units} 2>/dev/null || true
echo "  Остановка storage (${YDBD_STORAGE_SERVICE})..."
sudo systemctl stop ${YDBD_STORAGE_SERVICE}
echo "  Запуск storage..."
sudo systemctl start ${YDBD_STORAGE_SERVICE}
sleep 3
if [ -n "\${multi_units}" ]; then
    echo "  Запуск tenant: \${multi_units}"
    sudo systemctl start \${multi_units}
fi
echo "  Готово"
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт rolling-restart, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

# ----------------------------------------------------------------------------
# 3) Rolling upgrade бинарника ydbd на одной ноде (тест 10).
#    Используются глобалы: YDBD_BIN, BACKUP_FILE, DIST_NAME, TIMEOUT,
#                          YDBD_STORAGE_SERVICE, YDBD_TENANT_UNIT_GLOB.
# ----------------------------------------------------------------------------

# stop tenants + storage; список tenant сохраняется в /tmp/upgrade-chaos.units.
nemesis_systemd_upgrade_svc_stop() {
    local host="$1"
    chaos_term_remote_cmd "ssh ${host}  systemctl stop tenants + storage"
    local remote_script
    remote_script=$(cat <<REMOTE
multi_units=\$(systemctl list-units '${YDBD_TENANT_UNIT_GLOB}' --state=running --no-legend 2>/dev/null | awk '{print \$1}' | tr '\n' ' ')
if [ -z "\${multi_units}" ]; then
    multi_units=\$(systemctl list-units '${YDBD_TENANT_UNIT_GLOB}' --all --no-legend 2>/dev/null | awk '{print \$1}' | tr '\n' ' ')
fi
echo "\${multi_units}" > /tmp/upgrade-chaos.units
echo "Остановка tenant: \${multi_units}"
sudo systemctl stop \${multi_units} 2>/dev/null || true
echo 'Остановка storage...'
sudo systemctl stop ${YDBD_STORAGE_SERVICE}
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт upgrade svc stop, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_svc_start() {
    local host="$1"
    chaos_term_remote_cmd "ssh ${host}  systemctl start storage + tenants"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
multi_units=\$(cat /tmp/upgrade-chaos.units 2>/dev/null || echo '')
echo 'Запуск storage...'
sudo systemctl start ${YDBD_STORAGE_SERVICE}
sleep 3
if [ -n "\${multi_units}" ]; then
    echo "Запуск tenant: \${multi_units}"
    sudo systemctl start \${multi_units}
fi
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт upgrade svc start, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_backup() {
    local host="$1"
    log "Бэкап ${YDBD_BIN} → ~/${BACKUP_FILE}"
    chaos_term_remote_cmd "ssh ${host}  cp ${YDBD_BIN} ~/${BACKUP_FILE}"
    local remote_script
    remote_script=$(cat <<REMOTE
mkdir -p "\$(dirname ~/${BACKUP_FILE})"
sudo cp ${YDBD_BIN} ~/${BACKUP_FILE}
sudo chown \$(id -u):\$(id -g) ~/${BACKUP_FILE}
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт upgrade backup, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_extract() {
    local host="$1" ydbd_path="$2"
    local strip
    strip=$(echo "${ydbd_path}" | tr -cd '/' | wc -c | tr -d ' ')
    log "Распаковка ${ydbd_path} (strip=${strip}) → /tmp/ydbd.new"
    chaos_term_remote_cmd "ssh ${host}  tar x ${DIST_NAME} → /tmp/ydbd.new"
    local remote_script="tar x -C /tmp/ --strip-components=${strip} -f ~/${DIST_NAME} ${ydbd_path} && mv /tmp/ydbd /tmp/ydbd.new"
    chaos_log_remote_script "Удалённый скрипт upgrade extract, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_place() {
    local host="$1"
    log "Установка нового бинарника: /tmp/ydbd.new → ${YDBD_BIN}"
    chaos_term_remote_cmd "ssh ${host}  cp /tmp/ydbd.new → ${YDBD_BIN}"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
sudo cp /tmp/ydbd.new ${YDBD_BIN}
sudo chmod +x ${YDBD_BIN}
rm -f /tmp/ydbd.new
echo "Версия: \$(sudo ${YDBD_BIN} --version 2>&1 | head -1 || echo '?')"
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт upgrade place, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_restore() {
    local host="$1"
    log "Откат бинарника: ~/${BACKUP_FILE} → ${YDBD_BIN}"
    chaos_term_remote_cmd "ssh ${host}  cp бэкап → ${YDBD_BIN}"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [ ! -f ~/${BACKUP_FILE} ]; then
    echo 'ОШИБКА: бэкап не найден' >&2
    exit 1
fi
sudo cp ~/${BACKUP_FILE} ${YDBD_BIN}
sudo chmod +x ${YDBD_BIN}
echo "Версия: \$(sudo ${YDBD_BIN} -V 2>&1 | grep 'Branch:' | awk '{print \$2}' || echo '?')"
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт upgrade restore, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_arm_timer() {
    local host="$1"
    chaos_term_remote_cmd "ssh ${host}  nohup auto-rollback через ${TIMEOUT}s"
    local remote_script exported
    exported="$(printf 'export UPGRADE_TIMEOUT=%q UPGRADE_BACKUP=%q UPGRADE_BIN=%q UPGRADE_STORAGE=%q' \
        "$TIMEOUT" "$BACKUP_FILE" "$YDBD_BIN" "$YDBD_STORAGE_SERVICE")"
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [ -f /tmp/upgrade-chaos.pid ]; then
    kill "\$(cat /tmp/upgrade-chaos.pid)" 2>/dev/null || true
    rm -f /tmp/upgrade-chaos.pid
fi
cat > /tmp/upgrade-chaos-recover.sh <<'RECOVERY'
#!/usr/bin/env bash
set -euo pipefail
trap 'rm -f /tmp/upgrade-chaos.pid /tmp/upgrade-chaos.units /tmp/upgrade-chaos-recover.sh' EXIT
sleep "\${UPGRADE_TIMEOUT}"
multi_units=()
read -r -a multi_units < /tmp/upgrade-chaos.units || true
if ((\${#multi_units[@]})); then sudo systemctl stop "\${multi_units[@]}" || true; fi
sudo systemctl stop "\${UPGRADE_STORAGE}"
sudo cp "\${HOME}/\${UPGRADE_BACKUP}" "\${UPGRADE_BIN}"
sudo chmod +x "\${UPGRADE_BIN}"
sudo systemctl start "\${UPGRADE_STORAGE}"
sleep 3
if ((\${#multi_units[@]})); then sudo systemctl start "\${multi_units[@]}"; fi
RECOVERY
chmod +x /tmp/upgrade-chaos-recover.sh
${exported}
nohup /tmp/upgrade-chaos-recover.sh >/tmp/upgrade-chaos-recover.log 2>&1 &
echo \$! > /tmp/upgrade-chaos.pid
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт upgrade arm timer, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_disarm_timer() {
    local host="$1"
    chaos_term_remote_cmd "ssh ${host}  kill auto-rollback timer"
    local remote_script
    remote_script=$(cat <<REMOTE
if [ -f /tmp/upgrade-chaos.pid ]; then
    kill \$(cat /tmp/upgrade-chaos.pid) 2>/dev/null || true
    rm -f /tmp/upgrade-chaos.pid
fi
rm -f /tmp/upgrade-chaos-recover.sh /tmp/upgrade-chaos.units
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт upgrade disarm timer, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_systemd_upgrade_check() {
    local host="$1"
    chaos_term_remote_cmd "ssh ${host}  ls binary, backup, services, timer"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<REMOTE
_ver() { sudo "\$1" -V 2>&1 | grep 'Branch:' | awk '{print \$2}' 2>/dev/null || sudo "\$1" --version 2>&1 | head -1 || echo '?'; }
echo '=== Бинарник ydbd ==='
if ls -lh ${YDBD_BIN} 2>/dev/null; then
    echo "  версия: \$(_ver ${YDBD_BIN})"
else
    echo '  (не найден по пути ${YDBD_BIN})'
fi
echo '=== Бэкап ==='
if [ -f ~/${BACKUP_FILE} ]; then
    ls -lh ~/${BACKUP_FILE}
    echo "  версия: \$(_ver ~/${BACKUP_FILE})"
else
    echo '  (нет)'
fi
echo '=== Сервисы ==='
systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -E 'kikimr|ydbd' || true
echo '=== Таймер ==='
if [ -f /tmp/upgrade-chaos.pid ]; then
    pid=\$(cat /tmp/upgrade-chaos.pid)
    if kill -0 "\${pid}" 2>/dev/null; then echo "  активен pid=\${pid}"; else echo '  pid-файл есть, процесс мёртв'; fi
else
    echo '  не активен'
fi
REMOTE
}
