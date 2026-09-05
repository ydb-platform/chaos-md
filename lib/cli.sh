#!/usr/bin/env bash
# Единый разбор аргументов командной строки тестов хаоса.
#
# Общие флаги (одинаковые во всех тестах):
#   -1 / --single        scope: одна нода (NODE_HOST или SINGLE_HOST)
#   -4 / --dc            scope: основной ДЦ (DC_HOSTS)
#   -A / --dc-alt        scope: альтернативный ДЦ (DC_ALT_HOSTS)
#   -t / --time SEC      длительность фазы хаоса
#   -H / --host HOST     переопределить хост для -1
#   -D / --teardown      снять хаос
#   --hold               применить хаос и вернуть управление без локального ожидания
#   -C / --check [HOST]  показать состояние
#   -h / --help          справка
#
# chaos_parse_common "$@"  — заполняет глобалы, неузнанные опции складывает
# в массив CHAOS_REMAINING_ARGS. Тест разбирает свои опции из этого массива.
#
# chaos_require_scope <single|dc|either|node_or_dc_or_alt|none> — валидация.

# Дефолты
SCOPE_SINGLE=false
SCOPE_DC=false
SCOPE_DC_ALT=false
MODE_TEARDOWN=false
MODE_CHECK=false
MODE_HOLD=false
CHECK_HOST=""
NODE_HOST="${SINGLE_HOST:-}"
TIMEOUT="${DEFAULT_CHAOS_TIMEOUT:-1200}"
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"
CHAOS_REMAINING_ARGS=()

chaos_parse_common() {
    CHAOS_REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -1|--single)   SCOPE_SINGLE=true; shift ;;
            -4|--dc)       SCOPE_DC=true;     shift ;;
            -A|--dc-alt)   SCOPE_DC_ALT=true; shift ;;
            -t|--time)     TIMEOUT="$2";      shift 2 ;;
            -H|--host)     NODE_HOST="$2";    shift 2 ;;
            -D|--teardown) MODE_TEARDOWN=true; shift ;;
            --hold)         MODE_HOLD=true;     shift ;;
            -N|--dry-run)  CHAOS_DRY_RUN=true; shift ;;
            -C|--check)
                MODE_CHECK=true
                CHECK_HOST="${SINGLE_HOST:-}"
                if [[ $# -gt 1 && "$2" != -* ]]; then CHECK_HOST="$2"; shift; fi
                shift ;;
            -h|--help) chaos_usage; exit 0 ;;
            *) CHAOS_REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
}

# Печать справки. Тест переопределяет chaos_usage_extra (печать строк
# дополнительных опций) и переменные TEST_NAME / TEST_DESC / TEST_SCOPE.
chaos_usage() {
    local script
    script="$(basename "${CHAOS_CMDLINE[0]:-$0}")"

    local scope_line=""
    case "${TEST_SCOPE:-either}" in
        single)               scope_line="-1" ;;
        dc)                   scope_line="-4" ;;
        either)               scope_line="-1|-4" ;;
        node_or_dc_or_alt)    scope_line="-1|-4|-A" ;;
        none)                 scope_line="" ;;
    esac

    cat <<EOF
Использование: ${script} ${scope_line:+${scope_line} }[ОПЦИИ]

${TEST_DESC:-${TEST_NAME}}
EOF

    if [[ "${TEST_SCOPE:-either}" != "none" ]]; then
        echo ""
        echo "Scope (ровно один из):"
        case "${TEST_SCOPE:-either}" in
            single|either|node_or_dc_or_alt)
                echo "  -1, --single          Одна нода (-H или ${SINGLE_HOST:-?})"
                ;;
        esac
        case "${TEST_SCOPE:-either}" in
            dc|either|node_or_dc_or_alt)
                echo "  -4, --dc              Основной ДЦ (${#DC_HOSTS[@]} нод: DC_HOSTS)"
                ;;
        esac
        case "${TEST_SCOPE:-either}" in
            node_or_dc_or_alt)
                echo "  -A, --dc-alt          Альтернативный ДЦ (${#DC_ALT_HOSTS[@]} нод: DC_ALT_HOSTS)"
                ;;
        esac
    fi

    echo ""
    echo "Общие опции:"
    if [[ "${TEST_SCOPE:-either}" != "none" ]]; then
        cat <<EOF
  -t, --time SEC        Длительность фазы хаоса, с (по умолчанию: ${DEFAULT_CHAOS_TIMEOUT:-1200})
  -H, --host HOST       Переопределить хост для -1
  -D, --teardown        Снять хаос (откат). Без -1/-4/-A обрабатываются все хосты из env: NODE_HOST (-H), SINGLE_HOST, DC_HOSTS, DC_ALT_HOSTS и CLUSTER_HOSTS (дедуп).
  --hold                Применить хаос и сразу вернуть управление. Снять отдельным вызовом -D; удалённый safety-таймер -t остаётся активным, если немезис его поддерживает.
  -C, --check [HOST]    Показать состояние (без HOST — ${SINGLE_HOST:-?})
  -N, --dry-run         Не выполнять ssh/scp; показать только что бы запустилось
EOF
    else
        echo "  -C, --check [HOST]    Показать состояние (без HOST — ${SINGLE_HOST:-?})"
    fi
    echo "  -h, --help            Эта справка"

    if declare -F chaos_usage_extra >/dev/null; then
        echo ""
        echo "Опции теста:"
        chaos_usage_extra
    fi

    if declare -F chaos_usage_examples >/dev/null; then
        echo ""
        echo "Примеры:"
        chaos_usage_examples
    fi
}

# Проверка scope. Печатает в stderr и возвращает 1 при ошибке.
chaos_require_scope() {
    local mode="${1:-${TEST_SCOPE:-either}}"
    case "${mode}" in
        single)
            [[ "${SCOPE_SINGLE}" == true ]] || { echo "Ошибка: укажите -1 (одна нода)." >&2; return 1; }
            [[ "${SCOPE_DC}" != true && "${SCOPE_DC_ALT}" != true ]] \
                || { echo "Ошибка: для этого теста допустим только -1." >&2; return 1; }
            ;;
        dc)
            [[ "${SCOPE_DC}" == true ]] || { echo "Ошибка: укажите -4 (ДЦ)." >&2; return 1; }
            [[ "${SCOPE_SINGLE}" != true && "${SCOPE_DC_ALT}" != true ]] \
                || { echo "Ошибка: для этого теста допустим только -4." >&2; return 1; }
            ;;
        either)
            local cnt=0
            [[ "${SCOPE_SINGLE}" == true ]] && ((++cnt))
            [[ "${SCOPE_DC}"     == true ]] && ((++cnt))
            (( cnt == 1 )) || { echo "Ошибка: укажите ровно один флаг: -1 или -4." >&2; return 1; }
            ;;
        node_or_dc_or_alt)
            local cnt=0
            [[ "${SCOPE_SINGLE}" == true ]] && ((++cnt))
            [[ "${SCOPE_DC}"     == true ]] && ((++cnt))
            [[ "${SCOPE_DC_ALT}" == true ]] && ((++cnt))
            (( cnt == 1 )) || { echo "Ошибка: укажите ровно один из -1, -4, -A." >&2; return 1; }
            ;;
        none)
            ;;
        *)
            echo "chaos_require_scope: неизвестный режим ${mode}" >&2; return 1 ;;
    esac
}
