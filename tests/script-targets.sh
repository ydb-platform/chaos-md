#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
BASH_BIN="${2:-bash}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/lib" "${SANDBOX}/nemesis"

SCRIPTS=(
    01-cpu-load.sh 02-mem-load.sh 03-disk-fail.sh
    04-net-delay.sh 05-net-loss.sh 06-net-drop.sh
    08-proc-freeze.sh 09-proc-kill.sh 11-dc-drop.sh
)
for script in "${SCRIPTS[@]}"; do cp "${ROOT}/${script}" "${SANDBOX}/${script}"; done
for library in json.sh cli.sh hosts.sh util.sh; do cp "${ROOT}/lib/${library}" "${SANDBOX}/lib/${library}"; done

cat > "${SANDBOX}/lib/init.sh" <<'INIT'
SINGLE_HOST=default-node
DC_HOSTS=(default-dc-a default-dc-b)
DC_ALT_HOSTS=(default-alt)
CLUSTER_HOSTS=(default-node default-dc-a default-dc-b default-alt)
DEFAULT_CPU_PERCENT=50
DEFAULT_BLADE_TIMEOUT=60
DEFAULT_NET_DELAY=50
DEFAULT_NET_LOSS=10
YDB_PORTS=2135
source "${SCRIPT_DIR}/lib/json.sh"
source "${SCRIPT_DIR}/lib/cli.sh"
source "${SCRIPT_DIR}/lib/hosts.sh"
source "${SCRIPT_DIR}/lib/util.sh"
log() { :; }
log_tl() { :; }
log_wait_sec() { :; }
chaos_announce() { :; }
chaos_wait_with_timer() { :; }
chaos_log_script_start() { :; }
chaos_log_script_end() { local rc=$?; chaos_json_exit_trap "${rc}" || true; return "${rc}"; }
record_hosts() { printf '%s\n' "$@" >> "${TEST_CALLS}"; }
INIT
cat > "${SANDBOX}/nemesis/blade.sh" <<'NEMESIS'
nemesis_blade_destroy_all() { shift; record_hosts "$@"; }
NEMESIS
cat > "${SANDBOX}/nemesis/tc.sh" <<'NEMESIS'
nemesis_tc_teardown_all() { record_hosts "$@"; }
NEMESIS
cat > "${SANDBOX}/nemesis/iptables.sh" <<'NEMESIS'
nemesis_iptables_teardown_all() { record_hosts "$@"; }
NEMESIS
cat > "${SANDBOX}/nemesis/disk.sh" <<'NEMESIS'
nemesis_disk_teardown() { record_hosts "$1"; }
nemesis_disk_apply() { record_hosts "$1"; }
NEMESIS
cat > "${SANDBOX}/nemesis/proc.sh" <<'NEMESIS'
nemesis_proc_freeze_teardown() { record_hosts "$1"; }
nemesis_proc_ydbd_restart() { record_hosts "$1"; }
NEMESIS

CALLS="${SANDBOX}/calls"
export TEST_CALLS="${CALLS}"
export CHAOS_DISK_RESTART_STORAGE=false

for script in "${SCRIPTS[@]}"; do
    : > "${CALLS}"
    "${BASH_BIN}" "${SANDBOX}/${script}" --teardown --hosts selected-a,selected-b
    if [[ "${script}" == "02-mem-load.sh" ]]; then
        EXPECTED=$'selected-a\nselected-a\nselected-b\nselected-b'
    else
        EXPECTED=$'selected-a\nselected-b'
    fi
    ACTUAL="$(sort "${CALLS}")"
    [[ "${ACTUAL}" == "${EXPECTED}" ]] || {
        echo "${script}: unexpected targets" >&2
        cat "${CALLS}" >&2
        exit 1
    }
    printf '%s: explicit cleanup targets passed\n' "${script}"
done

: > "${CALLS}"
"${BASH_BIN}" "${SANDBOX}/03-disk-fail.sh" --hosts selected-a
[[ "$(cat "${CALLS}")" == "selected-a" ]] || { cat "${CALLS}" >&2; exit 1; }
printf '03-disk-fail.sh: explicit apply target passed\n'

: > "${CALLS}"
JSON_OUTPUT="$("${BASH_BIN}" "${SANDBOX}/06-net-drop.sh" --teardown --hosts selected-a --json 2>/dev/null)"
[[ "${JSON_OUTPUT}" == *'"test":"06-net-drop"'* ]]
[[ "${JSON_OUTPUT}" == *'"action":"teardown"'* ]]
[[ "${JSON_OUTPUT}" == *'"event":"complete"'* ]]
[[ "${JSON_OUTPUT}" == *'"result":"command_succeeded"'* ]]
printf '06-net-drop.sh: JSON Lines completion passed\n'
