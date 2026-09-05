#!/usr/bin/env bash
# Универсальный lifecycle workload для Chaos MD.
# Конкретная реализация выбирается через --type или CHAOS_WORKLOAD_TYPE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/config.sh"
chaos_load_env "${REPO_ROOT}"
[[ -f "${SCRIPT_DIR}/env.local.sh" ]] && source "${SCRIPT_DIR}/env.local.sh"

TYPE="${CHAOS_WORKLOAD_TYPE:-}"
COMMAND=""
DRY_RUN=false
START_TIMEOUT="${CHAOS_WORKLOAD_START_TIMEOUT:-15}"
PROFILE="${CHAOS_WORKLOAD_PROFILE:-}"
ANNOTATIONS="${CHAOS_WORKLOAD_ANNOTATIONS:-true}"
STATE_ROOT="${CHAOS_WORKLOAD_STATE_DIR:-${SCRIPT_DIR}/.state}"
ADAPTER_DIR="${CHAOS_WORKLOAD_ADAPTER_DIR:-${SCRIPT_DIR}/adapters}"

usage() {
    cat <<'EOF'
Использование: workload/manage.sh --type TYPE COMMAND [ОПЦИИ]

COMMAND:
  info       показать конфигурацию adapter и состояние процесса
  prepare    проверить или подготовить данные workload
  start      запустить workload в фоне
  status     проверить процесс и health adapter
  stop       штатно остановить workload
  action     выполнить adapter-specific действие и отметить его в Grafana
  run        запустить workload в foreground
  cleanup    удалить данные workload; требует --yes

ОПЦИИ:
  --type TYPE       adapter из workload/adapters/ (stock или search)
  --wait SEC        сколько ждать health после start, default 15
  --profile NAME    именованный профиль adapter; необязателен
  --dry-run         показать действия без запуска и изменений
  --yes             подтверждение для cleanup
  -h, --help        справка

TYPE можно задать переменной CHAOS_WORKLOAD_TYPE.
EOF
}

EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)
            [[ $# -ge 2 ]] || { echo "--type требует значение" >&2; exit 2; }
            TYPE="$2"; shift 2 ;;
        --wait)
            [[ $# -ge 2 ]] || { echo "--wait требует значение" >&2; exit 2; }
            START_TIMEOUT="$2"; shift 2 ;;
        --profile)
            [[ $# -ge 2 ]] || { echo "--profile требует значение" >&2; exit 2; }
            PROFILE="$2"; shift 2 ;;
        --dry-run|-n) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --yes) EXTRA_ARGS+=("--yes"); shift ;;
        --) shift; EXTRA_ARGS+=("$@"); break ;;
        -*) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -z "${COMMAND}" ]]; then
                COMMAND="$1"
            else
                EXTRA_ARGS+=("$1")
            fi
            shift ;;
    esac
done

