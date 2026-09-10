#!/usr/bin/env bash
# Логирование. Все сообщения уходят и в stdout, и в LOG_FILE.
# LOG_FILE задаёт init.sh.

now_msk() {
    TZ="${LOG_TZ:-Europe/Moscow}" date '+%Y-%m-%d %H:%M:%S %Z'
}

log() {
    local msg="[$(now_msk)] $*"
    printf '%s\n' "${msg}"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "${msg}" >> "${LOG_FILE}"
}

log_section() {
    log "=== $* ==="
}

log_chaos_apply() {
    log "Внесение хаоса: $*"
}

log_wait_sec() {
    log "Ожидание ${1}с"
}

# --- Лог удалённых команд (терминал: спокойный фон + яркий белый текст только у команды) ---
# CHAOS_LOG_COLOR=auto|always|never
# Таймстамп без подсветки; команда — ярко-белый на обычном (не ярком) фоне SGR 41/42.

CHAOS_LOG_ON_STYLE=$'\033[1;97;41m'
CHAOS_LOG_OFF_STYLE=$'\033[1;97;42m'
CHAOS_LOG_RST=$'\033[0m'

chaos_log_color_enabled() {
    case "${CHAOS_LOG_COLOR:-auto}" in
        never | false | 0 | no) return 1 ;;
        always | force | 1 | yes) return 0 ;;
        *) [[ -t 1 ]] ;;
    esac
}

