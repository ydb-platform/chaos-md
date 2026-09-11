#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="${ROOT}/nemesis/iptables-remote.sh"
TMP="$(mktemp -d)"
cleanup() {
    local file pid children child
    for file in "${TMP}"/state*/operations/*/timer.pid; do
        [[ -f "${file}" ]] || continue
        IFS= read -r pid < "${file}" || true
        [[ -n "${pid}" ]] || continue
        children="$(pgrep -P "${pid}" || true)"
        kill "${pid}" 2>/dev/null || true
        for child in ${children}; do kill "${child}" 2>/dev/null || true; done
    done
    rm -rf "${TMP}"
}
trap cleanup EXIT
mkdir -p "${TMP}/bin" "${TMP}/firewall/iptables" "${TMP}/firewall/ip6tables"

if command -v flock >/dev/null 2>&1; then
    ln -s "$(command -v flock)" "${TMP}/bin/flock"
else
cat > "${TMP}/bin/flock" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    echo 'flock is unavailable; lock behavior is not tested' >&2
fi

cat > "${TMP}/bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --signal=KILL ]] && shift
shift
exec "$@"
SH

cat > "${TMP}/bin/iptables" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
root="${FAKE_FIREWALL:?}/${name}"
[[ "${1:-}" != -w ]] || shift 2
action="${1:-}"; shift || true
chain="${1:-}"; shift || true
chain_file="${root}/chain.${chain}"
hook_file="${root}/hook.${chain}"
[[ "${FAKE_PROOF_FAIL:-}" != "${name}" || "${action}" != -S ]] || exit "${FAKE_PROOF_RC:-124}"
case "${action}" in
    -N) [[ ! -e "${chain_file}" ]] || exit 1; : > "${chain_file}"; [[ "${FAKE_CREATE_FAIL:-}" != "${name}" ]] ;;
    -S)
        if [[ -n "${chain}" ]]; then
            [[ -f "${chain_file}" ]] || exit 1
            printf '%s\n' "-N ${chain}"; cat "${chain_file}"
        else
            for file in "${root}"/chain.*; do
                [[ -f "${file}" ]] || continue
                printf '%s\n' "-N ${file##*/chain.}"; cat "${file}"
            done
            for file in "${root}"/hook.*; do
                [[ -f "${file}" ]] || continue
                while IFS= read -r jump; do printf '%s\n' "-A ${file##*/hook.} -j ${jump}"; done < "${file}"
            done
        fi
        ;;
    -A)
        [[ -f "${chain_file}" ]] || exit 1
        [[ "${FAKE_FAIL_STACK:-}" != "${name}" ]] || exit 42
        printf '%s\n' "-A ${chain} $*" >> "${chain_file}"
        ;;
    -I)
        [[ "${1:-}" == 1 && "${2:-}" == -j && -n "${3:-}" ]] || exit 2
        printf '%s\n' "${3}" >> "${hook_file}"
        ;;
    -C)
        if [[ "${chain}" != INPUT && "${chain}" != OUTPUT ]]; then
            [[ -f "${chain_file}" ]] && grep -Fxq -- "-A ${chain} $*" "${chain_file}"
            exit $?
        fi
        [[ "${1:-}" == -j && -n "${2:-}" ]] || exit 2
        [[ -f "${hook_file}" ]] && grep -Fxq "${2}" "${hook_file}"
        ;;
    -D)
        [[ "${1:-}" == -j && -n "${2:-}" ]] || exit 2
        [[ -f "${hook_file}" ]] || exit 1
        grep -Fxv "${2}" "${hook_file}" > "${hook_file}.new" || true
        mv "${hook_file}.new" "${hook_file}"
        ;;
    -F) [[ -f "${chain_file}" ]] || exit 1; : > "${chain_file}" ;;
    -X) [[ -f "${chain_file}" && ! -s "${chain_file}" ]] || exit 1; rm -f "${chain_file}" ;;
    *) exit 2 ;;
esac
SH

[[ -L "${TMP}/bin/flock" ]] || chmod +x "${TMP}/bin/flock"
chmod +x "${TMP}/bin/timeout" "${TMP}/bin/iptables"
cp "${TMP}/bin/iptables" "${TMP}/bin/ip6tables"
export PATH="${TMP}/bin:${PATH}"
export FAKE_FIREWALL="${TMP}/firewall"
export CHAOS_IPTABLES_BOOT_ID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee

OP1=11111111111111111111111111111111
OP2=22222222222222222222222222222222
OP3=33333333333333333333333333333333
STATE="${TMP}/state"
CHAIN1="YDB_CHAOS_${OP1:0:16}"
CHAIN2="YDB_CHAOS_${OP2:0:16}"

run_remote() { "${BASH}" "${REMOTE}" "$@"; }
state_index=0
next_state() { state_index=$((state_index + 1)); STATE="${TMP}/state${state_index}"; }

run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" >/dev/null 2>&1 || true
if run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" REJECT eth0 2135 46; then
    echo 'Отмененная операция iptables запустилась' >&2
    exit 1
fi

next_state
run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" REJECT eth0 2135,2136 46 | grep -q 'state=active'
[[ "$(wc -l < "${TMP}/firewall/iptables/chain.${CHAIN1}" | tr -d ' ')" == 8 ]]
[[ "$(wc -l < "${TMP}/firewall/ip6tables/chain.${CHAIN1}" | tr -d ' ')" == 8 ]]
run_remote check "${OP1}" "${OP1}" "${STATE}" "${CHAIN1}" | grep -q 'state=active'
export FAKE_PROOF_FAIL=iptables
if run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}"; then
    echo 'Ошибка проверки снятия iptables была принята' >&2
    exit 1
