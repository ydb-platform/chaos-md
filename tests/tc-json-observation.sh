#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

json="$(${BASH:-bash} -c '
    TEST_NAME=04-net-delay
    CHAOS_OPERATION_ID=0123456789abcdef0123456789abcdef
    CHAOS_JSON_ACTION=run
    CHAOS_REPO_DIR="$1"
    SSH_OPTS=()
    source "$1/lib/json.sh"
    source "$1/nemesis/tc.sh"
    ssh() {
        cat >/dev/null
        printf "%s\n" "observation operation=${CHAOS_OPERATION_ID} resource=tc:eth0 state=active boot_id=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee revision=9 recovery_armed=true cancelled=false code=ok"
    }
    chaos_json_enable
    _nemesis_tc_run_remote node-a check "${CHAOS_OPERATION_ID}" any /tmp/state eth0
    CHAOS_JSON_TERMINAL_EMITTED=true
' _ "${ROOT}" 2>/dev/null)"

jq -e '.schemaVersion == 3 and .kind == "observation"
    and .operation == "0123456789abcdef0123456789abcdef"
    and .host == "node-a" and .resource == "tc:eth0"
    and .state == "active" and .revision == 9
    and .recoveryArmed == true and .cancelled == false' <<< "${json}" >/dev/null

if ${BASH:-bash} -c '
    TEST_NAME=04-net-delay
    CHAOS_OPERATION_ID=0123456789abcdef0123456789abcdef
    CHAOS_REPO_DIR="$1"
    SSH_OPTS=()
    source "$1/lib/json.sh"
    source "$1/nemesis/tc.sh"
    ssh() { cat >/dev/null; echo malformed; }
    _nemesis_tc_run_remote node-a check "${CHAOS_OPERATION_ID}" any /tmp/state eth0
' _ "${ROOT}" >/dev/null 2>&1; then
    echo 'Некорректное наблюдение tc было принято' >&2
    exit 1
fi

echo 'tc JSON observation tests: ok'
