#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/logs"
export LOG_DIR="${TMP}/logs"
export TEST_NAME="01-cpu-load"
export BLADE_REMOTE=blade
export SSH_OPTS=()
export DESTROY_JSON='{"code":500,"success":false}'
export STATUS_JSON='{"code":200,"success":true,"result":{"Uid":"d64b8062b141dcf7","Status":"Destroyed"}}'
export STATUS_RC=0

log() { printf '%s\n' "$*"; }
log_chaos_apply() { :; }
chaos_term_remote_cmd() { :; }
chaos_remote_line_kind() { printf 'other\n'; }
chaos_log_remote_line() { :; }

ssh() {
    local cmd="$*"
    if [[ "${cmd}" == *' destroy '* ]]; then
        printf '%s\n' "${DESTROY_JSON}"
        [[ "${DESTROY_JSON}" == *'"success":true'* || "${DESTROY_JSON}" == *'"success": true'* ]]
        return
    fi
    if [[ "${cmd}" == *' status '* ]]; then
        printf '%s\n' "${STATUS_JSON}"
        return "${STATUS_RC}"
    fi
    return 42
}

# shellcheck source=../lib/util.sh
source "${ROOT}/lib/util.sh"
# shellcheck source=../nemesis/blade.sh
source "${ROOT}/nemesis/blade.sh"

HOST=ydb-1.example
UID_FILE="$(state_file "${HOST}" uid)"
printf 'd64b8062b141dcf7\n' > "${UID_FILE}"

if ! nemesis_blade_destroy "${HOST}" uid; then
    echo 'Destroyed after failed destroy must be clean' >&2
    exit 1
fi
[[ ! -f "${UID_FILE}" ]]

printf 'd64b8062b141dcf7\n' > "${UID_FILE}"
STATUS_JSON='{"code":200,"success":true,"result":{"Uid":"d64b8062b141dcf7","Status":"Success"}}'
if nemesis_blade_destroy "${HOST}" uid; then
    echo 'Success after failed destroy must stay leftover' >&2
    exit 1
fi
[[ -f "${UID_FILE}" ]]

DESTROY_JSON='{"code":200,"success":true}'
if ! nemesis_blade_destroy "${HOST}" uid; then
    echo 'success:true destroy must remove UID' >&2
    exit 1
fi
[[ ! -f "${UID_FILE}" ]]

if ! nemesis_blade_check "${HOST}"; then
    echo 'check without UID must be clean' >&2
    exit 1
fi

printf 'd64b8062b141dcf7\n' > "${UID_FILE}"
STATUS_JSON='{"code":200,"success":true,"result":{"Uid":"d64b8062b141dcf7","Status":"Destroyed"}}'
if ! nemesis_blade_check "${HOST}"; then
    echo 'check Destroyed must be clean' >&2
    exit 1
fi

STATUS_JSON='{"code":200,"success":true,"result":{"Uid":"d64b8062b141dcf7","Status":"Success"}}'
if nemesis_blade_check "${HOST}"; then
    echo 'check Success must fail' >&2
    exit 1
fi

STATUS_RC=1
if nemesis_blade_check "${HOST}"; then
    echo 'unreachable status must fail' >&2
    exit 1
fi

echo 'blade status tests: ok'
