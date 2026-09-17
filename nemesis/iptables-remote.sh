#!/usr/bin/env bash

set -euo pipefail
umask 077

fail() { echo "iptables operation: $*" >&2; exit 1; }
valid_operation() { [[ "${1:-}" =~ ^[0-9a-f]{32}$ ]]; }
valid_state_root() { [[ "${1:-}" =~ ^/[A-Za-z0-9._/-]+$ ]]; }
valid_chain() { [[ "${1:-}" =~ ^[A-Za-z0-9_-]{1,28}$ ]]; }
valid_stacks() { [[ "$1" == 4 || "$1" == 6 || "$1" == 46 ]]; }

valid_csv() {
    local kind="$1" value="$2" item seen="" limit=256
    local items=()
    [[ "${value}" != ,* && "${value}" != *, && "${value}" != *,,* ]] || return 1
    IFS=',' read -r -a items <<< "${value}"
    [[ "${kind}" != iface ]] || limit=16
    ((${#items[@]} > 0 && ${#items[@]} <= limit)) || return 1
    for item in "${items[@]}"; do
        if [[ "${kind}" == iface ]]; then
            [[ "${item}" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
        else
            [[ "${item}" =~ ^[1-9][0-9]{0,4}$ ]] && ((item <= 65535)) || return 1
        fi
        [[ ",${seen}," != *",${item},"* ]] || return 1
        seen="${seen:+${seen},}${item}"
    done
}

write_value() {
    local file="$1" value="$2" tmp
    tmp="${file}.tmp.$$"
    printf '%s\n' "${value}" > "${tmp}"
    mv -f "${tmp}" "${file}"
}

read_config() {
    local file="$1" chain target ifaces ports stacks
    [[ -f "${file}" && ! -L "${file}" ]] || return 1
    IFS='|' read -r chain target ifaces ports stacks < "${file}" || return 1
    valid_chain "${chain}" && [[ "${target}" == REJECT || "${target}" == DROP ]] || return 1
    valid_csv iface "${ifaces}" && valid_csv port "${ports}" && valid_stacks "${stacks}" || return 1
    [[ "$(cat "${file}")" == "${chain}|${target}|${ifaces}|${ports}|${stacks}" ]] || return 1
    printf '%s\n' "${chain}|${target}|${ifaces}|${ports}|${stacks}"
}

read_owner() {
    local file="$1" value=""
    [[ -f "${file}" ]] || return 1
    IFS= read -r value < "${file}" || true
    valid_operation "${value}" || return 1
    printf '%s' "${value}"
}

next_host_revision() {
    local file="${STATE_ROOT}/revision" value=0
    [[ ! -f "${file}" ]] || { IFS= read -r value < "${file}" || true; }
    [[ "${value}" =~ ^[0-9]+$ ]] || fail 'invalid host revision'
    ((value += 1))
    write_value "${file}" "${value}"
    printf '%s' "${value}"
}

emit_state() {
    local resource_operation="$1" state="$2" code="${3:-ok}" recovery=false cancelled=false
    [[ "${state}" == active || "${state}" == clean ]] || state=check_failed
    [[ "${state}" == active ]] && recovery=true
    [[ "${ACTION}" == teardown || "${ACTION}" == teardown-all ]] && cancelled=true
    [[ -e "${STATE_ROOT}/operations/${resource_operation}/cancelled" ]] && cancelled=true
    printf 'observation operation=%s resource=iptables:%s state=%s boot_id=%s revision=%s recovery_armed=%s cancelled=%s code=%s\n' \
        "${COMMAND_OPERATION}" "${resource_operation}" "${state}" "${HOST_BOOT_ID}" "${HOST_REVISION}" \
        "${recovery}" "${cancelled}" "${code}"
}

table_bin() { [[ "$1" == 4 ]] && printf '%s' "${IPTABLES_BIN}" || printf '%s' "${IP6TABLES_BIN}"; }
run_table() {
    local stack="$1" bin
    shift
    bin="$(table_bin "${stack}")"
    "${TIMEOUT_BIN}" --signal=KILL 10s "${bin}" -w 2 "$@"
}

chain_active() {
    local chain="$1" stacks="$2" expected="$3" output count
    if [[ "${stacks}" == *4* ]]; then
        output="$(run_table 4 -S "${chain}")" || return 1
        run_table 4 -C INPUT -j "${chain}" >/dev/null || return 1
        run_table 4 -C OUTPUT -j "${chain}" >/dev/null || return 1
        count="$(grep -c "^-A ${chain} " <<< "${output}" || true)"
        [[ "${count}" == "${expected}" ]] || return 1
    fi
    if [[ "${stacks}" == *6* ]]; then
        output="$(run_table 6 -S "${chain}")" || return 1
        run_table 6 -C INPUT -j "${chain}" >/dev/null || return 1
        run_table 6 -C OUTPUT -j "${chain}" >/dev/null || return 1
        count="$(grep -c "^-A ${chain} " <<< "${output}" || true)"
        [[ "${count}" == "${expected}" ]] || return 1
    fi
}

chain_clean() {
    local chain="$1" stacks="$2" stack output
    valid_stacks "${stacks}" || return 2
    for stack in 4 6; do
        [[ "${stacks}" == *"${stack}"* ]] || continue
        output="$(run_table "${stack}" -S)" || return 2
        awk -v chain="${chain}" '
            ($1 == "-N" || $1 == "-A") && $2 == chain { found=1 }
            { for (i=3; i<NF; i++) if (($i == "-j" || $i == "-g") && $(i+1) == chain) found=1 }
            END { exit found ? 1 : 0 }
        ' <<< "${output}" || return 1
    done
}

cleanup_stack() {
    local stack="$1" chain="$2" i
    for i in 1 2 3 4; do
        run_table "${stack}" -C INPUT -j "${chain}" >/dev/null 2>&1 || break
        run_table "${stack}" -D INPUT -j "${chain}" >/dev/null 2>&1 || return 1
    done
    for i in 1 2 3 4; do
        run_table "${stack}" -C OUTPUT -j "${chain}" >/dev/null 2>&1 || break
        run_table "${stack}" -D OUTPUT -j "${chain}" >/dev/null 2>&1 || return 1
    done
    run_table "${stack}" -F "${chain}" >/dev/null 2>&1 || true
    run_table "${stack}" -X "${chain}" >/dev/null 2>&1 || true
}

cleanup_owned() {
    local operation="$1" chain="$2" stacks="$3" final_phase="$4"
    local owner_file owner="" failed=0
    owner_file="${STATE_ROOT}/owners/iptables.${chain}"
    if [[ -e "${owner_file}" ]]; then
        owner="$(read_owner "${owner_file}" 2>/dev/null)" || {
            emit_state "${operation}" check_failed invalid_owner
            return 1
        }
    fi
    if [[ -n "${owner}" && "${owner}" != "${operation}" ]]; then
        emit_state "${operation}" check_failed owner_conflict
        return 1
    fi
    if [[ -z "${owner}" ]]; then
        if chain_clean "${chain}" "${stacks}"; then emit_state "${operation}" clean ok; return 0; fi
        emit_state "${operation}" check_failed unowned_chain
        return 1
    fi
    [[ "${stacks}" != *4* ]] || cleanup_stack 4 "${chain}" || failed=1
    [[ "${stacks}" != *6* ]] || cleanup_stack 6 "${chain}" || failed=1
    chain_clean "${chain}" "${stacks}" || failed=1
    if ((failed)); then
        write_value "${STATE_ROOT}/operations/${operation}/phase" cleanup_failed
        emit_state "${operation}" check_failed chain_remains
        return 1
    fi
    rm -f "${owner_file}"
    write_value "${STATE_ROOT}/operations/${operation}/phase" "${final_phase}"
    emit_state "${operation}" clean ok
}

write_recovery_script() {
    local file="$1"
    cat > "${file}" <<'RECOVER'
#!/usr/bin/env bash
set -euo pipefail
umask 077
operation="$1"; state_root="$2"; delay="$3"
op_dir="${state_root}/operations/${operation}"
printf '%s\n' ready > "${op_dir}/timer.ready"
sleep "${delay}"
exec 9> "${state_root}/lock"
locked=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if flock -w 5 -x 9; then locked=true; break; fi
    sleep 1
done
[[ "${locked}" == true ]] || exit 1
IFS='|' read -r chain _ _ _ stacks < "${op_dir}/iptables.config"
[[ "${chain}" =~ ^[A-Za-z0-9_-]{1,28}$ && ( "${stacks}" == 4 || "${stacks}" == 6 || "${stacks}" == 46 ) ]] || exit 1
owner_file="${state_root}/owners/iptables.${chain}"
owner=""; [[ ! -f "${owner_file}" ]] || IFS= read -r owner < "${owner_file}" || true
[[ "${owner}" == "${operation}" ]] || exit 1
timeout_bin="$(command -v timeout)"; iptables_bin="$(command -v iptables)"; ip6tables_bin="$(command -v ip6tables || true)"
run() { local bin="$1"; shift; "${timeout_bin}" --signal=KILL 10s "${bin}" -w 2 "$@"; }
clean_stack() {
    local bin="$1" i output
    for i in 1 2 3 4; do run "${bin}" -C INPUT -j "${chain}" >/dev/null 2>&1 || break; run "${bin}" -D INPUT -j "${chain}" >/dev/null 2>&1 || return 1; done
    for i in 1 2 3 4; do run "${bin}" -C OUTPUT -j "${chain}" >/dev/null 2>&1 || break; run "${bin}" -D OUTPUT -j "${chain}" >/dev/null 2>&1 || return 1; done
    run "${bin}" -F "${chain}" >/dev/null 2>&1 || true
    run "${bin}" -X "${chain}" >/dev/null 2>&1 || true
    output="$(run "${bin}" -S)" || return 1
    awk -v chain="${chain}" '
        ($1 == "-N" || $1 == "-A") && $2 == chain { found=1 }
        { for (i=3; i<NF; i++) if (($i == "-j" || $i == "-g") && $(i+1) == chain) found=1 }
        END { exit found ? 1 : 0 }
    ' <<< "${output}"
}
failed=0
[[ "${stacks}" != *4* ]] || clean_stack "${iptables_bin}" || failed=1
[[ "${stacks}" != *6* ]] || { [[ -n "${ip6tables_bin}" ]] && clean_stack "${ip6tables_bin}"; } || failed=1
if ((failed)); then printf '%s\n' cleanup_failed > "${op_dir}/phase"; exit 1; fi
[[ "${owner}" != "${operation}" ]] || rm -f "${owner_file}"
printf '%s\n' expired > "${op_dir}/phase"
RECOVER
    chmod 700 "${file}"
}

apply_rules() {
    local chain="$1" target="$2" ifaces="$3" ports="$4" stacks="$5"
    local stack iface port expected
    local rule_tail=() iface_values=() port_values=()
    IFS=',' read -r -a iface_values <<< "${ifaces}"
    IFS=',' read -r -a port_values <<< "${ports}"
    [[ "${target}" == DROP ]] && rule_tail=(-j DROP) || rule_tail=(-j REJECT --reject-with tcp-reset)
    expected=$((${#iface_values[@]} * ${#port_values[@]} * 4))
    for stack in 4 6; do
        [[ "${stacks}" == *"${stack}"* ]] || continue
        run_table "${stack}" -N "${chain}" || return 1
        run_table "${stack}" -I INPUT 1 -j "${chain}" || return 1
        run_table "${stack}" -I OUTPUT 1 -j "${chain}" || return 1
        for iface in "${iface_values[@]}"; do
            for port in "${port_values[@]}"; do
                run_table "${stack}" -A "${chain}" -p tcp -m tcp -i "${iface}" --dport "${port}" "${rule_tail[@]}" || return 1
                run_table "${stack}" -A "${chain}" -p tcp -m tcp -i "${iface}" --sport "${port}" "${rule_tail[@]}" || return 1
                run_table "${stack}" -A "${chain}" -p tcp -m tcp -o "${iface}" --sport "${port}" "${rule_tail[@]}" || return 1
                run_table "${stack}" -A "${chain}" -p tcp -m tcp -o "${iface}" --dport "${port}" "${rule_tail[@]}" || return 1
            done
        done
    done
    chain_active "${chain}" "${stacks}" "${expected}"
}

apply_operation() {
    local operation="$1" timeout_s="$2" chain="$3" target="$4" ifaces="$5" ports="$6" stacks="$7"
    local op_dir owner_file config timer_pid timer_ready=false
    local iface_values=() port_values=()
    op_dir="${STATE_ROOT}/operations/${operation}"
    owner_file="${STATE_ROOT}/owners/iptables.${chain}"
    config="${chain}|${target}|${ifaces}|${ports}|${stacks}"
    mkdir -p "${op_dir}"
    [[ ! -L "${op_dir}" && ! -e "${op_dir}/cancelled" ]] || fail 'operation was cancelled or unsafe'
    if [[ -f "${op_dir}/iptables.config" && "$(cat "${op_dir}/iptables.config")" != "${config}" ]]; then fail 'operation configuration changed'; fi
    write_value "${op_dir}/iptables.config" "${config}"
    if [[ -f "${op_dir}/phase" && "$(cat "${op_dir}/phase")" == active ]]; then
        [[ "$(read_owner "${owner_file}" 2>/dev/null || true)" == "${operation}" ]] || fail 'active operation lost ownership'
        IFS=',' read -r -a iface_values <<< "${ifaces}"; IFS=',' read -r -a port_values <<< "${ports}"
        chain_active "${chain}" "${stacks}" "$((${#iface_values[@]} * ${#port_values[@]} * 4))" || fail 'active chain changed'
        emit_state "${operation}" active ok
        return 0
    elif [[ -f "${op_dir}/phase" ]]; then
        cleanup_owned "${operation}" "${chain}" "${stacks}" retry_required || fail 'incomplete apply could not be cleaned'
        fail 'incomplete apply was cleaned; use a new operation'
    fi
    [[ ! -e "${owner_file}" ]] || fail 'chain metadata already exists'
    chain_clean "${chain}" "${stacks}" || fail 'operation chain already exists'
    write_recovery_script "${op_dir}/recover.sh"
    bash -n "${op_dir}/recover.sh" || fail 'recovery timer script is invalid'
    rm -f "${op_dir}/timer.ready"
    write_value "${op_dir}/phase" armed
    nohup "${op_dir}/recover.sh" "${operation}" "${STATE_ROOT}" "${timeout_s}" 9>&- </dev/null >/dev/null 2>&1 &
    timer_pid=$!; write_value "${op_dir}/timer.pid" "${timer_pid}"
    for _ in {1..100}; do
        if [[ -f "${op_dir}/timer.ready" ]]; then timer_ready=true; break; fi
        kill -0 "${timer_pid}" 2>/dev/null || break
        sleep 0.02
    done
    [[ "${timer_ready}" == true ]] || fail 'recovery timer did not become ready'
    write_value "${owner_file}" "${operation}"
    write_value "${op_dir}/phase" applying
    if ! apply_rules "${chain}" "${target}" "${ifaces}" "${ports}" "${stacks}"; then
        : > "${op_dir}/cancelled"
        cleanup_owned "${operation}" "${chain}" "${stacks}" apply_failed || true
        fail 'apply failed and compensation was attempted'
    fi
    write_value "${op_dir}/phase" active
    emit_state "${operation}" active ok
}

inspect_operation() {
    local operation="$1" requested_chain="${2:-}" op_dir chain target ifaces ports stacks expected owner config
    local iface_values=() port_values=()
    op_dir="${STATE_ROOT}/operations/${operation}"
    if [[ ! -e "${op_dir}/iptables.config" ]]; then
        if valid_chain "${requested_chain}" && chain_clean "${requested_chain}" 46; then
            emit_state "${operation}" clean no_state; return 0
        fi
        emit_state "${operation}" check_failed missing_config; return 1
    fi
    config="$(read_config "${op_dir}/iptables.config")" || { emit_state "${operation}" check_failed invalid_config; return 1; }
    IFS='|' read -r chain target ifaces ports stacks <<< "${config}"
    [[ -z "${requested_chain}" || "${requested_chain}" == "${chain}" ]] || { emit_state "${operation}" check_failed chain_mismatch; return 1; }
    owner="$(read_owner "${STATE_ROOT}/owners/iptables.${chain}" 2>/dev/null || true)"
    if [[ -z "${owner}" ]]; then
        chain_clean "${chain}" "${stacks}" && { emit_state "${operation}" clean ok; return 0; }
        emit_state "${operation}" check_failed unowned_chain; return 1
    fi
    [[ "${owner}" == "${operation}" ]] || { emit_state "${operation}" check_failed owner_conflict; return 1; }
    IFS=',' read -r -a iface_values <<< "${ifaces}"; IFS=',' read -r -a port_values <<< "${ports}"
    expected=$((${#iface_values[@]} * ${#port_values[@]} * 4))
    chain_active "${chain}" "${stacks}" "${expected}" && { emit_state "${operation}" active ok; return 0; }
    emit_state "${operation}" check_failed chain_mismatch; return 1
}

ACTION="${1:-}"; shift || true
case "${ACTION}" in
    apply)
        (($# == 8)) || fail 'apply expects 8 arguments'
        COMMAND_OPERATION="$1"; STATE_ROOT="$2"; TIMEOUT_S="$3"; CHAIN="$4"
        TARGET="$5"; IFACES="$6"; PORTS="$7"; STACKS="$8"
        ;;
    teardown)
        (($# == 3)) || fail 'teardown expects 3 arguments'
        COMMAND_OPERATION="$1"; STATE_ROOT="$2"; CHAIN="$3"
        ;;
    teardown-all)
        (($# == 2)) || fail 'teardown-all expects 2 arguments'
        COMMAND_OPERATION="$1"; STATE_ROOT="$2"
        ;;
    check)
        (($# == 4)) || fail 'check expects 4 arguments'
        COMMAND_OPERATION="$1"; OPERATION="$2"; STATE_ROOT="$3"; CHAIN="$4"
        ;;
    *) fail 'unknown action' ;;
esac

valid_operation "${COMMAND_OPERATION}" || fail 'invalid operation'
valid_state_root "${STATE_ROOT}" || fail 'invalid state root'
command -v flock >/dev/null 2>&1 || fail 'flock is required'
command -v nohup >/dev/null 2>&1 || fail 'nohup is required'
TIMEOUT_BIN="$(command -v timeout)" || fail 'timeout is required'
IPTABLES_BIN="$(command -v iptables)" || fail 'iptables is required'
IP6TABLES_BIN="$(command -v ip6tables || true)"
mkdir -p "${STATE_ROOT}/operations" "${STATE_ROOT}/owners"
[[ ! -L "${STATE_ROOT}" && ! -L "${STATE_ROOT}/operations" && ! -L "${STATE_ROOT}/owners" ]] || fail 'state path is a symlink'
exec 9> "${STATE_ROOT}/lock"
flock -w 5 -x 9 || fail 'metadata lock timed out'
HOST_BOOT_ID="${CHAOS_IPTABLES_BOOT_ID:-}"
if [[ -z "${HOST_BOOT_ID}" && -f /proc/sys/kernel/random/boot_id ]]; then IFS= read -r HOST_BOOT_ID < /proc/sys/kernel/random/boot_id || true; fi
[[ "${HOST_BOOT_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail 'boot_id is unavailable or invalid'
HOST_BOOT_ID="$(printf '%s' "${HOST_BOOT_ID}" | tr 'A-F' 'a-f')"
HOST_REVISION="$(next_host_revision)"

case "${ACTION}" in
    apply)
        [[ "${TIMEOUT_S}" =~ ^[1-9][0-9]*$ ]] || fail 'invalid timeout'
        valid_chain "${CHAIN}" || fail 'invalid chain'
        [[ "${TARGET}" == REJECT || "${TARGET}" == DROP ]] || fail 'invalid target'
        valid_csv iface "${IFACES}" || fail 'invalid interfaces'
        valid_csv port "${PORTS}" || fail 'invalid ports'
        [[ "${STACKS}" == 4 || "${STACKS}" == 6 || "${STACKS}" == 46 ]] || fail 'invalid stacks'
        [[ "${STACKS}" != *6* || -n "${IP6TABLES_BIN}" ]] || fail 'ip6tables is required'
        apply_operation "${COMMAND_OPERATION}" "${TIMEOUT_S}" "${CHAIN}" "${TARGET}" "${IFACES}" "${PORTS}" "${STACKS}"
        ;;
    teardown)
        valid_chain "${CHAIN}" || fail 'invalid chain'
        OP_DIR="${STATE_ROOT}/operations/${COMMAND_OPERATION}"
        mkdir -p "${OP_DIR}"; : > "${OP_DIR}/cancelled"
        if [[ ! -e "${OP_DIR}/iptables.config" ]]; then
            cleanup_owned "${COMMAND_OPERATION}" "${CHAIN}" 46 cancelled
            exit $?
        fi
        CONFIG="$(read_config "${OP_DIR}/iptables.config")" || fail 'invalid operation configuration'
        IFS='|' read -r CONFIG_CHAIN _ _ _ CONFIG_STACKS <<< "${CONFIG}"
        [[ "${CONFIG_CHAIN}" == "${CHAIN}" ]] || fail 'operation chain changed'
        cleanup_owned "${COMMAND_OPERATION}" "${CHAIN}" "${CONFIG_STACKS}" cancelled
        ;;
    teardown-all)
        FOUND=false; FAILED=0
        for OP_DIR in "${STATE_ROOT}/operations"/*; do
            [[ -d "${OP_DIR}" && -f "${OP_DIR}/iptables.config" ]] || continue
            RESOURCE_OPERATION="${OP_DIR##*/}"; valid_operation "${RESOURCE_OPERATION}" || continue
            CONFIG="$(read_config "${OP_DIR}/iptables.config")" || { FAILED=1; continue; }
            IFS='|' read -r CONFIG_CHAIN _ _ _ CONFIG_STACKS <<< "${CONFIG}"
            FOUND=true; : > "${OP_DIR}/cancelled"
            cleanup_owned "${RESOURCE_OPERATION}" "${CONFIG_CHAIN}" "${CONFIG_STACKS}" cancelled || FAILED=1
        done
        [[ "${FOUND}" == true ]] || emit_state "${COMMAND_OPERATION}" clean no_state
        ((FAILED == 0)) || exit 1
        ;;
    check)
        if [[ "${OPERATION}" != any ]]; then
            valid_operation "${OPERATION}" || fail 'invalid expected operation'
            valid_chain "${CHAIN}" || fail 'invalid expected chain'
            inspect_operation "${OPERATION}" "${CHAIN}"
        else
            FOUND=false; FAILED=0
            for OP_DIR in "${STATE_ROOT}/operations"/*; do
                [[ -d "${OP_DIR}" && -f "${OP_DIR}/iptables.config" ]] || continue
                RESOURCE_OPERATION="${OP_DIR##*/}"; valid_operation "${RESOURCE_OPERATION}" || continue
                FOUND=true; inspect_operation "${RESOURCE_OPERATION}" || FAILED=1
            done
            [[ "${FOUND}" == true ]] || emit_state "${COMMAND_OPERATION}" clean no_state
            ((FAILED == 0)) || exit 1
        fi
        ;;
esac
