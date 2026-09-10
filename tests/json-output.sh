#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

human="$(${BASH:-bash} -c '
    TEST_NAME=sample
    TEST_SCOPE=single
    SINGLE_HOST=node-a
    DC_HOSTS=()
    DC_ALT_HOSTS=()
    source "$1/lib/json.sh"
    source "$1/lib/cli.sh"
    chaos_parse_common --single
    echo readable
' _ "${ROOT}")"
[[ "${human}" == readable ]]

json="$(${BASH:-bash} -c '
    TEST_NAME=sample
    TEST_SCOPE=single
    SINGLE_HOST=node-a
    DC_HOSTS=()
    DC_ALT_HOSTS=()
    TARGET_HOSTS=(node-a)
    source "$1/lib/json.sh"
    source "$1/lib/cli.sh"
    chaos_parse_common --json --single
    chaos_json_emit apply command_succeeded null "quoted \"value\""
    chaos_json_exit_trap 0
' _ "${ROOT}" 2>/dev/null)"
expected='{"schemaVersion":1,"test":"sample","action":"run","event":"apply","result":"command_succeeded","exitCode":null,"scope":"","hosts":["node-a"],"timestamp":"'
[[ "${json}" == "${expected}"* ]]
grep -Fq '"message":"quoted \"value\""}' <<< "${json}"
[[ "$(printf '%s\n' "${json}" | wc -l | tr -d ' ')" == 2 ]]
while IFS= read -r line; do jq -e . >/dev/null <<< "${line}"; done <<< "${json}"

set +e
failed="$(${BASH:-bash} -c '
    TEST_NAME=sample
    LOG_FILE=
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
