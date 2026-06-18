#!/usr/bin/env bash
# PTY smoke-тест chaos-md через tmux.
#
# Запускает приложение в --dry-run, шлёт серию клавиш, на каждом шаге снимает
# буфер экрана и проверяет ключевые подстроки. Это «глазами пользователя»
# проверка реального TUI, в отличие от unit-тестов с TestBackend.
#
# Использование:
#   chaos-md/tests/pty_smoke.sh
#
# Зависимости: tmux, собранный бинарь chaos-md/target/release/chaos-md.
#
# Перед прогоном бэкапим .chaos-md-state.json в корне репозитория и кладём
# детерминированный — иначе результаты зависят от прошлых сессий.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN="${ROOT}/chaos-md/target/release/chaos-md"
LOG_DIR="${ROOT}/chaos-md/target/tmp/smoke"
STATE_FILE="${ROOT}/.chaos-md-state.json"
STATE_BAK=""

mkdir -p "${LOG_DIR}"

if [[ ! -x "${BIN}" ]]; then
    echo "Нет бинарника ${BIN}; собери: cargo build --release" >&2
    exit 1
fi

# Сохраняем существующий state и кладём пустой (всё false).
if [[ -f "${STATE_FILE}" ]]; then
    STATE_BAK="${STATE_FILE}.bak.$$"
    cp "${STATE_FILE}" "${STATE_BAK}"
fi
write_state() {
    cat > "${STATE_FILE}" <<JSON
{
  "selected": [false, false, false, false, false, false, false, false, false, false, false, false],
  "phases_node": true,
  "phases_dc": false,
  "phases_dc_alt": false,
  "dry_run": true,
  "time_test_s": 1200,
  "time_wait_s": 600
}
JSON
}

SESSIONS=()
cleanup() {
    for s in "${SESSIONS[@]}"; do
        tmux kill-session -t "${s}" 2>/dev/null || true
    done
    if [[ -n "${STATE_BAK}" ]]; then
        mv "${STATE_BAK}" "${STATE_FILE}"
    else
        rm -f "${STATE_FILE}"
    fi
}
trap cleanup EXIT

snap() {
    local sess="$1" name="$2"
    tmux capture-pane -p -t "${sess}" > "${LOG_DIR}/${name}.txt"
    printf "  snap → %s\n" "${LOG_DIR}/${name}.txt"
}

assert_contains() {
    local file="$1" needle="$2" label="$3"
    if ! grep -qF -- "${needle}" "${file}"; then
        echo "FAIL [${label}]: ожидали «${needle}» в ${file}" >&2
        cat "${file}" >&2
        exit 1
    fi
    printf "  ok   [%s] contains «%s»\n" "${label}" "${needle}"
}

assert_absent() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "${needle}" "${file}"; then
        echo "FAIL [${label}]: НЕ ожидали «${needle}» в ${file}" >&2
        exit 1
    fi
    printf "  ok   [%s] absent «%s»\n" "${label}" "${needle}"
}

new_session() {
    local sess="$1"
    tmux new-session -d -s "${sess}" -x 120 -y 40 \
        "${BIN}" --root "${ROOT}" --dry-run
    SESSIONS+=("${sess}")
    sleep 0.5
}

# ═══════════════════════════════════════════════════════════════════════════
# SCENARIO 1: чистая навигация, диалоги
# ═══════════════════════════════════════════════════════════════════════════
write_state
S1="chaos-md-smoke-$$-1"
new_session "${S1}"

echo "== Idle =="
snap "${S1}" 01_idle
assert_contains "${LOG_DIR}/01_idle.txt" "Тесты"   "idle: selector title"
assert_contains "${LOG_DIR}/01_idle.txt" "ЗАПУСК"  "idle: start button"
assert_contains "${LOG_DIR}/01_idle.txt" "DRY-RUN" "idle: dry-run banner"
assert_contains "${LOG_DIR}/01_idle.txt" "01 cpu"  "idle: first test"
assert_contains "${LOG_DIR}/01_idle.txt" "12 server" "idle: last test"
assert_contains "${LOG_DIR}/01_idle.txt" "Tab"     "idle: status bar Tab"

echo "== Config dialog =="
tmux send-keys -t "${S1}" "i"
sleep 0.3
snap "${S1}" 02_config
assert_contains "${LOG_DIR}/02_config.txt" "Configuration" "config dialog title"
assert_contains "${LOG_DIR}/02_config.txt" "Repo root"     "config: repo root row"

tmux send-keys -t "${S1}" "Escape"
sleep 0.25
snap "${S1}" 03_config_closed
assert_absent "${LOG_DIR}/03_config_closed.txt" "Configuration" "config closed"

echo "== Select test via Space =="
# Курсор уже на 01 (после загрузки чистого state). Просто пробел.
tmux send-keys -t "${S1}" " "
sleep 0.3
snap "${S1}" 04_first_selected
assert_contains "${LOG_DIR}/04_first_selected.txt" "☑ 01" "first test marked"

echo "== Tab cycles through subgroups =="
# Tab #1: TestList → TimeFields. Курсор переезжает на «Время:».
tmux send-keys -t "${S1}" "Tab"
sleep 0.3
snap "${S1}" 05_tab1_time_fields
assert_contains "${LOG_DIR}/05_tab1_time_fields.txt" "Время:" "Tab 1: still in selector, TimeFields"

# DOS-ввод: 5 → значение становится 5 (заменяет, а не дописывает к 1200)
tmux send-keys -t "${S1}" "5"
sleep 0.2
snap "${S1}" 06_dos_input
assert_contains "${LOG_DIR}/06_dos_input.txt" "Время:▕    5 ▏" "DOS input: first digit replaced 1200 with 5"

