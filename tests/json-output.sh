#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

human="$(${BASH:-bash} -c '
    TEST_NAME=sample
    TEST_SCOPE=single
    CHAOS_OPERATION_ID=0123456789abcdef0123456789abcdef
    SINGLE_HOST=node-a
    DC_HOSTS=()
    DC_ALT_HOSTS=()
    source "$1/lib/operation.sh"
    source "$1/lib/json.sh"
    source "$1/lib/cli.sh"
    chaos_parse_common --single
    echo readable
' _ "${ROOT}")"
[[ "${human}" == readable ]]

json="$(${BASH:-bash} -c '
    TEST_NAME=sample
    TEST_SCOPE=single
    CHAOS_OPERATION_ID=0123456789abcdef0123456789abcdef
    SINGLE_HOST=node-a
    DC_HOSTS=()
    DC_ALT_HOSTS=()
    TARGET_HOSTS=(node-a)
    source "$1/lib/operation.sh"
    source "$1/lib/json.sh"
    source "$1/lib/cli.sh"
    chaos_parse_common --json --single
    chaos_json_emit apply command_succeeded null "quoted \"value\""
    chaos_json_exit_trap 0
' _ "${ROOT}" 2>/dev/null)"
expected='{"schemaVersion":3,"kind":"command","test":"sample","operation":"0123456789abcdef0123456789abcdef","action":"run","event":"apply","result":"command_succeeded","exitCode":null,"scope":"","hosts":["node-a"],"timestamp":"'
[[ "${json}" == "${expected}"* ]]
grep -Fq '"message":"quoted \"value\""}' <<< "${json}"
[[ "$(printf '%s\n' "${json}" | wc -l | tr -d ' ')" == 2 ]]
while IFS= read -r line; do jq -e . >/dev/null <<< "${line}"; done <<< "${json}"

capabilities="$(${BASH:-bash} -c '
    TEST_NAME=sample
    TEST_SCOPE=single
    SINGLE_HOST=node-a
    DC_HOSTS=()
    DC_ALT_HOSTS=()
    source "$1/lib/operation.sh"
    source "$1/lib/json.sh"
    source "$1/lib/cli.sh"
    chaos_parse_common --json --capabilities
' _ "${ROOT}" 2>/dev/null)"
[[ "$(printf '%s\n' "${capabilities}" | wc -l | tr -d ' ')" == 1 ]]
jq -e '.schemaVersion == 3 and .kind == "capabilities"
    and .contract == "chaos-md-shell"
    and .features == ["explicit-hosts", "operation-id", "command-frames", "resource-observations"]
    and (.timestamp | type == "string")' <<< "${capabilities}" >/dev/null

tc_capabilities="$(${BASH:-bash} -c '
    TEST_NAME=sample
    TEST_SCOPE=single
    CHAOS_RESOURCE_EVIDENCE_FAMILY=tc
    SINGLE_HOST=node-a
    DC_HOSTS=()
    DC_ALT_HOSTS=()
    source "$1/lib/operation.sh"
    source "$1/lib/json.sh"
    source "$1/lib/cli.sh"
    chaos_parse_common --json --capabilities
' _ "${ROOT}" 2>/dev/null)"
jq -e '.features == [
    "explicit-hosts", "operation-id", "command-frames", "resource-observations",
    "resource-observations-tc"
]' <<< "${tc_capabilities}" >/dev/null

if ${BASH:-bash} -c '
    TEST_NAME=sample
    TEST_SCOPE=single
    CHAOS_RESOURCE_EVIDENCE_FAMILY="invalid family"
    SINGLE_HOST=node-a
    DC_HOSTS=()
    DC_ALT_HOSTS=()
    source "$1/lib/operation.sh"
    source "$1/lib/json.sh"
    source "$1/lib/cli.sh"
    chaos_parse_common --json --capabilities
' _ "${ROOT}" >/dev/null 2>&1; then
    echo "invalid resource evidence family was accepted" >&2
    exit 1
fi

readable="$(${BASH:-bash} -c '
    TEST_NAME=sample; TEST_SCOPE=single; SINGLE_HOST=node-a; DC_HOSTS=(); DC_ALT_HOSTS=()
    source "$1/lib/operation.sh"; source "$1/lib/json.sh"; source "$1/lib/cli.sh"
    chaos_parse_common --capabilities
' _ "${ROOT}")"
grep -Fq 'Chaos MD shell contract 3' <<< "${readable}"

tc_readable="$(${BASH:-bash} -c '
    TEST_NAME=sample; TEST_SCOPE=single; CHAOS_RESOURCE_EVIDENCE_FAMILY=tc
    SINGLE_HOST=node-a; DC_HOSTS=(); DC_ALT_HOSTS=()
    source "$1/lib/operation.sh"; source "$1/lib/json.sh"; source "$1/lib/cli.sh"
    chaos_parse_common --capabilities
' _ "${ROOT}")"
grep -Fq 'resource-observations-tc' <<< "${tc_readable}"

numbered_tc="$("${ROOT}/04-net-delay.sh" --json --capabilities 2>/dev/null)"
jq -e '.features | index("resource-observations-tc") != null' <<< "${numbered_tc}" >/dev/null
numbered_iptables="$("${ROOT}/06-net-drop.sh" --json --capabilities 2>/dev/null)"
jq -e '.features | index("resource-observations-iptables") == null' <<< "${numbered_iptables}" >/dev/null

observation="$(${BASH:-bash} -c '
    TEST_NAME=sample
    CHAOS_OPERATION_ID=0123456789abcdef0123456789abcdef
    CHAOS_JSON_ACTION=run
    source "$1/lib/json.sh"
    chaos_json_enable
    chaos_json_emit_observation node-a tc:eth0 active aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee 7 true false ok
    CHAOS_JSON_TERMINAL_EMITTED=true
' _ "${ROOT}" 2>/dev/null)"
jq -e '.schemaVersion == 3 and .kind == "observation" and .host == "node-a"
    and .resource == "tc:eth0" and .state == "active" and .revision == 7
    and .recoveryArmed == true and .cancelled == false' <<< "${observation}" >/dev/null

message=$'path\\new\\test "quoted"\n\t\r\b\f\001 Привет'
escaped="$(${BASH:-bash} -c 'source "$1/lib/json.sh"; chaos_json_escape "$2"' _ "${ROOT}" "${message}")"
jq -en --arg expected "${message}" --arg encoded "\"${escaped}\"" \
    '$encoded | fromjson == $expected' >/dev/null

set +e
failed="$(${BASH:-bash} -c '
    TEST_NAME=sample
    LOG_FILE=
    source "$1/lib/operation.sh"
    source "$1/lib/json.sh"
    source "$1/lib/log.sh"
    chaos_json_enable
    trap '\''rc=$?; true; chaos_log_script_end "${rc}"'\'' EXIT
    exit 7
' _ "${ROOT}" 2>/dev/null)"
failed_rc=$?
set -e
[[ "${failed_rc}" == 7 ]]
grep -Fq '"event":"complete","result":"command_failed","exitCode":7' <<< "${failed}"
printf 'human output and JSON Lines separation passed\n'
