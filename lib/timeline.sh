#!/usr/bin/env bash
# События для корреляции с метриками: пишутся в logs/timeline.log
# и одновременно отправляются в Grafana как региональные аннотации.
#
# Использование: log_tl CHAOS_START|CHAOS_END|CHAOS_CANCEL <детали...>

log_tl() {
    local event="$1"; shift
    local details="$*"
    local timeline="${LOG_DIR}/timeline.log"

    case "${event}" in
        CHAOS_START)
            printf "%-26s  %-16s  %s\n" "$(now_msk)" "${event}" "${details}" \
                | tee -a "${timeline}"
            grafana_region_open "${TEST_NAME}" "${event}  ${details}"
            chaos_json_emit apply command_succeeded null "${details}"
            ;;
        CHAOS_END*)
            printf "%-26s  %-16s  %s\n" "$(now_msk)" "${event}" "${details}" \
                | tee -a "${timeline}"
            grafana_region_close "${TEST_NAME}"
            chaos_json_emit window_complete command_succeeded null "${details}"
            ;;
        CHAOS_CANCEL)
            printf "%-26s  %-16s  %s\n" "$(now_msk)" "${event}" "${details}" \
                | tee -a "${timeline}"
            grafana_region_close "${TEST_NAME}"
            chaos_json_emit teardown command_succeeded null "${details}"
            ;;
    esac
}