fi
unset FAKE_PROOF_FAIL
run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" | grep -q 'state=clean'
run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" | grep -q 'state=clean'
[[ ! -e "${TMP}/firewall/iptables/chain.${CHAIN1}" ]]
[[ ! -e "${TMP}/firewall/ip6tables/chain.${CHAIN1}" ]]

next_state
export FAKE_FAIL_STACK=ip6tables
if run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 46; then
    echo 'Частичное применение iptables было принято' >&2
    exit 1
fi
unset FAKE_FAIL_STACK
[[ ! -e "${TMP}/firewall/iptables/chain.${CHAIN1}" ]]
[[ ! -e "${TMP}/firewall/ip6tables/chain.${CHAIN1}" ]]

next_state
run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 4 >/dev/null
"${BASH}" "${STATE}/operations/${OP1}/recover.sh" "${OP1}" "${STATE}" 0
run_remote check "${OP1}" "${OP1}" "${STATE}" "${CHAIN1}" | grep -q 'state=clean'

next_state
run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 4 >/dev/null
printf '%s\n' broken > "${STATE}/owners/iptables.${CHAIN1}"
if run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}"; then
    echo 'Поврежденный владелец iptables был принят' >&2
    exit 1
fi
[[ -e "${TMP}/firewall/iptables/chain.${CHAIN1}" ]]
printf '%s\n' "${OP1}" > "${STATE}/owners/iptables.${CHAIN1}"
run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" >/dev/null

next_state
run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 4 >/dev/null
run_remote apply "${OP2}" "${STATE}" 600 "${CHAIN2}" DROP eth0 2135 4 >/dev/null
mkdir -p "${STATE}/operations/${OP3}"
printf '%s\n' 'netem|eth0|2135|4|loss 2%' > "${STATE}/operations/${OP3}/config"
teardown_all_output="$(run_remote teardown-all "${OP3}" "${STATE}")"
grep -q 'state=clean' <<< "${teardown_all_output}"
[[ ! -e "${TMP}/firewall/iptables/chain.${CHAIN1}" ]]
[[ ! -e "${TMP}/firewall/iptables/chain.${CHAIN2}" ]]
grep -q '^netem|' "${STATE}/operations/${OP3}/config"

failures=0
expect_failure() {
    local output rc=0 label="$1"; shift
    output="$("$@" 2>&1)" || rc=$?
    if ((rc == 0)) || [[ "${output}" == *state=clean* || "${output}" == *state=active* ]]; then
        echo "FAIL ${label}: rc=${rc} ${output}" >&2
        failures=$((failures + 1))
    fi
}

next_state
if ! run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" > "${TMP}/cancel.output"; then
    echo 'FAIL cancellation before apply cannot complete' >&2; failures=$((failures + 1))
fi
[[ -f "${STATE}/operations/${OP1}/cancelled" ]]
expect_failure 'delayed apply after cancellation' run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 4

next_state
run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 4 >/dev/null
export FAKE_PROOF_FAIL=iptables FAKE_PROOF_RC=1
expect_failure 'failed read with exit 1 is not clean evidence' run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}"
unset FAKE_PROOF_FAIL FAKE_PROOF_RC
run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" >/dev/null
printf '%s\n' "-A ${CHAIN1} -j ACCEPT" > "${TMP}/firewall/iptables/chain.${CHAIN1}"
"${BASH}" "${STATE}/operations/${OP1}/recover.sh" "${OP1}" "${STATE}" 0 || true
if [[ ! -s "${TMP}/firewall/iptables/chain.${CHAIN1}" ]]; then
    echo 'FAIL stale timer removed an unowned chain' >&2; failures=$((failures + 1))
fi
rm -f "${TMP}/firewall/iptables/chain.${CHAIN1}"

next_state
mkdir -p "${STATE}/operations/${OP1}"
printf '%s\n' "-A ${CHAIN1} -j ACCEPT" > "${TMP}/firewall/iptables/chain.${CHAIN1}"
expect_failure 'missing metadata does not prove absence' run_remote check "${OP1}" "${OP1}" "${STATE}" "${CHAIN1}"
rm -f "${TMP}/firewall/iptables/chain.${CHAIN1}"

next_state
run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 4 >/dev/null
cp "${STATE}/operations/${OP1}/iptables.config" "${TMP}/config"
printf '%s\n' "${CHAIN1}|DROP|eth0|2135|" > "${STATE}/operations/${OP1}/iptables.config"
expect_failure 'empty stacks cannot bypass inspection' run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}"
cp "${TMP}/config" "${STATE}/operations/${OP1}/iptables.config"
printf '%s\n' "${OP1}" > "${STATE}/owners/iptables.${CHAIN1}"
run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" >/dev/null

next_state
export FAKE_CREATE_FAIL=iptables
if run_remote apply "${OP1}" "${STATE}" 600 "${CHAIN1}" DROP eth0 2135 4 > "${TMP}/apply.output" 2>&1; then
    echo 'FAIL failed mutation was admitted' >&2; failures=$((failures + 1))
fi
unset FAKE_CREATE_FAIL
run_remote teardown "${OP1}" "${STATE}" "${CHAIN1}" >/dev/null

((failures == 0)) || exit 1
echo 'iptables operation tests: ok'
