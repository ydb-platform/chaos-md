#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="${ROOT}/nemesis/tc-remote.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/bin" "${TMP}/tc"

cat > "${TMP}/bin/flock" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_FLOCK_FAIL:-false}" == true ]] && exit 1
exit 0
SH

cat > "${TMP}/bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --signal=KILL ]] && shift
shift
printf '%s\n' "$*" >> "${FAKE_TIMEOUT_LOG:?}"
exec "$@"
SH

cat > "${TMP}/bin/tc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_TC_STATE:?}"
if [[ "${1:-}" == -batch ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
        "$0" ${line}
    done < "$2"
    exit 0
fi
[[ "${1:-}" == qdisc || "${1:-}" == filter ]] || exit 2

if [[ "$1" == filter ]]; then
    exit 0
fi

action="${2:-}"
iface=""
i=1
while ((i <= $#)); do
    if [[ "${!i}" == dev ]]; then
        ((i += 1))
        iface="${!i}"
        break
    fi
    ((i += 1))
done
[[ -n "${iface}" ]] || exit 2
file="${state}/${iface}"

case "${action}" in
    show)
        [[ -f "${file}" ]] && cat "${file}"
        exit 0
        ;;
    del)
        rm -f "${file}"
        ;;
    replace|add)
        if [[ "${FAKE_TC_FAIL_IFACE:-}" == "${iface}" && " $* " == *" root "* ]]; then
            exit 42
        fi
        if [[ " $* " == *" root "* ]]; then
            if [[ " $* " == *" tbf "* ]]; then
                printf '%s\n' 'qdisc tbf 8001: root' > "${file}"
            else
                printf '%s\n' 'qdisc prio 1: root' > "${file}"
            fi
        elif [[ " $* " == *" netem "* ]]; then
            printf '%s\n' 'qdisc netem 10: parent 1:1' >> "${file}"
        fi
        ;;
    *) exit 2 ;;
esac
SH

chmod +x "${TMP}/bin/flock" "${TMP}/bin/timeout" "${TMP}/bin/tc"
export PATH="${TMP}/bin:${PATH}"
export FAKE_TC_STATE="${TMP}/tc"
export FAKE_TIMEOUT_LOG="${TMP}/timeout.log"
export CHAOS_TC_BOOT_ID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee

OP1=11111111111111111111111111111111
OP2=22222222222222222222222222222222
OP3=33333333333333333333333333333333
STATE="${TMP}/state"

run_remote() {
    bash "${REMOTE}" "$@"
}

assert_absent() {
    [[ ! -e "$1" ]] || { echo "Ожидалось отсутствие $1" >&2; exit 1; }
}

assert_present() {
    [[ -e "$1" ]] || { echo "Ожидалось наличие $1" >&2; exit 1; }
}

run_remote teardown "${OP1}" "${STATE}" eth0
if run_remote apply-netem "${OP1}" "${STATE}" 30 eth0 2135 4 'delay 50ms'; then
    echo 'Отмененная операция запустилась' >&2
    exit 1
fi
assert_absent "${TMP}/tc/eth0"

rm -rf "${STATE}"
run_remote apply-netem "${OP1}" "${STATE}" 30 eth0 2135 4 'delay 50ms'
if run_remote apply-tbf "${OP2}" "${STATE}" 30 eth0 10 1600; then
    echo 'Конфликт владельцев не был отклонен' >&2
    exit 1
fi
grep -q 'qdisc prio 1: root' "${TMP}/tc/eth0"
run_remote teardown "${OP1}" "${STATE}" eth0
assert_absent "${TMP}/tc/eth0"

rm -rf "${STATE}"
export FAKE_TC_FAIL_IFACE=eth1
if run_remote apply-tbf "${OP1}" "${STATE}" 30 eth0,eth1 10 1600; then
    echo 'Частичная ошибка применения была принята' >&2
    exit 1
fi
unset FAKE_TC_FAIL_IFACE
assert_absent "${TMP}/tc/eth0"
assert_absent "${TMP}/tc/eth1"
assert_absent "${STATE}/owners/tc.eth0"
assert_absent "${STATE}/owners/tc.eth1"

rm -rf "${STATE}"
run_remote apply-netem "${OP1}" "${STATE}" 30 eth0 2135 4 'loss 2%'
TIMER_PID="$(cat "${STATE}/operations/${OP1}/timer.pid")"
run_remote apply-netem "${OP1}" "${STATE}" 30 eth0 2135 4 'loss 2%' | grep -q 'state=active'
[[ "$(cat "${STATE}/operations/${OP1}/timer.pid")" == "${TIMER_PID}" ]]
RECOVER1="${STATE}/operations/${OP1}/recover.sh"
assert_present "${RECOVER1}"
run_remote teardown "${OP1}" "${STATE}" eth0
run_remote apply-tbf "${OP2}" "${STATE}" 30 eth0 10 1600
run_remote check "${OP2}" "${OP2}" "${STATE}" eth0 | grep -q 'state=active'
bash "${RECOVER1}" "${OP1}" "${STATE}" 0
grep -q 'qdisc tbf 8001: root' "${TMP}/tc/eth0"
grep -q "${OP2}" "${STATE}/owners/tc.eth0"
run_remote teardown "${OP2}" "${STATE}" eth0
run_remote check "${OP2}" "${OP2}" "${STATE}" eth0 | grep -q 'state=clean'

run_remote apply-tbf "${OP3}" "${STATE}" 30 eth0 10 1600
run_remote teardown-all "${OP3}" "${STATE}" eth0
run_remote check "${OP3}" any "${STATE}" eth0 | grep -q 'state=clean'

rm -rf "${STATE}"
mkdir -p "${STATE}/owners"
printf '%s\n' broken > "${STATE}/owners/tc.eth0"
if run_remote apply-tbf "${OP1}" "${STATE}" 30 eth0 10 1600; then
    echo 'Поврежденный владелец был перезаписан' >&2
    exit 1
fi
grep -q '^broken$' "${STATE}/owners/tc.eth0"
assert_absent "${TMP}/tc/eth0"
run_remote teardown-all "${OP2}" "${STATE}" eth0
assert_absent "${STATE}/owners/tc.eth0"

rm -rf "${STATE}"
printf '%s\n' 'qdisc cake 8001: root' > "${TMP}/tc/eth0"
if run_remote apply-tbf "${OP1}" "${STATE}" 30 eth0 10 1600; then
    echo 'Неподдерживаемый исходный qdisc был заменен' >&2
    exit 1
fi
grep -q 'qdisc cake 8001: root' "${TMP}/tc/eth0"
assert_absent "${STATE}/owners/tc.eth0"
rm -f "${TMP}/tc/eth0"

rm -rf "${STATE}"
export FAKE_FLOCK_FAIL=true
if run_remote apply-tbf "${OP1}" "${STATE}" 30 eth0 10 1600; then
    echo 'Ошибка блокировки была принята' >&2
    exit 1
fi
unset FAKE_FLOCK_FAIL
assert_absent "${TMP}/tc/eth0"
grep -q 'qdisc show dev eth0' "${FAKE_TIMEOUT_LOG}"

echo 'tc operation tests: ok'
