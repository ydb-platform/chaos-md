#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export CHAOS_WORKLOAD_ADAPTER_DIR="${SCRIPT_DIR}"
export CHAOS_WORKLOAD_STATE_DIR="${TMP}/state"
export CHAOS_WORKLOAD_LOG_DIR="${TMP}/logs"
export FAKE_WORKLOAD_READY_FILE="${TMP}/ready"
export FAKE_WORKLOAD_ACTION_FILE="${TMP}/action"
export CHAOS_WORKLOAD_ANNOTATIONS=false
export CHAOS_ENV_FILE="${TMP}/env.sh"
export CHAOS_SKIP_LOCAL_ENV=true
printf 'LOG_DIR=%q\nGRAFANA_URL=%q\nGRAFANA_TOKEN=%q\n' \
    "${TMP}/logs" "http://127.0.0.1:1" "" >"${CHAOS_ENV_FILE}"

manager=(bash "${WORKLOAD_DIR}/manage.sh" --type fake --profile smoke)

"${manager[@]}" prepare
"${manager[@]}" start --wait 5
"${manager[@]}" status
grep -Fx -- "smoke" "${TMP}/state/fake/profile" >/dev/null

# Read-only inspection must not create a control event on every poll.
before="$(grep -c 'WORKLOAD_ACTION' "${TMP}/logs/timeline.log" || true)"
"${manager[@]}" action partitions
after="$(grep -c 'WORKLOAD_ACTION' "${TMP}/logs/timeline.log" || true)"
[[ "${before}" == "${after}" ]]

"${manager[@]}" action partition-auto fulltext
grep -Fx -- "partition-auto fulltext" "${FAKE_WORKLOAD_ACTION_FILE}" >/dev/null
grep -F -- "WORKLOAD_ACTION" "${TMP}/logs/timeline.log" >/dev/null
"${manager[@]}" stop

if "${manager[@]}" status >/dev/null 2>&1; then
    echo "status unexpectedly succeeded after stop" >&2
    exit 1
fi
[[ ! -e "${FAKE_WORKLOAD_READY_FILE}" ]]
echo "manager lifecycle smoke: OK"
