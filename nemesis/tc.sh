#!/usr/bin/env bash

CHAOS_TC_STATE_DIR="${CHAOS_TC_STATE_DIR:-/var/lib/chaos-md}"

_nemesis_tc_run_remote() {
    local host="$1" action="$2"
    shift 2
    local remote_cmd arg
    printf -v remote_cmd 'sudo bash -s -- %q' "${action}"
    for arg in "$@"; do
        printf -v remote_cmd '%s %q' "${remote_cmd}" "${arg}"
    done
    ssh "${SSH_OPTS[@]}" "${host}" "${remote_cmd}" < "${CHAOS_REPO_DIR}/nemesis/tc-remote.sh"
}

nemesis_tc_netem_apply() {
    local host="$1" netem_params="$2" timeout_s="$3"
    chaos_ydb_ports_to_array
    chaos_net_require_any_stack || return 1
    chaos_net_ifaces_for_host "${host}"

    local ports_csv="${CHAOS_YDB_PORTS_ARR[*]}"
    local ifaces_csv="${CHAOS_NET_IFACES_ARR[*]}"
    local stack_ids=""
    ports_csv="${ports_csv// /,}"
    ifaces_csv="${ifaces_csv// /,}"
    chaos_net_ipv4_enabled && stack_ids+="4"
    chaos_net_ipv6_enabled && stack_ids+="6"

    log_chaos_apply "tc netem на ${host} ifaces=[${ifaces_csv}] ports=${ports_csv} [${netem_params}] timeout=${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  tc prio+netem [${netem_params}] ifaces=${ifaces_csv}"
    _nemesis_tc_run_remote "${host}" apply-netem "${CHAOS_OPERATION_ID}" \
        "${CHAOS_TC_STATE_DIR}" "${timeout_s}" "${ifaces_csv}" "${ports_csv}" \
        "${stack_ids}" "${netem_params}"
}

nemesis_tc_tbf_apply() {
    local host="$1" rate_mbit="$2" burst_bytes="$3" timeout_s="$4"
    chaos_net_ifaces_for_host "${host}"
    local ifaces_csv="${CHAOS_NET_IFACES_ARR[*]}"
    ifaces_csv="${ifaces_csv// /,}"

    log_chaos_apply "tc tbf на ${host} ifaces=[${ifaces_csv}] rate=${rate_mbit}mbit burst=${burst_bytes} timeout=${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  tc tbf rate ${rate_mbit}mbit burst ${burst_bytes}, auto-undo через ${timeout_s}s"
    _nemesis_tc_run_remote "${host}" apply-tbf "${CHAOS_OPERATION_ID}" \
        "${CHAOS_TC_STATE_DIR}" "${timeout_s}" "${ifaces_csv}" "${rate_mbit}" "${burst_bytes}"
}

nemesis_tc_teardown() {
    local host="$1"
    chaos_net_ifaces_for_host "${host}"
    local ifaces_csv="${CHAOS_NET_IFACES_ARR[*]}"
    ifaces_csv="${ifaces_csv// /,}"
    chaos_term_remote_cmd "ssh ${host}  tc qdisc del root ifaces=${ifaces_csv}"

    if [[ "${MODE_TEARDOWN:-false}" == true && "${CHAOS_OPERATION_EXPLICIT:-false}" != true ]]; then
        _nemesis_tc_run_remote "${host}" teardown-all "${CHAOS_TC_STATE_DIR}" "${ifaces_csv}"
    else
        _nemesis_tc_run_remote "${host}" teardown "${CHAOS_OPERATION_ID}" "${CHAOS_TC_STATE_DIR}" "${ifaces_csv}"
    fi
}

nemesis_tc_check() {
    local host="$1"
    chaos_net_ifaces_for_host "${host}"
    local ifaces_csv="${CHAOS_NET_IFACES_ARR[*]}"
    local operation=any
    ifaces_csv="${ifaces_csv// /,}"
    [[ "${CHAOS_OPERATION_EXPLICIT:-false}" == true ]] && operation="${CHAOS_OPERATION_ID}"
    chaos_term_remote_cmd "ssh ${host}  tc operation check ifaces=${ifaces_csv}"
    _nemesis_tc_run_remote "${host}" check "${operation}" "${CHAOS_TC_STATE_DIR}" "${ifaces_csv}"
}

nemesis_tc_netem_apply_all() {
    log_chaos_apply "tc netem [${NETEM_PARAMS}] на ${#@} хостах timeout=${TIMEOUT}s"
    parallel_for_hosts nemesis_tc_netem_apply "$@" -- "${NETEM_PARAMS}" "${TIMEOUT}"
}

nemesis_tc_tbf_apply_all() {
    log_chaos_apply "tc tbf rate=${RATE}mbit burst=${BURST}b на ${#@} хостах timeout=${TIMEOUT}s"
    parallel_for_hosts nemesis_tc_tbf_apply "$@" -- "${RATE}" "${BURST}" "${TIMEOUT}"
}

nemesis_tc_teardown_all() {
    log "Снятие tc с ${#@} хостов"
    parallel_for_hosts nemesis_tc_teardown "$@" || return $?
}
