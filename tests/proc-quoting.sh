#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/pgrep" <<'SH'
#!/usr/bin/env bash
[[ $# == 3 && "$1" == -f && "$2" == -- && "$3" == "${EXPECTED_PATTERN}" ]] || exit 42
printf '%s' "$3" > "${PATTERN_FILE}"
exit 1
SH
cat > "${TMP}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${TMP}/bin/pgrep" "${TMP}/bin/systemctl"
export PATH="${TMP}/bin:${PATH}" PATTERN_FILE="${TMP}/pattern"
export EXPECTED_PATTERN="'; touch ${TMP}/injected; : '"
YDBD_BIN="${EXPECTED_PATTERN}"
SSH_OPTS=(-o BatchMode=yes)
log_chaos_apply() { :; }
chaos_term_remote_cmd() { :; }
chaos_log_remote_script() { :; }
ssh() {
    local script
    script="$(cat)"
    [[ "${script}" != *'kill $(cat /tmp/proc-freeze.pid)'* ]] || return 42
    "${BASH}" -s <<< "${script}"
}
source "${ROOT}/nemesis/proc.sh"
nemesis_proc_kill_apply fake-host >/dev/null 2>&1 || true
[[ ! -e "${TMP}/injected" && -f "${PATTERN_FILE}" && "$(cat "${PATTERN_FILE}")" == "${EXPECTED_PATTERN}" ]] || { echo 'unsafe kill pattern' >&2; exit 1; }
rm "${PATTERN_FILE}"
nemesis_proc_check fake-host >/dev/null 2>&1
[[ ! -e "${TMP}/injected" && -f "${PATTERN_FILE}" && "$(cat "${PATTERN_FILE}")" == "${EXPECTED_PATTERN}" ]] || { echo 'unsafe check pattern' >&2; exit 1; }
if nemesis_proc_freeze_apply fake-host "1; touch ${TMP}/injected" >/dev/null 2>&1; then exit 1; fi
[[ ! -e "${TMP}/injected" ]] || exit 1
echo 'proc quoting tests: ok'
