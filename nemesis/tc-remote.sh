#!/usr/bin/env bash

set -euo pipefail
umask 077

fail() {
    echo "tc operation: $*" >&2
    exit 1
}

valid_operation() {
    [[ "${1:-}" =~ ^[0-9a-f]{32}$ ]]
}

valid_state_root() {
    [[ "${1:-}" =~ ^/[A-Za-z0-9._/-]+$ ]]
}

valid_iface() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

valid_ifaces() {
    [[ "${1:-}" != ,* && "${1:-}" != *, && "${1:-}" != *,,* ]] || return 1
    local iface seen=""
    local values=()
    IFS=',' read -r -a values <<< "${1:-}"
    ((${#values[@]} > 0 && ${#values[@]} <= 16)) || return 1
    for iface in "${values[@]}"; do
        valid_iface "${iface}" || return 1
        [[ ",${seen}," != *",${iface},"* ]] || return 1
        seen="${seen:+${seen},}${iface}"
    done
}

valid_ports() {
    local port
    local values=()
    IFS=',' read -r -a values <<< "${1:-}"
    ((${#values[@]} > 0 && ${#values[@]} <= 4096)) || return 1
    for port in "${values[@]}"; do
        [[ "${port}" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
        ((port <= 65535)) || return 1
    done
}

read_owner() {
    local file="$1" value=""
    [[ -f "${file}" ]] || return 1
    IFS= read -r value < "${file}" || true
    valid_operation "${value}" || return 1
    printf '%s' "${value}"
}

write_value() {
    local file="$1" value="$2" tmp
    tmp="${file}.tmp.$$"
    printf '%s\n' "${value}" > "${tmp}"
    mv -f "${tmp}" "${file}"
}

emit_state() {
    local iface="$1" raw_state="$2" code="${3:-ok}" state recovery_armed=false cancelled=false
    case "${raw_state}" in
        active|clean) state="${raw_state}" ;;
        *) state=check_failed ;;
    esac
    [[ "${state}" == active ]] && recovery_armed=true
    [[ "${ACTION}" == teardown || "${ACTION}" == teardown-all ]] && cancelled=true
    [[ -e "${STATE_ROOT}/operations/${COMMAND_OPERATION}/cancelled" ]] && cancelled=true
    printf 'observation operation=%s resource=tc:%s state=%s boot_id=%s revision=%s recovery_armed=%s cancelled=%s code=%s\n' \
        "${COMMAND_OPERATION}" "${iface}" "${state}" "${HOST_BOOT_ID}" "${HOST_REVISION}" \
        "${recovery_armed}" "${cancelled}" "${code}"
}

run_tc() {
    "${TIMEOUT_BIN}" --signal=KILL 20s "${TC_BIN}" "$@"
}

next_host_revision() {
    local file="${STATE_ROOT}/revision" value=0
    if [[ -f "${file}" ]]; then
        IFS= read -r value < "${file}" || true
        [[ "${value}" =~ ^[0-9]+$ ]] || fail 'invalid host revision'
    fi
    ((value += 1))
    write_value "${file}" "${value}"
    printf '%s' "${value}"
}

qdisc_is_active() {
    local iface="$1" mode="$2" output
    output="$(run_tc qdisc show dev "${iface}")" || return 2
    case "${mode}" in
        netem)
            grep -Eq 'qdisc prio 1:.* root' <<< "${output}" &&
                grep -Eq 'qdisc netem 10:.* parent 1:1' <<< "${output}"
            ;;
        tbf)
            grep -Eq 'qdisc tbf .* root' <<< "${output}"
            ;;
        *) return 2 ;;
    esac
}

qdisc_root_kind() {
    local output="$1" line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^qdisc\ ([a-z0-9_]+)\ .*root ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<< "${output}"
    printf '%s' none
}

qdisc_is_clean() {
    local iface="$1" baseline_file="${2:-}" output expected=none actual
    output="$(run_tc qdisc show dev "${iface}")" || return 2
    ! grep -Eq 'qdisc (prio 1:.* root|tbf .* root|netem 10:.* parent 1:1)' <<< "${output}" || return 1
    [[ -n "${baseline_file}" ]] || return 0
    [[ -f "${baseline_file}" ]] || return 2
    IFS= read -r expected < "${baseline_file}" || true
    actual="$(qdisc_root_kind "${output}")"
    [[ "${actual}" == "${expected}" ]]
}

capture_baselines() {
    local op_dir="$1" resources="$2" iface output kind
    while IFS= read -r iface || [[ -n "${iface}" ]]; do
        output="$(run_tc qdisc show dev "${iface}")" || return 1
        kind="$(qdisc_root_kind "${output}")"
        case "${kind}" in
            none|mq|noqueue) ;;
            *) emit_state "${iface}" check_failed unsupported_root_qdisc; return 1 ;;
        esac
        write_value "${op_dir}/baseline.${iface}" "${kind}"
    done < "${resources}"
}

write_recovery_script() {
    local file="$1"
    cat > "${file}" <<'RECOVER'
#!/usr/bin/env bash
set -euo pipefail
umask 077

operation="$1"
state_root="$2"
delay="$3"
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

tc_bin="$(command -v tc)"
timeout_bin="$(command -v timeout)"
[[ -n "${tc_bin}" && -n "${timeout_bin}" ]] || exit 1
run_tc() { "${timeout_bin}" --signal=KILL 20s "${tc_bin}" "$@"; }
root_kind() {
    local text="$1" line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^qdisc\ ([a-z0-9_]+)\ .*root ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return
        fi
    done <<< "${text}"
    printf '%s' none
}

resources="${op_dir}/resources"
failed=0
[[ -f "${resources}" ]] || exit 0

while IFS= read -r iface || [[ -n "${iface}" ]]; do
    [[ "${iface}" =~ ^[A-Za-z0-9_.:-]+$ ]] || { failed=1; continue; }
    owner_file="${state_root}/owners/tc.${iface}"
    owner=""
    if [[ -f "${owner_file}" ]]; then
        IFS= read -r owner < "${owner_file}" || true
        [[ "${owner}" =~ ^[0-9a-f]{32}$ ]] || { failed=1; continue; }
    fi
    [[ "${owner}" == "${operation}" ]] || continue
    clean=false
    baseline_file="${op_dir}/baseline.${iface}"
    expected=""
    [[ -f "${baseline_file}" ]] && IFS= read -r expected < "${baseline_file}" || true
    for _ in 1 2 3; do
        run_tc qdisc del dev "${iface}" root >/dev/null 2>&1 || true
        output="$(run_tc qdisc show dev "${iface}")" || { sleep 1; continue; }
        if ! grep -Eq 'qdisc (prio 1:.* root|tbf .* root|netem 10:.* parent 1:1)' <<< "${output}" \
            && [[ -n "${expected}" && "$(root_kind "${output}")" == "${expected}" ]]; then
            clean=true
            break
        fi
        sleep 1
    done
    [[ "${clean}" == true ]] || { failed=1; continue; }
    current=""
    [[ -f "${owner_file}" ]] && IFS= read -r current < "${owner_file}" || true
    [[ "${current}" == "${operation}" ]] && rm -f "${owner_file}"
done < "${resources}"

if ((failed)); then
    printf '%s\n' cleanup_failed > "${op_dir}/phase"
    exit 1
fi
printf '%s\n' expired > "${op_dir}/phase"
RECOVER
    chmod 700 "${file}"
}

cleanup_owned() {
    local operation="$1" resources="$2" final_phase="$3"
    local iface owner_file owner failed=0
    [[ -f "${resources}" ]] || return 0
    while IFS= read -r iface || [[ -n "${iface}" ]]; do
        valid_iface "${iface}" || { failed=1; continue; }
        owner_file="${STATE_ROOT}/owners/tc.${iface}"
        if [[ -e "${owner_file}" ]]; then
            owner="$(read_owner "${owner_file}" 2>/dev/null)" || {
                emit_state "${iface}" cleanup_failed invalid_owner
                failed=1
                continue
            }
        else
            owner=""
        fi
        [[ "${owner}" == "${operation}" ]] || continue
        run_tc qdisc del dev "${iface}" root >/dev/null 2>&1 || true
        if qdisc_is_clean "${iface}" "${STATE_ROOT}/operations/${operation}/baseline.${iface}"; then
            owner="$(read_owner "${owner_file}" 2>/dev/null || true)"
            [[ "${owner}" == "${operation}" ]] && rm -f "${owner_file}"
            emit_state "${iface}" clean ok
        else
            emit_state "${iface}" cleanup_failed qdisc_remains
            failed=1
        fi
    done < "${resources}"
    if ((failed)); then
        write_value "${STATE_ROOT}/operations/${operation}/phase" cleanup_failed
        return 1
    fi
    write_value "${STATE_ROOT}/operations/${operation}/phase" "${final_phase}"
}

reserve_resources() {
    local operation="$1" resources="$2" iface owner_file owner
    while IFS= read -r iface || [[ -n "${iface}" ]]; do
        owner_file="${STATE_ROOT}/owners/tc.${iface}"
        if [[ -e "${owner_file}" ]]; then
            owner="$(read_owner "${owner_file}" 2>/dev/null)" || {
                emit_state "${iface}" invalid_owner invalid_owner
                return 1
            }
        else
            owner=""
        fi
        if [[ -n "${owner}" && "${owner}" != "${operation}" ]]; then
            emit_state "${iface}" conflict owner_conflict
            return 1
        fi
    done < "${resources}"
    while IFS= read -r iface || [[ -n "${iface}" ]]; do
        write_value "${STATE_ROOT}/owners/tc.${iface}" "${operation}"
    done < "${resources}"
}

apply_netem_iface() {
    local iface="$1" ports="$2" stacks="$3" params="$4" port hex
    local port_values=()
    local batch="${STATE_ROOT}/operations/${COMMAND_OPERATION}/tc.${iface}.batch"
    printf 'qdisc replace dev %s root handle 1: prio\n' "${iface}" > "${batch}"
    printf 'qdisc replace dev %s parent 1:1 handle 10: netem %s limit 262144\n' "${iface}" "${params}" >> "${batch}"
    if [[ "${stacks}" == *4* ]]; then
        printf 'filter add dev %s protocol ip parent 1:0 prio 3 u32 match ip src 0.0.0.0/0 flowid 1:2\n' "${iface}" >> "${batch}"
        IFS=',' read -r -a port_values <<< "${ports}"
        for port in "${port_values[@]}"; do
            printf 'filter add dev %s protocol ip parent 1:0 prio 2 u32 match ip sport %s 0xffff flowid 1:1\n' "${iface}" "${port}" >> "${batch}"
            printf 'filter add dev %s protocol ip parent 1:0 prio 2 u32 match ip dport %s 0xffff flowid 1:1\n' "${iface}" "${port}" >> "${batch}"
        done
    fi
    if [[ "${stacks}" == *6* ]]; then
        for hex in '0x0 0xffff' '0x1 0xffff' '0x2 0xfffe' '0x4 0xfffc' '0x8 0xfff8' \
            '0x10 0xfff0' '0x20 0xffe0' '0x40 0xffc0' '0x80 0xff80' \
            '0x100 0xff00' '0x200 0xfe00' '0x400 0xfc00' '0x800 0xf800' \
            '0x1000 0xf000' '0x2000 0xe000' '0x4000 0xc000' '0x8000 0x8000'; do
            printf 'filter add dev %s protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport %s flowid 1:2\n' "${iface}" "${hex}" >> "${batch}"
        done
        IFS=',' read -r -a port_values <<< "${ports}"
        for port in "${port_values[@]}"; do
            printf -v hex '0x%x' "${port}"
            printf 'filter add dev %s protocol ipv6 parent 1:0 prio 2 u32 match ip6 sport %s 0xffff flowid 1:1\n' "${iface}" "${hex}" >> "${batch}"
            printf 'filter add dev %s protocol ipv6 parent 1:0 prio 2 u32 match ip6 dport %s 0xffff flowid 1:1\n' "${iface}" "${hex}" >> "${batch}"
        done
    fi
    printf 'qdisc replace dev %s parent 1:2 handle 20: netem delay 0ms limit 262144\n' "${iface}" >> "${batch}"
    run_tc -batch "${batch}"
}

apply_operation() {
    local action="$1" operation="$2" timeout_s="$3" ifaces="$4" config="$5"
    shift 5
    local op_dir resources iface owner mode timer_pid timer_ready failed=0
    op_dir="${STATE_ROOT}/operations/${operation}"
    resources="${op_dir}/resources"
    mode="${action#apply-}"

    valid_operation "${operation}" || fail 'invalid operation'
    [[ "${timeout_s}" =~ ^[1-9][0-9]*$ ]] || fail 'invalid timeout'
    valid_ifaces "${ifaces}" || fail 'invalid interfaces'
    mkdir -p "${op_dir}"
    [[ ! -L "${op_dir}" ]] || fail 'operation path is a symlink'

    [[ ! -e "${op_dir}/cancelled" ]] || fail 'operation was cancelled'
    if [[ -f "${op_dir}/config" && "$(cat "${op_dir}/config")" != "${config}" ]]; then
        fail 'operation configuration changed'
    fi
    write_value "${op_dir}/config" "${config}"
    tr ',' '\n' <<< "${ifaces}" > "${resources}.tmp.$$"
    mv -f "${resources}.tmp.$$" "${resources}"

    if [[ -f "${op_dir}/phase" && "$(cat "${op_dir}/phase")" == active ]]; then
        failed=0
        while IFS= read -r iface || [[ -n "${iface}" ]]; do
            owner="$(read_owner "${STATE_ROOT}/owners/tc.${iface}" 2>/dev/null || true)"
            [[ "${owner}" == "${operation}" ]] && qdisc_is_active "${iface}" "${mode}" || failed=1
        done < "${resources}"
        if ((failed == 0)); then
            while IFS= read -r iface || [[ -n "${iface}" ]]; do
                emit_state "${iface}" active ok
            done < "${resources}"
            return 0
        fi
        cleanup_owned "${operation}" "${resources}" retry_required || fail 'inconsistent previous apply could not be cleaned'
        fail 'inconsistent previous apply was cleaned; use a new operation'
    elif [[ -f "${op_dir}/phase" ]]; then
        cleanup_owned "${operation}" "${resources}" retry_required || fail 'incomplete previous apply could not be cleaned'
        fail 'incomplete previous apply was cleaned; use a new operation'
    fi

    capture_baselines "${op_dir}" "${resources}" || fail 'unsupported or unreadable root qdisc'

    write_recovery_script "${op_dir}/recover.sh"
    bash -n "${op_dir}/recover.sh" || fail 'recovery timer script is invalid'
    rm -f "${op_dir}/timer.ready"
    write_value "${op_dir}/phase" armed
    nohup "${op_dir}/recover.sh" "${operation}" "${STATE_ROOT}" "${timeout_s}" </dev/null >/dev/null 2>&1 &
    timer_pid=$!
    write_value "${op_dir}/timer.pid" "${timer_pid}"
    timer_ready=false
    for _ in {1..100}; do
        if [[ -f "${op_dir}/timer.ready" ]]; then
            timer_ready=true
            break
        fi
        kill -0 "${timer_pid}" 2>/dev/null || break
        sleep 0.02
    done
    [[ "${timer_ready}" == true ]] || {
        cleanup_owned "${operation}" "${resources}" timer_failed || true
        fail 'recovery timer did not become ready'
    }

    reserve_resources "${operation}" "${resources}" || fail 'resource is owned by another operation'

    write_value "${op_dir}/phase" applying
    while IFS= read -r iface || [[ -n "${iface}" ]]; do
        if [[ "${action}" == apply-netem ]]; then
            apply_netem_iface "${iface}" "$@" || { failed=1; break; }
        else
            run_tc qdisc replace dev "${iface}" root tbf rate "$1"mbit burst "$2" latency 50ms || { failed=1; break; }
        fi
        qdisc_is_active "${iface}" "${mode}" || { failed=1; break; }
    done < "${resources}"

    if ((failed)); then
        : > "${op_dir}/cancelled"
        cleanup_owned "${operation}" "${resources}" apply_failed || true
        fail 'apply failed and compensation was attempted'
    fi
    write_value "${op_dir}/phase" active
    while IFS= read -r iface || [[ -n "${iface}" ]]; do
        emit_state "${iface}" active ok
    done < "${resources}"
}

ACTION="${1:-}"
shift || true

case "${ACTION}" in
    apply-netem)
        (($# == 7)) || fail 'apply-netem expects 7 arguments'
        OPERATION="$1"; STATE_ROOT="$2"; TIMEOUT_S="$3"; IFACES="$4"
        COMMAND_OPERATION="${OPERATION}"
        PORTS="$5"; STACKS="$6"; PARAMS="$7"
        valid_ports "${PORTS}" || fail 'invalid ports'
        [[ "${STACKS}" == 4 || "${STACKS}" == 6 || "${STACKS}" == 46 ]] || fail 'invalid stacks'
        [[ "${PARAMS}" =~ ^delay\ [0-9]+([.][0-9]+)?ms$ || "${PARAMS}" =~ ^loss\ [0-9]+([.][0-9]+)?%$ ]] || fail 'invalid netem parameters'
        CONFIG="netem|${IFACES}|${PORTS}|${STACKS}|${PARAMS}"
        ;;
    apply-tbf)
        (($# == 6)) || fail 'apply-tbf expects 6 arguments'
        OPERATION="$1"; STATE_ROOT="$2"; TIMEOUT_S="$3"; IFACES="$4"
        COMMAND_OPERATION="${OPERATION}"
        RATE="$5"; BURST="$6"
        [[ "${RATE}" =~ ^[1-9][0-9]*$ && "${BURST}" =~ ^[1-9][0-9]*$ ]] || fail 'invalid tbf parameters'
        CONFIG="tbf|${IFACES}|${RATE}|${BURST}"
        ;;
    teardown)
        (($# == 3)) || fail 'teardown expects 3 arguments'
        OPERATION="$1"; STATE_ROOT="$2"; IFACES="$3"
        COMMAND_OPERATION="${OPERATION}"
        valid_operation "${OPERATION}" || fail 'invalid operation'
        valid_ifaces "${IFACES}" || fail 'invalid interfaces'
        ;;
    teardown-all)
        (($# == 3)) || fail 'teardown-all expects 3 arguments'
        COMMAND_OPERATION="$1"; STATE_ROOT="$2"; IFACES="$3"
        valid_operation "${COMMAND_OPERATION}" || fail 'invalid command operation'
        valid_ifaces "${IFACES}" || fail 'invalid interfaces'
        ;;
    check)
        (($# == 4)) || fail 'check expects 4 arguments'
        COMMAND_OPERATION="$1"; OPERATION="$2"; STATE_ROOT="$3"; IFACES="$4"
        valid_operation "${COMMAND_OPERATION}" || fail 'invalid command operation'
        [[ "${OPERATION}" == any ]] || valid_operation "${OPERATION}" || fail 'invalid operation'
        valid_ifaces "${IFACES}" || fail 'invalid interfaces'
        ;;
    *) fail 'unknown action' ;;
esac

valid_state_root "${STATE_ROOT}" || fail 'invalid state root'
command -v flock >/dev/null 2>&1 || fail 'flock is required'
command -v nohup >/dev/null 2>&1 || fail 'nohup is required'
TC_BIN="$(command -v tc)" || fail 'tc is required'
TIMEOUT_BIN="$(command -v timeout)" || fail 'timeout is required'
mkdir -p "${STATE_ROOT}/operations" "${STATE_ROOT}/owners"
[[ ! -L "${STATE_ROOT}" && ! -L "${STATE_ROOT}/operations" && ! -L "${STATE_ROOT}/owners" ]] || fail 'state path is a symlink'
exec 9> "${STATE_ROOT}/lock"
flock -w 5 -x 9 || fail 'metadata lock timed out'
HOST_BOOT_ID="${CHAOS_TC_BOOT_ID:-}"
if [[ -z "${HOST_BOOT_ID}" && -f /proc/sys/kernel/random/boot_id ]]; then
    IFS= read -r HOST_BOOT_ID < /proc/sys/kernel/random/boot_id || true
fi
[[ "${HOST_BOOT_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail 'boot_id is unavailable or invalid'
HOST_BOOT_ID="$(printf '%s' "${HOST_BOOT_ID}" | tr 'A-F' 'a-f')"
HOST_REVISION="$(next_host_revision)"

case "${ACTION}" in
    apply-netem)
        apply_operation "${ACTION}" "${OPERATION}" "${TIMEOUT_S}" "${IFACES}" "${CONFIG}" "${PORTS}" "${STACKS}" "${PARAMS}"
        ;;
    apply-tbf)
        apply_operation "${ACTION}" "${OPERATION}" "${TIMEOUT_S}" "${IFACES}" "${CONFIG}" "${RATE}" "${BURST}"
        ;;
    teardown)
        OP_DIR="${STATE_ROOT}/operations/${OPERATION}"
        mkdir -p "${OP_DIR}"
        [[ ! -L "${OP_DIR}" ]] || fail 'operation path is a symlink'
        : > "${OP_DIR}/cancelled"
        if [[ ! -f "${OP_DIR}/resources" ]]; then
            tr ',' '\n' <<< "${IFACES}" > "${OP_DIR}/resources"
        fi
        cleanup_owned "${OPERATION}" "${OP_DIR}/resources" cancelled
        ;;
    teardown-all)
        IFS=',' read -r -a TEARDOWN_IFACES <<< "${IFACES}"
        TEARDOWN_FAILED=0
        for IFACE in "${TEARDOWN_IFACES[@]}"; do
            OWNER_FILE="${STATE_ROOT}/owners/tc.${IFACE}"
            OWNER="$(read_owner "${OWNER_FILE}" 2>/dev/null || true)"
            if [[ -n "${OWNER}" ]]; then
                OWNER_DIR="${STATE_ROOT}/operations/${OWNER}"
                mkdir -p "${OWNER_DIR}"
                : > "${OWNER_DIR}/cancelled"
                write_value "${OWNER_DIR}/phase" cancelling
            fi
            run_tc qdisc del dev "${IFACE}" root >/dev/null 2>&1 || true
            if qdisc_is_clean "${IFACE}"; then
                rm -f "${OWNER_FILE}"
                emit_state "${IFACE}" clean ok
            else
                emit_state "${IFACE}" cleanup_failed qdisc_remains
                TEARDOWN_FAILED=1
            fi
        done
        ((TEARDOWN_FAILED == 0)) || exit 1
        ;;
    check)
        IFS=',' read -r -a CHECK_IFACES <<< "${IFACES}"
        CHECK_FAILED=0
        for IFACE in "${CHECK_IFACES[@]}"; do
            OWNER_FILE="${STATE_ROOT}/owners/tc.${IFACE}"
            if [[ -e "${OWNER_FILE}" ]]; then
                OWNER="$(read_owner "${OWNER_FILE}" 2>/dev/null)" || {
                    emit_state "${IFACE}" invalid_owner invalid_owner
                    CHECK_FAILED=1
                    continue
                }
            else
                OWNER=""
            fi
            EXPECTED="${OPERATION}"
            [[ "${EXPECTED}" == any ]] && EXPECTED="${OWNER}"
            MODE=""
            if [[ -n "${OWNER}" && -f "${STATE_ROOT}/operations/${OWNER}/config" ]]; then
                IFS='|' read -r MODE _ < "${STATE_ROOT}/operations/${OWNER}/config" || true
            fi
            if [[ -n "${EXPECTED}" && -z "${OWNER}" ]]; then
                PHASE=""
                BASELINE_FILE=""
                [[ -f "${STATE_ROOT}/operations/${EXPECTED}/phase" ]] && IFS= read -r PHASE < "${STATE_ROOT}/operations/${EXPECTED}/phase" || true
                [[ -f "${STATE_ROOT}/operations/${EXPECTED}/baseline.${IFACE}" ]] \
                    && BASELINE_FILE="${STATE_ROOT}/operations/${EXPECTED}/baseline.${IFACE}"
                if [[ "${PHASE}" == cancelled || "${PHASE}" == expired ]] && qdisc_is_clean "${IFACE}" "${BASELINE_FILE}"; then
                    emit_state "${IFACE}" clean ok
                else
                    emit_state "${IFACE}" conflict owner_missing
                    CHECK_FAILED=1
                fi
            elif [[ -n "${EXPECTED}" && "${OWNER}" != "${EXPECTED}" ]]; then
                emit_state "${IFACE}" conflict owner_conflict
                CHECK_FAILED=1
            elif [[ -n "${OWNER}" && ( "${MODE}" == netem || "${MODE}" == tbf ) ]]; then
                if qdisc_is_active "${IFACE}" "${MODE}"; then
                    emit_state "${IFACE}" active ok
                else
                    emit_state "${IFACE}" check_failed qdisc_mismatch
                    CHECK_FAILED=1
                fi
            elif qdisc_is_clean "${IFACE}"; then
                emit_state "${IFACE}" clean ok
            else
                emit_state "${IFACE}" unowned_active unowned_active
                CHECK_FAILED=1
            fi
        done
        ((CHECK_FAILED == 0)) || exit 1
        ;;
esac