# Классификация строк удалённого bash-скрипта: on | off | neutral
chaos_remote_line_kind() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    [[ -z "${s}" ]] && { echo neutral; return; }
    [[ "${s}" =~ ^# ]] && { echo neutral; return; }

    if [[ "${s}" =~ ^(set[[:space:]]|if[[:space:]]|then$|else$|elif[[:space:]]|fi$|done$|do$|trap[[:space:]]|readarray[[:space:]]|local[[:space:]]|chmod[[:space:]]|disown) ]] \
        || [[ "${s}" =~ ^echo[[:space:]] ]] \
        || [[ "${s}" =~ ^sudo[[:space:]]+echo[[:space:]] ]] \
        || [[ "${s}" =~ ^cat[[:space:]] ]] \
        || [[ "${s}" =~ ^printf[[:space:]] ]]; then
        echo neutral
        return
    fi

    if [[ "${s}" =~ ^nohup ]] && [[ "${s}" =~ systemctl[[:space:]]+stop ]] && [[ "${s}" =~ systemctl[[:space:]]+start ]]; then
        echo neutral
        return
    fi

    # ON — сначала специфичные kill/stop
    if [[ "${s}" =~ tc[[:space:]]+(qdisc|filter)[[:space:]]+(add|replace) ]]; then echo on; return; fi
    if [[ "${s}" =~ iptables[[:space:]].*-A[[:space:]] ]] || [[ "${s}" =~ iptables[[:space:]]+-A[[:space:]] ]]; then echo on; return; fi
    if [[ "${s}" =~ ip6tables[[:space:]].*-A[[:space:]] ]] || [[ "${s}" =~ ip6tables[[:space:]]+-A[[:space:]] ]]; then echo on; return; fi
    if [[ "${s}" =~ blade[[:space:]]+create ]] || [[ "${s}" =~ ./blade[[:space:]]+create ]]; then echo on; return; fi
    if [[ "${s}" =~ kill[[:space:]]+-STOP ]]; then echo on; return; fi
    if [[ "${s}" =~ kill[[:space:]]+-9 ]] || [[ "${s}" =~ kill[[:space:]]+-SIGKILL ]]; then echo on; return; fi
    if [[ "${s}" =~ systemctl[[:space:]]+stop ]]; then echo on; return; fi
    if [[ "${s}" =~ device/device/remove ]]; then echo on; return; fi
    if [[ "${s}" =~ tee[[:space:]].*remove ]]; then echo on; return; fi

    # OFF
    if [[ "${s}" =~ tc[[:space:]]+qdisc[[:space:]]+del ]]; then echo off; return; fi
    if [[ "${s}" =~ kill[[:space:]]+-CONT ]]; then echo off; return; fi
    if [[ "${s}" =~ (^|[[:space:]])kill[[:space:]] ]]; then echo off; return; fi
    if [[ "${s}" =~ rm[[:space:]]+-f[[:space:]] ]]; then echo off; return; fi
    if [[ "${s}" =~ iptables[[:space:]].*-F[[:space:]] ]] || [[ "${s}" =~ iptables[[:space:]]+-F[[:space:]] ]]; then echo off; return; fi
    if [[ "${s}" =~ iptables[[:space:]].*-D[[:space:]] ]] || [[ "${s}" =~ iptables[[:space:]]+-D[[:space:]] ]]; then echo off; return; fi
    if [[ "${s}" =~ ip6tables[[:space:]].*-F[[:space:]] ]] || [[ "${s}" =~ ip6tables[[:space:]]+-F[[:space:]] ]]; then echo off; return; fi
    if [[ "${s}" =~ ip6tables[[:space:]].*-D[[:space:]] ]] || [[ "${s}" =~ ip6tables[[:space:]]+-D[[:space:]] ]]; then echo off; return; fi
    if [[ "${s}" =~ blade[[:space:]]+destroy ]] || [[ "${s}" =~ ./blade[[:space:]]+destroy ]]; then echo off; return; fi
    if [[ "${s}" =~ pci/rescan ]]; then echo off; return; fi
    if [[ "${s}" =~ systemctl[[:space:]]+start ]]; then echo off; return; fi
    if [[ "${s}" =~ systemctl[[:space:]]+reset-failed ]]; then echo off; return; fi
    if [[ "${s}" =~ ^nohup ]] && [[ "${s}" =~ (tc[[:space:]]+qdisc[[:space:]]+del|svc-chaos-recover|\-CONT|rescan|upgrade-chaos) ]]; then echo off; return; fi

    echo neutral
}

chaos_log_remote_line() {
    local kind="$1" line="$2"
    local ts plain disp
    ts="[$(now_msk)] "
    plain="${ts}  ${line}"
    if chaos_log_color_enabled && [[ "${kind}" == on ]]; then
        disp="${ts}  ${CHAOS_LOG_ON_STYLE}${line}${CHAOS_LOG_RST}"
    elif chaos_log_color_enabled && [[ "${kind}" == off ]]; then
        disp="${ts}  ${CHAOS_LOG_OFF_STYLE}${line}${CHAOS_LOG_RST}"
    else
        disp="${plain}"
    fi
    printf '%b\n' "${disp}"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "${plain}" >> "${LOG_FILE}"
}

chaos_log_remote_script() {
    local title="$1"
    local script="$2"
    [[ -n "${title}" ]] && log_section "${title}"
    local line kind
    while IFS= read -r line || [[ -n "${line}" ]]; do
        kind=$(chaos_remote_line_kind "${line}")
        case "${kind}" in
            on)  chaos_log_remote_line on "${line}" ;;
            off) chaos_log_remote_line off "${line}" ;;
            *)   log "  ${line}" ;;
        esac
    done <<< "${script}"
}

# Стартовый/финальный маркер скрипта.
chaos_log_script_start() {
    log "Запуск ${TEST_NAME}"
    if [[ "${CHAOS_DRY_RUN:-false}" == "true" ]]; then
        log "*** DRY-RUN: команды не выполняются, только вывод ***"
    fi
    if [[ -n "${CHAOS_CMDLINE+x}" && ${#CHAOS_CMDLINE[@]} -gt 0 ]]; then
        chaos_term_cmdline "${CHAOS_CMDLINE[@]}"
    fi
}

chaos_log_script_end() {
    local rc=$?
    [[ $# -gt 0 ]] && rc="$1"
    log "Завершение ${TEST_NAME}"
    local sep
    sep="$(printf '%.0s-' {1..72})"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "${sep}" >> "${LOG_FILE}"
    printf '%s\n' "${sep}" >&2
    if declare -F chaos_json_exit_trap >/dev/null; then
        chaos_json_exit_trap "${rc}" || true
    fi
    return "${rc}"
}
