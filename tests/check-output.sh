#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
BASH_BIN="${BASH:-bash}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/lib" "${SANDBOX}/nemesis"
cp "${ROOT}"/[0-9][0-9]-*.sh "${SANDBOX}/"
for library in operation.sh json.sh cli.sh hosts.sh util.sh test_runner.sh; do
    cp "${ROOT}/lib/${library}" "${SANDBOX}/lib/${library}"
done
cat > "${SANDBOX}/lib/init.sh" <<'INIT'
SINGLE_HOST=default-node
DC_HOSTS=(default-dc-a default-dc-b)
if [[ "${EMPTY_DC:-false}" == true ]]; then DC_HOSTS=(); fi
DC_ALT_HOSTS=(default-alt)
DEFAULT_CPU_PERCENT=50
DEFAULT_BLADE_TIMEOUT=60
DEFAULT_NET_DELAY=50
DEFAULT_NET_LOSS=10
DEFAULT_BW_RATE=500
CHAOS_DISK_RESTART_STORAGE=false
YDB_PORTS=2135
for library in operation json cli hosts util test_runner; do source "${SCRIPT_DIR}/lib/${library}.sh"; done
log() { printf '%s\n' "$*"; }
record_check() {
    printf '%s\n' "$1" >> "${TEST_CALLS}"
    printf 'checked %s\n' "$1"
    if [[ "$1" == "${FAIL_HOST:-}" ]]; then return 7; fi
}
INIT
for nemesis in blade tc iptables disk proc systemd; do
    printf 'nemesis_%s_check() { record_check "$@"; }\n' "${nemesis}" > "${SANDBOX}/nemesis/${nemesis}.sh"
done
printf 'nemesis_systemd_upgrade_check() { record_check "$@"; }\n' >> "${SANDBOX}/nemesis/systemd.sh"
export TEST_CALLS="${SANDBOX}/calls"
for script in "${SANDBOX}"/[0-9][0-9]-*.sh; do
    : > "${TEST_CALLS}"
    "${BASH_BIN}" "${script}" --json --check --hosts selected-a,selected-b > "${SANDBOX}/stdout" 2> "${SANDBOX}/stderr"
    [[ "$(sort "${TEST_CALLS}")" == $'selected-a\nselected-b' ]]
    jq -se 'length == 2 and all(.[]; .action == "check" and .hosts == ["selected-a", "selected-b"])
        and .[0].event == "check" and .[0].exitCode == null
        and .[1].event == "complete" and .[1].exitCode == 0' "${SANDBOX}/stdout" >/dev/null
    : > "${TEST_CALLS}"
    "${BASH_BIN}" "${script}" --check another-node > "${SANDBOX}/stdout"
    [[ "$(cat "${TEST_CALLS}")" == another-node ]]
    [[ "$(cat "${SANDBOX}/stdout")" == 'checked another-node' ]]
    : > "${TEST_CALLS}"
    "${BASH_BIN}" "${script}" --check --dc >/dev/null
    [[ "$(sort "${TEST_CALLS}")" == $'default-dc-a\ndefault-dc-b' ]]
    : > "${TEST_CALLS}"
    if FAIL_HOST=selected-a "${BASH_BIN}" "${script}" --json --check --hosts selected-a,selected-b > "${SANDBOX}/stdout" 2>/dev/null; then
        printf '%s: failed check was accepted\n' "${script}" >&2
        exit 1
    fi
    [[ "$(sort "${TEST_CALLS}")" == $'selected-a\nselected-b' ]]
    jq -se 'length == 1 and .[0].event == "complete" and .[0].result == "command_failed"
        and .[0].exitCode != 0' "${SANDBOX}/stdout" >/dev/null
    : > "${TEST_CALLS}"
    if EMPTY_DC=true "${BASH_BIN}" "${script}" --json --check --dc > "${SANDBOX}/stdout" 2>/dev/null; then
        printf '%s: empty group was accepted\n' "${script}" >&2
        exit 1
    fi
    [[ ! -s "${TEST_CALLS}" ]]
    jq -se 'length == 1 and .[0].hosts == [] and .[0].exitCode != 0' "${SANDBOX}/stdout" >/dev/null
    for invalid in '' 'selected-a,' ',selected-a' 'selected-a,,selected-b'; do
        : > "${TEST_CALLS}"
        if "${BASH_BIN}" "${script}" --json --check --hosts "${invalid}" > "${SANDBOX}/stdout" 2>/dev/null; then
            printf '%s: invalid explicit targets were accepted\n' "${script}" >&2
            exit 1
        fi
        [[ ! -s "${TEST_CALLS}" ]]
        jq -se 'length == 1 and .[0].exitCode != 0' "${SANDBOX}/stdout" >/dev/null
    done
done
printf 'all numbered check commands preserve targets and JSON results\n'
