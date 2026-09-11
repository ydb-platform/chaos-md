#!/usr/bin/env bash
# Высокоуровневые обёртки жизненного цикла теста.
#
# Типичный сценарий хаос-теста:
#   1. parse args
#   2. resolve targets
#   3. apply chaos
#   4. wait with timer
#   5. teardown
# Эта функция объединяет 3–5 в одной точке, единообразно для всех тестов.

# Анонсировать целевой ресурс крупно, цветом C_HOST. Затем — параметры в лог.
chaos_announce() {
    chaos_term_target "$(chaos_target_description)"
    log "Параметры: $*"
}

chaos_run_checks() {
    local check_fn="$1"; shift
    chaos_resolve_check_targets
    parallel_for_hosts "${check_fn}" "${TARGET_HOSTS[@]}" -- "$@"
    chaos_json_emit check command_succeeded null
}

# Запустить хаос с автоматическим тикером и явным снятием по окончании окна.
#
# Использование:
#   chaos_run_window <timeline_short_desc> <apply_fn> <teardown_fn>
#
# apply_fn / teardown_fn вызываются как: <fn> "${TARGET_HOSTS[@]}".
# timeline_short_desc — короткая строка для timeline.log (CHAOS_START / END).
#
# Поведение:
#   - apply_fn выполняется на всех TARGET_HOSTS (фоновый таймер на хосте — ответственность немезиса);
#   - локально ждём TIMEOUT с тикером;
#   - вызываем teardown_fn (явное снятие; даже если фоновый таймер на хосте уже снял хаос — операция идемпотентна).
chaos_run_window() {
    local short="$1" apply_fn="$2" teardown_fn="$3"
    local previous_int previous_term
    previous_int="$(trap -p INT)"
    previous_term="$(trap -p TERM)"

    _chaos_run_window_restore_traps() {
        if [[ -n "${previous_int}" ]]; then eval "${previous_int}"; else trap - INT; fi
        if [[ -n "${previous_term}" ]]; then eval "${previous_term}"; else trap - TERM; fi
    }

    _chaos_run_window_interrupt() {
        local signal="$1" rc=130 cleanup_rc=0
        [[ "${signal}" == TERM ]] && rc=143
        trap - INT TERM
        log "Получен ${signal}. Хаос снимается."
        "${teardown_fn}" "${TARGET_HOSTS[@]}" || cleanup_rc=$?
        if ((cleanup_rc == 0)); then
            log_tl "CHAOS_CANCEL" "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}  signal=${signal}"
        else
            log "Снятие после ${signal} завершилось ошибкой."
            chaos_json_emit teardown command_failed "${cleanup_rc}" "${short}  interrupted; teardown failed"
        fi
        exit "${rc}"
    }

    trap '_chaos_run_window_interrupt INT' INT
    trap '_chaos_run_window_interrupt TERM' TERM

    if ! "${apply_fn}" "${TARGET_HOSTS[@]}"; then
        log "Применение хаоса завершилось ошибкой. Выполняется компенсация."
        "${teardown_fn}" "${TARGET_HOSTS[@]}" || log "Компенсация после ошибки применения тоже завершилась ошибкой."
        chaos_json_emit teardown command_failed 1 "${short}  apply failed; compensation attempted"
        _chaos_run_window_restore_traps
        return 1
    fi
    log_tl "CHAOS_START" "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}  timeout=${TIMEOUT}s"

    log_wait_sec "${TIMEOUT}"
    if ! chaos_wait_with_timer "${TIMEOUT}" "${short}  ${SCOPE_LABEL}=${#TARGET_HOSTS[@]}h"; then
        log "Ожидание завершилось досрочно. Хаос снимается."
        "${teardown_fn}" "${TARGET_HOSTS[@]}" || log "Снятие после досрочного завершения тоже завершилось ошибкой."
        chaos_json_emit teardown command_failed 1 "${short}  wait interrupted; teardown attempted"
        _chaos_run_window_restore_traps
        return 1
    fi

    if ! "${teardown_fn}" "${TARGET_HOSTS[@]}"; then
        chaos_json_emit teardown command_failed 1 "${short}  teardown failed"
        _chaos_run_window_restore_traps
        return 1
    fi
    chaos_json_emit teardown command_succeeded null "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}"
    log_tl "CHAOS_END  " "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}"
    _chaos_run_window_restore_traps
}

# Аналог, но без явного снятия после ожидания (хаос завершается сам по таймеру
# на хосте, например ChaosBlade --timeout). Используется для blade-тестов.
chaos_run_window_no_teardown() {
    local short="$1" apply_fn="$2"

    "${apply_fn}" "${TARGET_HOSTS[@]}"
    log_tl "CHAOS_START" "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}  timeout=${TIMEOUT}s"

    log_wait_sec "${TIMEOUT}"
    chaos_wait_with_timer "${TIMEOUT}" "${short}  ${SCOPE_LABEL}=${#TARGET_HOSTS[@]}h"

    log_tl "CHAOS_END  " "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}"
}
