#!/usr/bin/env bash

CHAOS_IPTABLES_STATE_DIR="${CHAOS_IPTABLES_STATE_DIR:-/var/lib/chaos-md}"

_chaos_iptables_chain_prefix() {
    local prefix="${CHAOS_IPTABLES_CHAIN:-YDB_CHAOS_FW}"
    [[ "${prefix}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    prefix="${prefix:0:10}"
    while [[ "${prefix}" == *_ || "${prefix}" == *- ]]; do prefix="${prefix%?}"; done
    [[ -n "${prefix}" ]] || return 1
    printf '%s' "${prefix}"
}

_chaos_iptables_operation_chain() {
    local operation="$1" prefix
    prefix="$(_chaos_iptables_chain_prefix)" || return 1
    printf '%s_%s' "${prefix}" "${operation:0:16}"
}

_nemesis_iptables_run_remote() {
    local host="$1" action="$2"
    shift 2
    local remote_cmd arg output line rc=0
    printf -v remote_cmd 'sudo bash -s -- %q' "${action}"
    for arg in "$@"; do
        printf -v remote_cmd '%s %q' "${remote_cmd}" "${arg}"
    done
    output="$(ssh "${SSH_OPTS[@]}" "${host}" "${remote_cmd}" < "${CHAOS_REPO_DIR}/nemesis/iptables-remote.sh")" || rc=$?
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if [[ "${line}" =~ ^observation\ operation=([0-9a-f]{32})\ resource=(iptables:[0-9a-f]{32})\ state=(active|clean|check_failed|unreachable)\ boot_id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\ revision=([0-9]+)\ recovery_armed=(true|false)\ cancelled=(true|false)\ code=([A-Za-z0-9_.:-]+)$ ]]; then
            [[ "${BASH_REMATCH[1]}" == "${CHAOS_OPERATION_ID}" ]] || return 1
            printf '%s %s %s recovery=%s cancelled=%s code=%s\n' \
                "${host}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
                "${BASH_REMATCH[6]}" "${BASH_REMATCH[7]}" "${BASH_REMATCH[8]}"
            chaos_json_emit_observation "${host}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
                "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" \
                "${BASH_REMATCH[7]}" "${BASH_REMATCH[8]}"
        else
            echo "Некорректное наблюдение iptables от ${host}: ${line}" >&2
            return 1
        fi
    done <<< "${output}"
    return "${rc}"
}

nemesis_iptables_apply() {
    local host="$1" target="$2" timeout_s="${3:-${TIMEOUT:-0}}"
    local chain ports_csv ifaces_csv stacks=""
    chaos_net_require_any_stack || return 1
    chaos_net_ifaces_for_host "${host}"
    chaos_ydb_ports_to_array
    chain="$(_chaos_iptables_operation_chain "${CHAOS_OPERATION_ID}")" || return 1
    ports_csv="${CHAOS_YDB_PORTS_ARR[*]}"; ports_csv="${ports_csv// /,}"
    ifaces_csv="${CHAOS_NET_IFACES_ARR[*]}"; ifaces_csv="${ifaces_csv// /,}"
    chaos_net_ipv4_enabled && stacks+="4"
    chaos_net_ipv6_enabled && stacks+="6"

    log_chaos_apply "iptables ${target} на ${host} chain=${chain} ifaces=[${ifaces_csv}] timeout=${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  iptables operation=${CHAOS_OPERATION_ID} chain=${chain}"
    _nemesis_iptables_run_remote "${host}" apply "${CHAOS_OPERATION_ID}" \
        "${CHAOS_IPTABLES_STATE_DIR}" "${timeout_s}" "${chain}" "${target}" \
        "${ifaces_csv}" "${ports_csv}" "${stacks}"
}

nemesis_iptables_teardown() {
    local host="$1" chain
    chain="$(_chaos_iptables_operation_chain "${CHAOS_OPERATION_ID}")" || return 1
    chaos_term_remote_cmd "ssh ${host}  iptables teardown operation=${CHAOS_OPERATION_ID}"
    if [[ "${MODE_TEARDOWN:-false}" == true && "${CHAOS_OPERATION_EXPLICIT:-false}" != true ]]; then
        _nemesis_iptables_run_remote "${host}" teardown-all "${CHAOS_OPERATION_ID}" "${CHAOS_IPTABLES_STATE_DIR}"
    else
        _nemesis_iptables_run_remote "${host}" teardown "${CHAOS_OPERATION_ID}" "${CHAOS_IPTABLES_STATE_DIR}" "${chain}"
    fi
}

nemesis_iptables_check() {
    local host="$1" operation=any chain=""
    if [[ "${CHAOS_OPERATION_EXPLICIT:-false}" == true ]]; then
        operation="${CHAOS_OPERATION_ID}"
        chain="$(_chaos_iptables_operation_chain "${operation}")" || return 1
    fi
    chaos_term_remote_cmd "ssh ${host}  iptables operation check"
    _nemesis_iptables_run_remote "${host}" check "${CHAOS_OPERATION_ID}" "${operation}" \
        "${CHAOS_IPTABLES_STATE_DIR}" "${chain}"
}

nemesis_iptables_apply_all() {
    local target="${IPT_TARGET:-REJECT}"
    log_chaos_apply "iptables ${target} на ${#@} хостах ports=${YDB_PORTS} timeout=${TIMEOUT:-0}s"
    parallel_for_hosts nemesis_iptables_apply "$@" -- "${target}" "${TIMEOUT:-0}"
}

nemesis_iptables_teardown_all() {
    log "Снятие iptables с ${#@} хостов"
    parallel_for_hosts nemesis_iptables_teardown "$@" || return $?
}
