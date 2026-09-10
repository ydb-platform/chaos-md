#!/usr/bin/env bash
# Немезис: iptables/ip6tables — блокировка YDB-интерконнекта.
# Используется в тестах 06 (одна нода) и 11 (весь ДЦ).
#
# CHAOS_NET_IPV4 / CHAOS_NET_IPV6 — какие стеки трогать (env).
# CHAOS_IPTABLES_CHAIN — имя пользовательской цепочки (по умолчанию YDB_CHAOS_FW).
# Интерфейсы: NET_IFACES / NET_IFACES_TABLE — все NIC с межнодевым трафиком перечислить в env
# (через запятую в строке таблицы или массив NET_IFACES). На каждый порт YDB и iface — 4 правила TCP:
#   INPUT  -i iface --dport / --sport;  OUTPUT -o iface --sport / --dport
# (и то же в ip6tables при CHAOS_NET_IPV6).
#
# Базовый API:
#   nemesis_iptables_prepare_chain_remote_script   # скрипт: создать цепочку + вызовы INPUT/OUTPUT
#   nemesis_iptables_apply    <host> <REJECT|DROP>
#   nemesis_iptables_teardown <host> <REJECT|DROP>
#   nemesis_iptables_check    <host>

_chaos_iptables_chain() {
    printf '%s' "${CHAOS_IPTABLES_CHAIN:-YDB_CHAOS_FW}"
}

_iptables_jrule() {
    case "${1:-REJECT}" in
        DROP) echo "-j DROP" ;;
        *)    echo "-j REJECT --reject-with tcp-reset" ;;
    esac
}

# Идемпотентно: создать цепочку и вставить вызов в начало INPUT/OUTPUT (IPv4/IPv6 по флагам env).
nemesis_iptables_prepare_chain_remote_script() {
    local c
    c="$(_chaos_iptables_chain)"
    local rb=""
    rb+="set -euo pipefail"$'\n'
    rb+="# Цепочка ${c}, вызов из INPUT/OUTPUT"$'\n'

    if chaos_net_ipv4_enabled; then
        rb+="sudo iptables -w 2 -N ${c} 2>/dev/null || true"$'\n'
        rb+="sudo iptables -w 2 -C INPUT -j ${c} 2>/dev/null || sudo iptables -w 2 -I INPUT 1 -j ${c}"$'\n'
        rb+="sudo iptables -w 2 -C OUTPUT -j ${c} 2>/dev/null || sudo iptables -w 2 -I OUTPUT 1 -j ${c}"$'\n'
    fi
    if chaos_net_ipv6_enabled; then
        rb+="sudo ip6tables -w 2 -N ${c} 2>/dev/null || true"$'\n'
        rb+="sudo ip6tables -w 2 -C INPUT -j ${c} 2>/dev/null || sudo ip6tables -w 2 -I INPUT 1 -j ${c}"$'\n'
        rb+="sudo ip6tables -w 2 -C OUTPUT -j ${c} 2>/dev/null || sudo ip6tables -w 2 -I OUTPUT 1 -j ${c}"$'\n'
    fi
    printf '%s' "${rb}"
}