[[ -n "${TYPE}" ]] || { echo "Не задан workload type (--type или CHAOS_WORKLOAD_TYPE)" >&2; exit 2; }
[[ "${TYPE}" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Недопустимый workload type: ${TYPE}" >&2; exit 2; }
[[ -z "${PROFILE}" || "${PROFILE}" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Недопустимый workload profile: ${PROFILE}" >&2; exit 2; }
[[ -n "${COMMAND}" ]] || { usage; exit 2; }
[[ "${START_TIMEOUT}" =~ ^[0-9]+$ ]] || { echo "--wait должен быть целым числом секунд" >&2; exit 2; }

ADAPTER="${ADAPTER_DIR}/${TYPE}.sh"
[[ -f "${ADAPTER}" ]] || { echo "Adapter не найден: ${ADAPTER}" >&2; exit 2; }

STATE_DIR="${STATE_ROOT}/${TYPE}"
PID_FILE="${STATE_DIR}/pid"
RUN_FILE="${STATE_DIR}/run-id"
GROUP_FILE="${STATE_DIR}/process-group"
LOG_DIR="${CHAOS_WORKLOAD_LOG_DIR:-${REPO_ROOT}/logs/workload}"
LOG_FILE="${LOG_DIR}/${TYPE}.log"
PROFILE_FILE="${STATE_DIR}/profile"

source "${REPO_ROOT}/lib/grafana.sh"

adapter() {
    CHAOS_WORKLOAD_PROFILE="${PROFILE}" WORKLOAD_DRY_RUN="${DRY_RUN}" bash "${ADAPTER}" "$@"
}

workload_event() {
    local event="$1" text="$2" timeline="${LOG_DIR}/timeline.log"
    mkdir -p "${LOG_DIR}"
    printf '%s  %-16s  %s\n' "$(date -Iseconds)" "${event}" "${text}" >>"${timeline}"
}

workload_annotation_open() {
    [[ "${ANNOTATIONS}" == true ]] || return 0
    grafana_region_open "workload-${TYPE}" "$1" workload
}

workload_annotation_close() {
    [[ "${ANNOTATIONS}" == true ]] || return 0
    grafana_region_close "workload-${TYPE}"
}

read_pid() {
    [[ -f "${PID_FILE}" ]] || return 1
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${pid}"
}

is_running() {
    local pid
    pid="$(read_pid)" || return 1
    kill -0 "${pid}" 2>/dev/null
}

cmd_info() {
    echo "type       : ${TYPE}"
    echo "adapter    : ${ADAPTER}"
    echo "state dir  : ${STATE_DIR}"
    echo "log        : ${LOG_FILE}"
    echo "profile    : ${PROFILE:-(default)}"
    if is_running; then
        echo "process    : RUNNING (pid $(read_pid))"
    elif [[ -f "${PID_FILE}" ]]; then
        echo "process    : STOPPED (stale pid $(cat "${PID_FILE}" 2>/dev/null || true))"
    else
        echo "process    : STOPPED"
    fi
    adapter info
}

cmd_prepare() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo "+ ${ADAPTER} prepare ${EXTRA_ARGS[*]}"
    fi
    adapter prepare "${EXTRA_ARGS[@]}"
}

cmd_start() {
    if is_running; then
        local active_profile
        active_profile="$(cat "${PROFILE_FILE}" 2>/dev/null || true)"
        if [[ "${active_profile}" == "${PROFILE}" ]]; then
            echo "workload ${TYPE} уже запущен: pid $(read_pid), profile ${PROFILE:-(default)}"
            return 0
        fi
        echo "workload ${TYPE} уже запущен с profile ${active_profile:-(default)}; сначала выполните stop" >&2
        return 1
    fi
    if [[ "${DRY_RUN}" == true ]]; then
        echo "+ nohup setsid ${ADAPTER} run > ${LOG_FILE} 2>&1 &"
        return 0
    fi

    mkdir -p "${STATE_DIR}" "${LOG_DIR}"
    rm -f "${PID_FILE}" "${GROUP_FILE}"
    local run_id pid grouped=false
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

    local can_group=true
    case "$(uname -s 2>/dev/null || true)" in
        MINGW*|MSYS*|CYGWIN*) can_group=false ;;
    esac
    if [[ "${can_group}" == true ]] && command -v setsid >/dev/null 2>&1; then
        nohup setsid env CHAOS_WORKLOAD_RUN_ID="${run_id}" WORKLOAD_DRY_RUN=false \
            CHAOS_WORKLOAD_PROFILE="${PROFILE}" \
            bash "${ADAPTER}" run >>"${LOG_FILE}" 2>&1 </dev/null &
        grouped=true
    else
        nohup env CHAOS_WORKLOAD_RUN_ID="${run_id}" WORKLOAD_DRY_RUN=false \
            CHAOS_WORKLOAD_PROFILE="${PROFILE}" \
            bash "${ADAPTER}" run >>"${LOG_FILE}" 2>&1 </dev/null &
    fi
    pid=$!
    printf '%s\n' "${pid}" > "${PID_FILE}"
    printf '%s\n' "${run_id}" > "${RUN_FILE}"
    printf '%s\n' "${grouped}" > "${GROUP_FILE}"
    printf '%s\n' "${PROFILE}" > "${PROFILE_FILE}"

    sleep 1
    if ! is_running; then
        echo "workload ${TYPE} завершился во время запуска; последние строки лога:" >&2
        tail -30 "${LOG_FILE}" >&2 || true
        rm -f "${PID_FILE}" "${GROUP_FILE}"
        return 1
    fi

    local waited=0
    until adapter health >/dev/null 2>&1; do
        if (( waited >= START_TIMEOUT )); then
            echo "workload ${TYPE} не прошёл health за ${START_TIMEOUT}s" >&2
            cmd_stop || true
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
        is_running || { echo "workload ${TYPE} остановился до готовности" >&2; return 1; }
    done
    local label="workload ${TYPE} / ${PROFILE:-(default)}"
    workload_event "WORKLOAD_START" "${label}"
    workload_annotation_open "WORKLOAD_START  ${label}"
    echo "workload ${TYPE} запущен: pid ${pid}, profile ${PROFILE:-(default)}, log ${LOG_FILE}"
}

cmd_status() {
    if ! is_running; then
        if [[ -f "${PID_FILE}" ]]; then
            echo "workload ${TYPE}: STOPPED (stale pid $(cat "${PID_FILE}" 2>/dev/null || true))"
        else
            echo "workload ${TYPE}: STOPPED"
        fi
        return 1
    fi
    local pid
    pid="$(read_pid)"
    if adapter health >/dev/null 2>&1; then
        echo "workload ${TYPE}: RUNNING, health=OK, pid=${pid}, profile=$(cat "${PROFILE_FILE}" 2>/dev/null || echo default)"
        return 0
    fi
    echo "workload ${TYPE}: RUNNING, health=FAILED, pid=${pid}" >&2
    return 2
}

cmd_stop() {
    local pid
    if ! pid="$(read_pid)" || ! kill -0 "${pid}" 2>/dev/null; then
        local active_profile label
        active_profile="$(cat "${PROFILE_FILE}" 2>/dev/null || true)"
        if [[ -f "${PROFILE_FILE}" ]]; then
            label="workload ${TYPE} / ${active_profile:-(default)}"
            workload_event "WORKLOAD_STOP" "${label} (process already stopped)"
            workload_annotation_close
        fi
        echo "workload ${TYPE} уже остановлен"
        adapter stop || true
        rm -f "${PID_FILE}" "${GROUP_FILE}" "${PROFILE_FILE}"
        return 0
    fi
    if [[ "${DRY_RUN}" == true ]]; then
        echo "+ kill -TERM ${pid}"
        return 0
    fi

    echo "останавливаю workload ${TYPE}: pid ${pid}"
    if [[ "$(cat "${GROUP_FILE}" 2>/dev/null || true)" == true ]]; then
        kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    else
        kill -TERM "${pid}" 2>/dev/null || true
    fi

    # Compose adapters own an external container process. Stop it immediately:
    # a shell waiting in `compose up` may defer its TERM trap until that child
    # exits. For binary adapters this operation is a no-op.
    adapter stop || true

    local waited=0 stop_timeout="${CHAOS_WORKLOAD_STOP_TIMEOUT:-15}"
    while kill -0 "${pid}" 2>/dev/null && (( waited < stop_timeout )); do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        echo "workload не завершился за ${stop_timeout}s, отправляю KILL" >&2
        if [[ "$(cat "${GROUP_FILE}" 2>/dev/null || true)" == true ]]; then
            kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
        else
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    fi
    rm -f "${PID_FILE}" "${GROUP_FILE}"
    local active_profile label
    active_profile="$(cat "${PROFILE_FILE}" 2>/dev/null || true)"
    label="workload ${TYPE} / ${active_profile:-(default)}"
    workload_event "WORKLOAD_STOP" "${label}"
    workload_annotation_close
    rm -f "${PROFILE_FILE}"
    echo "workload ${TYPE} остановлен"
}

cmd_action() {
    [[ ${#EXTRA_ARGS[@]} -gt 0 ]] || {
        echo "action требует имя действия adapter" >&2
        exit 2
    }
    local action_name="${EXTRA_ARGS[0]}" action_text annotate_action=true
    action_text="workload ${TYPE}: ${EXTRA_ARGS[*]}"
    adapter action "${EXTRA_ARGS[@]}"
    # `partitions` is the search adapter's read-only status query. Recording it
    # as a control action used to create a vertical Grafana marker on every
    # observer/poll iteration and hid the meaningful profile and split events.
    [[ "${action_name}" != partitions ]] || annotate_action=false
    if [[ "${DRY_RUN}" != true && "${annotate_action}" == true ]]; then
        workload_event "WORKLOAD_ACTION" "${action_text}"
        if [[ "${ANNOTATIONS}" == true ]]; then
            local marker="workload-action-${TYPE}"
            grafana_region_open "${marker}" "WORKLOAD_ACTION  ${action_text}" control
            grafana_region_close "${marker}"
        fi
    fi
}

case "${COMMAND}" in
    info) cmd_info ;;
    prepare) cmd_prepare ;;
    start) cmd_start ;;
    status) cmd_status ;;
    stop) cmd_stop ;;
    action) cmd_action ;;
    run) adapter run "${EXTRA_ARGS[@]}" ;;
    cleanup)
        [[ " ${EXTRA_ARGS[*]} " == *" --yes "* ]] || {
            echo "cleanup требует --yes" >&2; exit 2;
        }
        adapter cleanup "${EXTRA_ARGS[@]}"
        ;;
    *) echo "Неизвестная команда: ${COMMAND}" >&2; usage >&2; exit 2 ;;
esac
