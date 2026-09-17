#!/usr/bin/env bash

CHAOS_OPERATION_ID="${CHAOS_OPERATION_ID:-}"
CHAOS_OPERATION_EXPLICIT=false

chaos_operation_validate() {
    [[ "${1:-}" =~ ^[0-9a-f]{32}$ ]]
}

chaos_operation_generate() {
    local value
    value="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    chaos_operation_validate "${value}" || {
        echo 'Не удалось создать идентификатор операции' >&2
        return 1
    }
    printf '%s' "${value}"
}

chaos_operation_prepare() {
    local count=0 value=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --operation ]]; then
            [[ $# -gt 1 ]] || { echo '--operation требует значение' >&2; return 1; }
            value="$2"
            ((count += 1))
            shift 2
        else
            shift
        fi
    done
    ((count <= 1)) || { echo '--operation нельзя задавать несколько раз' >&2; return 1; }
    if [[ -n "${value}" ]]; then
        chaos_operation_validate "${value}" || {
            echo '--operation должен содержать 32 строчные шестнадцатеричные цифры' >&2
            return 1
        }
        CHAOS_OPERATION_ID="${value}"
        CHAOS_OPERATION_EXPLICIT=true
    elif [[ -z "${CHAOS_OPERATION_ID}" ]]; then
        CHAOS_OPERATION_ID="$(chaos_operation_generate)"
    fi
}