_nemesis_iptables_remote_script() {
    local target="$1" timeout_s="${2:-0}"
    local jrule c
    jrule="$(_iptables_jrule "${target}")"
    c="$(_chaos_iptables_chain)"

    chaos_ydb_ports_to_array

    local rb=""
    rb+="$(nemesis_iptables_prepare_chain_remote_script)"$'\n'
    rb+="# Правила по интерфейсам и стекам (IPv4 затем IPv6)"$'\n'

    local iface p
    for iface in "${CHAOS_NET_IFACES_ARR[@]}"; do
        rb+=""$'\n'
        rb+="echo '[iptables-chaos] iface=${iface} chain=${c}'"$'\n'

        if chaos_net_ipv4_enabled; then
            rb+="# IPv4: INPUT dport/sport + OUTPUT sport/dport"$'\n'
            for p in "${CHAOS_YDB_PORTS_ARR[@]}"; do
                rb+="sudo iptables -w 2 -A ${c} -p tcp -m tcp -i ${iface} --dport ${p} ${jrule}"$'\n'
                rb+="sudo iptables -w 2 -A ${c} -p tcp -m tcp -i ${iface} --sport ${p} ${jrule}"$'\n'
                rb+="sudo iptables -w 2 -A ${c} -p tcp -m tcp -o ${iface} --sport ${p} ${jrule}"$'\n'
                rb+="sudo iptables -w 2 -A ${c} -p tcp -m tcp -o ${iface} --dport ${p} ${jrule}"$'\n'
            done
        fi

        if chaos_net_ipv6_enabled; then
            rb+="# IPv6: INPUT dport/sport + OUTPUT sport/dport"$'\n'
            for p in "${CHAOS_YDB_PORTS_ARR[@]}"; do
                rb+="sudo ip6tables -w 2 -A ${c} -p tcp -m tcp -i ${iface} --dport ${p} ${jrule}"$'\n'
                rb+="sudo ip6tables -w 2 -A ${c} -p tcp -m tcp -i ${iface} --sport ${p} ${jrule}"$'\n'
                rb+="sudo ip6tables -w 2 -A ${c} -p tcp -m tcp -o ${iface} --sport ${p} ${jrule}"$'\n'
                rb+="sudo ip6tables -w 2 -A ${c} -p tcp -m tcp -o ${iface} --dport ${p} ${jrule}"$'\n'
            done
        fi
    done

    # Host-side safety-таймер снимает iptables-изоляцию независимо от управляющего процесса.
    if [[ "${timeout_s}" -gt 0 ]]; then
        rb+=""$'\n'
        rb+="# Safety-таймер: auto-teardown через ${timeout_s}s"$'\n'
        rb+="nohup bash -c 'sleep ${timeout_s}; sudo iptables -w 2 -F ${c} 2>/dev/null || true; sudo ip6tables -w 2 -F ${c} 2>/dev/null || true' >/dev/null 2>&1 &"$'\n'
        rb+="echo \"[iptables-chaos] safety-timer ${timeout_s}s pid=\$!\""$'\n'
    fi

    printf '%s' "${rb}"
}

nemesis_iptables_apply() {
    local host="$1" target="$2" timeout_s="${3:-${TIMEOUT:-0}}"
    chaos_net_require_any_stack || return 1
    chaos_net_ifaces_for_host "${host}"
    chaos_ydb_ports_to_array

    local ports_csv="${CHAOS_YDB_PORTS_ARR[*]}"
    ports_csv="${ports_csv// /,}"
    local ifcsv="${CHAOS_NET_IFACES_ARR[*]}"
    ifcsv="${ifcsv// /,}"
    local stacks=""
    chaos_net_ipv4_enabled && stacks+="IPv4 "
    chaos_net_ipv6_enabled && stacks+="IPv6 "
    stacks="${stacks%% }"

    local c
    c="$(_chaos_iptables_chain)"

    log_chaos_apply "iptables/ip6tables ${target} ports=${ports_csv} на ${host} ifaces=[${ifcsv}] stacks=[${stacks}] timeout=${timeout_s}s (цепочка ${c})"
    chaos_term_remote_cmd "ssh ${host}  ${c} ${target} tcp ${ports_csv} ifaces=${ifcsv}"

    local remote_script
    remote_script="$(_nemesis_iptables_remote_script "${target}" "${timeout_s}")"

    chaos_log_remote_script "Удалённый скрипт iptables, хост ${host}" "${remote_script}"

    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<< "${remote_script}"
}

nemesis_iptables_teardown() {
    local host="$1"
    local c
    c="$(_chaos_iptables_chain)"
    chaos_term_remote_cmd "ssh ${host}  iptables/ip6tables -F ${c} (сброс цепочки)"
    local rb=$'sudo iptables  -w 2 -F '"${c}"$' 2>/dev/null || true\nsudo ip6tables -w 2 -F '"${c}"$' 2>/dev/null || true\n'
    chaos_log_remote_script "Удалённый скрипт iptables teardown, хост ${host}" "${rb}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${rb}"
}

nemesis_iptables_check() {
    local host="$1"
    local c
    c="$(_chaos_iptables_chain)"
    chaos_term_remote_cmd "ssh ${host}  iptables-save | grep ${c}"
    # shellcheck disable=SC2087
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<REMOTE
echo "=== ip6tables (${c}) ==="
sudo ip6tables-save 2>/dev/null | grep -E '${c}|:${c}' || true
echo "=== iptables (${c}) ==="
sudo iptables-save 2>/dev/null | grep -E '${c}|:${c}' || true
REMOTE
}

nemesis_iptables_apply_all() {
    local target="${IPT_TARGET:-REJECT}"
    log_chaos_apply "iptables ${target} на ${#@} хостах ports=${YDB_PORTS} timeout=${TIMEOUT:-0}s"
    parallel_for_hosts nemesis_iptables_apply "$@" -- "${target}" "${TIMEOUT:-0}"
}

nemesis_iptables_teardown_all() {
    local target="${IPT_TARGET:-REJECT}"
    log "Снятие iptables ${target} с ${#@} хостов"
    parallel_for_hosts nemesis_iptables_teardown "$@" -- "${target}"
}
