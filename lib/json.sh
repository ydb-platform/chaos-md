#!/usr/bin/env bash

MODE_JSON="${MODE_JSON:-false}"
CHAOS_JSON_FD_READY="${CHAOS_JSON_FD_READY:-false}"
CHAOS_JSON_TERMINAL_EMITTED="${CHAOS_JSON_TERMINAL_EMITTED:-false}"
CHAOS_JSON_ACTION="${CHAOS_JSON_ACTION:-run}"

chaos_json_escape() {
    local value="${1:-}" out="" char code i
    local LC_ALL=C
    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "${char}" in
            '"') out+='\"' ;;
            '\') out+='\\' ;;
            $'\b') out+='\b' ;;
            $'\f') out+='\f' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            *)
                printf -v code '%d' "'${char}"
                if ((code >= 0 && code < 32)); then
                    printf -v char '\\u%04x' "${code}"
                fi
                out+="${char}"
                ;;
        esac
    done
    printf '%s' "${out}"
}

chaos_json_array() {
    local first=true value
    printf '['
    for value in "$@"; do
        [[ "${first}" == true ]] || printf ','
        first=false
        printf '"%s"' "$(chaos_json_escape "${value}")"
    done
    printf ']'
}

chaos_json_hosts() {
    if [[ -n "${SCOPE_LABEL:-}" ]]; then
        chaos_json_array ${TARGET_HOSTS[@]+"${TARGET_HOSTS[@]}"}
    elif [[ -n "${TARGET_HOSTS[*]:-}" ]]; then
        chaos_json_array "${TARGET_HOSTS[@]}"
    elif [[ -n "${EXPLICIT_HOSTS[*]:-}" ]]; then
        chaos_json_array "${EXPLICIT_HOSTS[@]}"
    elif [[ -n "${CHECK_HOST:-}" ]]; then
        chaos_json_array "${CHECK_HOST}"
    else
        printf '[]'
    fi
}

chaos_json_emit() {
    [[ "${MODE_JSON:-false}" == true ]] || return 0
    local event="$1" result="$2" exit_code="${3:-null}" message="${4:-}"
    local timestamp scope hosts
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    scope="${SCOPE_LABEL:-}"
    hosts="$(chaos_json_hosts)"
    printf '{"schemaVersion":3,"kind":"command","test":"%s","operation":"%s","action":"%s","event":"%s","result":"%s","exitCode":%s,"scope":"%s","hosts":%s,"timestamp":"%s","message":"%s"}\n' \
        "$(chaos_json_escape "${TEST_NAME:-unknown}")" \
        "$(chaos_json_escape "${CHAOS_OPERATION_ID:-}")" \
        "$(chaos_json_escape "${CHAOS_JSON_ACTION:-run}")" \
        "$(chaos_json_escape "${event}")" \
        "$(chaos_json_escape "${result}")" \
        "${exit_code}" \
        "$(chaos_json_escape "${scope}")" \
        "${hosts}" \
        "${timestamp}" \
        "$(chaos_json_escape "${message}")" >&3
}

chaos_capability_features() {
    local features=(explicit-hosts operation-id command-frames resource-observations)
    local family="${CHAOS_RESOURCE_EVIDENCE_FAMILY:-}"
    if [[ -n "${family}" ]]; then
        if [[ ! "${family}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
            echo "Некорректное семейство доказательств ресурсов: ${family}" >&2
            return 1
        fi
        features+=("resource-observations-${family}")
    fi
    printf '%s\n' "${features[@]}"
}

chaos_capability_features_text() {
    local feature feature_lines output=""
    feature_lines="$(chaos_capability_features)" || return 1
    while IFS= read -r feature; do
        [[ -z "${output}" ]] || output+=" "
        output+="${feature}"
    done <<< "${feature_lines}"
    printf '%s' "${output}"
}

chaos_json_emit_capabilities() {
    [[ "${MODE_JSON:-false}" == true ]] || return 0
    local timestamp feature feature_lines features=()
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    feature_lines="$(chaos_capability_features)" || return 1
    while IFS= read -r feature; do features+=("${feature}"); done <<< "${feature_lines}"
    printf '{"schemaVersion":3,"kind":"capabilities","contract":"chaos-md-shell","features":%s,"timestamp":"%s"}\n' \
        "$(chaos_json_array "${features[@]}")" "${timestamp}" >&3
}

chaos_json_emit_observation() {
    [[ "${MODE_JSON:-false}" == true ]] || return 0
    local host="$1" resource="$2" state="$3" boot_id="$4" revision="$5"
    local recovery_armed="$6" cancelled="$7" code="$8" timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '{"schemaVersion":3,"kind":"observation","test":"%s","operation":"%s","action":"%s","host":"%s","resource":"%s","state":"%s","bootId":"%s","revision":%s,"recoveryArmed":%s,"cancelled":%s,"timestamp":"%s","message":"%s"}\n' \
        "$(chaos_json_escape "${TEST_NAME:-unknown}")" \
        "$(chaos_json_escape "${CHAOS_OPERATION_ID:-}")" \
        "$(chaos_json_escape "${CHAOS_JSON_ACTION:-run}")" \
        "$(chaos_json_escape "${host}")" \
        "$(chaos_json_escape "${resource}")" \
        "$(chaos_json_escape "${state}")" \
        "$(chaos_json_escape "${boot_id}")" \
        "${revision}" "${recovery_armed}" "${cancelled}" "${timestamp}" \
        "$(chaos_json_escape "${code}")" >&3
}

chaos_json_exit_trap() {
    local rc="${1:-0}"
    [[ "${MODE_JSON:-false}" == true ]] || return "${rc}"
    if [[ "${CHAOS_JSON_TERMINAL_EMITTED}" != true ]]; then
        CHAOS_JSON_TERMINAL_EMITTED=true
        if ((rc == 0)); then
            chaos_json_emit complete command_succeeded "${rc}"
        else
            chaos_json_emit complete command_failed "${rc}"
        fi
    fi
    return "${rc}"
}

chaos_json_enable() {
    [[ "${CHAOS_JSON_FD_READY}" == true ]] && return 0
    MODE_JSON=true
    CHAOS_JSON_FD_READY=true
    exec 3>&1
    exec 1>&2
    trap 'chaos_json_exit_trap $?' EXIT
}