# Дописываем
tmux send-keys -t "${S1}" "0"
sleep 0.2
snap "${S1}" 07_dos_append
assert_contains "${LOG_DIR}/07_dos_append.txt" "Время:▕   50 ▏" "DOS input: subsequent digit appends"

# Enter → переход на TimeWait
tmux send-keys -t "${S1}" "Enter"
sleep 0.2
tmux send-keys -t "${S1}" "7"
sleep 0.2
snap "${S1}" 08_enter_to_next_field
assert_contains "${LOG_DIR}/08_enter_to_next_field.txt" "Пауза:▕    7 ▏" "Enter moved to TimeWait, digit replaced"

# Tab #2: TimeFields → StartButton
tmux send-keys -t "${S1}" "Tab"
sleep 0.3
snap "${S1}" 09_tab2_start
assert_contains "${LOG_DIR}/09_tab2_start.txt" "ЗАПУСК" "Tab 2: cursor on Start button"

# Tab #3: StartButton → Log
tmux send-keys -t "${S1}" "Tab"
sleep 0.3
snap "${S1}" 10_tab3_log
# В Log-фокусе селектор не сбросился
assert_contains "${LOG_DIR}/10_tab3_log.txt" "☑ 01" "Tab 3: in Log, selection persists"

echo "== Quit from idle =="
tmux send-keys -t "${S1}" "q"
sleep 0.5
if tmux has-session -t "${S1}" 2>/dev/null; then
    echo "FAIL: q в idle не закрыл приложение"
    snap "${S1}" 99_after_q
    exit 1
fi
echo "  ok   приложение закрылось"

# ═══════════════════════════════════════════════════════════════════════════
# SCENARIO 2: Running → Stop confirm → cancel → confirm
# ═══════════════════════════════════════════════════════════════════════════
echo "== Running → Stop confirm =="
write_state
# Включим test 01 и поставим короткое время
cat > "${STATE_FILE}" <<JSON
{
  "selected": [true, false, false, false, false, false, false, false, false, false, false, false],
  "phases_node": true,
  "phases_dc": false,
  "phases_dc_alt": false,
  "dry_run": true,
  "time_test_s": 30,
  "time_wait_s": 1
}
JSON

S2="chaos-md-smoke-$$-2"
new_session "${S2}"
snap "${S2}" 10_idle_pre
assert_contains "${LOG_DIR}/10_idle_pre.txt" "☑ 01" "test 01 preselected"

# Запустить через глобальный S
tmux send-keys -t "${S2}" "S"
sleep 1.2
snap "${S2}" 11_running
assert_contains "${LOG_DIR}/11_running.txt" "СТОП" "running: button shows СТОП"
# Статус-бар тоже должен переключиться на «Стоп!»
assert_contains "${LOG_DIR}/11_running.txt" "Стоп!" "running: status bar shows Стоп!"

# Открыть подтверждение остановки через глобальный S
tmux send-keys -t "${S2}" "S"
sleep 0.4
snap "${S2}" 12_stop_confirm
assert_contains "${LOG_DIR}/12_stop_confirm.txt" "Остановить хаос" "stop confirm dialog visible"
assert_contains "${LOG_DIR}/12_stop_confirm.txt" "y / Enter" "stop confirm shows hints"

# Отменить
tmux send-keys -t "${S2}" "Escape"
sleep 0.4
snap "${S2}" 13_stop_cancelled
assert_absent  "${LOG_DIR}/13_stop_cancelled.txt" "Остановить хаос?" "stop confirm closed"
assert_contains "${LOG_DIR}/13_stop_cancelled.txt" "СТОП" "still running after cancel"

# Реально остановить
tmux send-keys -t "${S2}" "S"
sleep 0.3
tmux send-keys -t "${S2}" "y"
sleep 2.0
snap "${S2}" 14_stop_requested
assert_contains "${LOG_DIR}/14_stop_requested.txt" "запрошена остановка" "stop kicked in"
# Должен запуститься teardown-шаг
assert_contains "${LOG_DIR}/14_stop_requested.txt" "teardown" "teardown step started"
# Timeline должен показать CHAOS_CANCEL
assert_contains "${LOG_DIR}/14_stop_requested.txt" "CHAOS_CANCEL" "timeline has CHAOS_CANCEL"

# ═══════════════════════════════════════════════════════════════════════════
# SCENARIO 3: Quit confirmation visible during running
# ═══════════════════════════════════════════════════════════════════════════
echo "== Quit confirm during running =="
S3="chaos-md-smoke-$$-3"
new_session "${S3}"
tmux send-keys -t "${S3}" "S"
sleep 1.0
tmux send-keys -t "${S3}" "q"
sleep 0.4
snap "${S3}" 20_quit_confirm
assert_contains "${LOG_DIR}/20_quit_confirm.txt" "Выйти из приложения" "quit hint visible"
assert_contains "${LOG_DIR}/20_quit_confirm.txt" "подтвердить" "quit confirm text"

tmux send-keys -t "${S3}" "n"
sleep 0.4
snap "${S3}" 21_quit_cancelled
assert_absent "${LOG_DIR}/21_quit_cancelled.txt" "Выйти из приложения" "quit prompt cleared"

# Финальный выход через y. Принудительно завершаем сессию, так как
# teardown в dry-run может работать долго.
tmux kill-session -t "${S3}" 2>/dev/null || true
tmux kill-session -t "${S2}" 2>/dev/null || true

echo
echo "PTY smoke: PASS"
echo "Скриншоты: ${LOG_DIR}"
