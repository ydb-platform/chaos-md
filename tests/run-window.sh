#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/test_runner.sh"

EVENTS=()
TARGET_HOSTS=(h1 h2)
SCOPE_LABEL=explicit
TIMEOUT=1

log() { :; }
log_tl() {
    if [[ "$1" == CHAOS_CANCEL ]]; then
        chaos_json_emit teardown command_succeeded null "$2"
    fi
}
log_wait_sec() { :; }
chaos_json_emit() { :; }
chaos_wait_with_timer() { EVENTS+=(wait); }

apply_fail() { EVENTS+=(apply); return 1; }
apply_ok() { EVENTS+=(apply); }
teardown_ok() { EVENTS+=(teardown); }
teardown_fail() { EVENTS+=(teardown); return 1; }

if chaos_run_window test apply_fail teardown_ok; then
    echo 'Ошибка apply не была возвращена' >&2
    exit 1
fi
[[ "${EVENTS[*]}" == 'apply teardown' ]]

EVENTS=()
if chaos_run_window test apply_ok teardown_fail; then
    echo 'Ошибка teardown не была возвращена' >&2
    exit 1
fi
[[ "${EVENTS[*]}" == 'apply wait teardown' ]]

EVENTS=()
chaos_run_window test apply_ok teardown_ok
[[ "${EVENTS[*]}" == 'apply wait teardown' ]]

run_signal_case() {
    local signal="$1" expected_rc="$2"
    local sandbox child events json rc
    sandbox="$(mktemp -d)"
    child="${sandbox}/child.sh"
    events="${sandbox}/events"
    json="${sandbox}/json"
    cat > "${child}" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
EVENTS_FILE="$2"
JSON_FILE="$3"
SIGNAL="$4"
TARGET_HOSTS=(h1)
SCOPE_LABEL=explicit
TIMEOUT=60
log() { :; }
log_tl() {
    if [[ "$1" == CHAOS_CANCEL ]]; then
        chaos_json_emit teardown command_succeeded null "$2"
    fi
}
log_wait_sec() { :; }
chaos_json_emit() { printf '%s\n' "$*" >> "${JSON_FILE}"; }
chaos_wait_with_timer() { kill "-${SIGNAL}" "$$"; sleep "$1"; }
apply_ok() { printf 'apply\n' >> "${EVENTS_FILE}"; }
teardown_ok() { printf 'teardown\n' >> "${EVENTS_FILE}"; }
source "${ROOT}/lib/test_runner.sh"
trap 'rc=$?; chaos_json_emit complete "$([[ ${rc} == 0 ]] && echo command_succeeded || echo command_failed)" "${rc}"; exit "${rc}"' EXIT
chaos_run_window test apply_ok teardown_ok
CHILD
    chmod +x "${child}"
    set +e
    "${BASH:-bash}" "${child}" "${ROOT}" "${events}" "${json}" "${signal}"
    rc=$?
    set -e
    [[ "${rc}" == "${expected_rc}" ]]
    [[ "$(cat "${events}")" == $'apply\nteardown' ]]
    [[ "$(grep -c '^teardown command_succeeded null ' "${json}")" == 1 ]]
    grep -Fxq "complete command_failed ${expected_rc}" "${json}"
    rm -rf "${sandbox}"
}

run_signal_case INT 130
run_signal_case TERM 143

echo 'run window tests: ok'
