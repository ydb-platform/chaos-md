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

    "${apply_fn}" "${TARGET_HOSTS[@]}"
    log_tl "CHAOS_START" "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}  timeout=${TIMEOUT}s"

    if [[ "${MODE_HOLD:-false}" == true ]]; then
        log "Хаос оставлен активным; снимите его отдельным вызовом с -D"
        return 0
    fi

    log_wait_sec "${TIMEOUT}"
    chaos_wait_with_timer "${TIMEOUT}" "${short}  ${SCOPE_LABEL}=${#TARGET_HOSTS[@]}h"

    "${teardown_fn}" "${TARGET_HOSTS[@]}"
    log_tl "CHAOS_END  " "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}"
}

# Аналог, но без явного снятия после ожидания (хаос завершается сам по таймеру
# на хосте, например ChaosBlade --timeout). Используется для blade-тестов.
chaos_run_window_no_teardown() {
    local short="$1" apply_fn="$2"

    "${apply_fn}" "${TARGET_HOSTS[@]}"
    log_tl "CHAOS_START" "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}  timeout=${TIMEOUT}s"

    if [[ "${MODE_HOLD:-false}" == true ]]; then
        log "Хаос оставлен активным; снимите его отдельным вызовом с -D"
        return 0
    fi

    log_wait_sec "${TIMEOUT}"
    chaos_wait_with_timer "${TIMEOUT}" "${short}  ${SCOPE_LABEL}=${#TARGET_HOSTS[@]}h"

    log_tl "CHAOS_END  " "${short}  scope=${SCOPE_LABEL}  hosts=${#TARGET_HOSTS[@]}"
}
