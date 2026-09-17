#!/usr/bin/env bash
# Аннотации Grafana — открытие/закрытие региональной аннотации на интервал хаоса.
# Без GRAFANA_URL / GRAFANA_TOKEN всё превращается в no-op.
#
# Используется через timeline.sh: log_tl CHAOS_START / CHAOS_END / CHAOS_CANCEL.
# ID открытой аннотации хранится в /tmp/grafana-chaos-<test_name>.id.

_grafana_time_ms() {
    if date +%s%3N 2>/dev/null | grep -q '^[0-9]\{13\}$'; then
        date +%s%3N
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

_grafana_id_file() {
    echo "/tmp/grafana-chaos-$1.id"
}

_grafana_json_text() {
    printf '"%s"' "$(chaos_json_escape "$1")"
}

# Открыть регион. Сохраняет id для дальнейшего close.
grafana_region_open() {
    local test_name="$1" text="$2"
    [[ -z "${GRAFANA_URL:-}" ]] && return 0

    local time_ms id_file payload response annot_id
    time_ms="$(_grafana_time_ms)"
    id_file="$(_grafana_id_file "${test_name}")"
    local chaos_tag="chaos"
    [[ "${CHAOS_DRY_RUN:-false}" == "true" ]] && chaos_tag="chaos-dry"
    payload="$(printf '{"time":%s,"timeEnd":%s,"tags":["%s","%s"],"text":%s}' \
        "${time_ms}" "${time_ms}" "${chaos_tag}" "${test_name}" "$(_grafana_json_text "${text}")")"

    response=$(curl -sfk --max-time 5 \
        -XPOST "${GRAFANA_URL}/api/annotations" \
        -H "Authorization: Bearer ${GRAFANA_TOKEN:-}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>&1) || {
        echo "grafana: WARNING POST failed (${test_name})" >&2
        return 0
    }
    annot_id=$(echo "${response}" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    [[ -n "${annot_id}" ]] && echo "${annot_id}" > "${id_file}"
}

# Закрыть регион.
grafana_region_close() {
    local test_name="$1"
    [[ -z "${GRAFANA_URL:-}" ]] && return 0

    local id_file annot_id time_end
    id_file="$(_grafana_id_file "${test_name}")"
    [[ -f "${id_file}" ]] || return 0
    annot_id=$(cat "${id_file}"); rm -f "${id_file}"
    [[ -z "${annot_id}" ]] && return 0

    time_end="$(_grafana_time_ms)"
    curl -sfk --max-time 5 \
        -XPATCH "${GRAFANA_URL}/api/annotations/${annot_id}" \
        -H "Authorization: Bearer ${GRAFANA_TOKEN:-}" \
        -H "Content-Type: application/json" \
        -d "{\"timeEnd\": ${time_end}}" >/dev/null 2>&1 || {
        echo "grafana: WARNING PATCH failed id=${annot_id}" >&2
    }
}
