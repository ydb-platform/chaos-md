#!/usr/bin/env bash
# Создаёт аннотацию в Grafana (POST /api/annotations).
# Требует: GRAFANA_URL и GRAFANA_TOKEN в env.local.sh (или в окружении).
#
# Текст аннотации — обязателен, задаётся после всех ключей (один или несколько аргументов
# склеиваются через пробел).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/env.sh"

# Дашборд по умолчанию (UID берётся из пути /d/<uid>/...).
# Можно задать через GRAFANA_DASHBOARD_URL в env.local.sh, либо через -u/--url.
DEFAULT_DASHBOARD_URL="${GRAFANA_DASHBOARD_URL:-}"

usage() {
    cat <<EOF
Использование:
  $(basename "$0") [КЛЮЧИ] <текст аннотации>...

Текст обязателен и идёт после всех ключей (несколько слов — несколько аргументов).

Ключи:
  -h, --help                 Эта справка
  -a, --all                  Аннотация на весь org (без привязки к дашборду)
  -u, --url URL              Ссылка на дашборд (по умолчанию: GRAFANA_DASHBOARD_URL)
  -U, --uid UID              UID дашборда явно (имеет приоритет над -u)
  -g, --grafana-url URL      Базовый URL API (по умолчанию: GRAFANA_URL из env)
  -t, --tags СПИСОК          Теги через запятую (по умолчанию: chaos)
  -T, --time MS              Время начала, мс с epoch (по умолчанию: сейчас)
  -E, --time-end MS          Конец интервала, мс (по умолчанию: как -T — точечная аннотация)

Переменные: GRAFANA_URL, GRAFANA_TOKEN, GRAFANA_DASHBOARD_URL.

Примеры:
  $(basename "$0") "CPU chaos start"
  $(basename "$0") -t chaos,manual "Проверка после деплоя"
  $(basename "$0") -a "Событие на всех дашбордах с подходящим query"
  $(basename "$0") -U other-dashboard "Только на указанном UID"
  $(basename "$0") -- "-текст начинается как ключ"
EOF
}

_grafana_time_ms() {
    if date +%s%3N 2>/dev/null | grep -q '^[0-9]\{13\}$'; then
        date +%s%3N
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

ALL_DASHBOARDS=false
DASHBOARD_URL="${DEFAULT_DASHBOARD_URL}"
EXPLICIT_UID=""
GRAFANA_API_BASE="${GRAFANA_URL:-}"
TAGS_CSV="chaos"
TIME_MS=""
TIME_END_MS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        -a|--all)         ALL_DASHBOARDS=true; shift ;;
        -u|--url)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            DASHBOARD_URL="$2"; shift 2 ;;
        -U|--uid)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            EXPLICIT_UID="$2"; shift 2 ;;
        -g|--grafana-url)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            GRAFANA_API_BASE="$2"; shift 2 ;;
        -t|--tags)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            TAGS_CSV="$2"; shift 2 ;;
        -T|--time)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            TIME_MS="$2"; shift 2 ;;
        -E|--time-end)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            TIME_END_MS="$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "Неизвестный ключ: $1" >&2; usage >&2; exit 1 ;;
        *)  break ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

ANN_TEXT="$*"

if [[ -z "${GRAFANA_API_BASE}" || -z "${GRAFANA_TOKEN:-}" ]]; then
    echo "Ошибка: задайте GRAFANA_URL (-g) и GRAFANA_TOKEN" >&2
    exit 1
fi

if [[ "${ALL_DASHBOARDS}" == true && -n "${EXPLICIT_UID}" ]]; then
    echo "Ошибка: нельзя одновременно -a/--all и -U/--uid" >&2
    exit 1
fi

[[ -z "${TIME_MS}" ]] && TIME_MS="$(_grafana_time_ms)"
[[ -z "${TIME_END_MS}" ]] && TIME_END_MS="${TIME_MS}"

DASH_UID=""
if [[ "${ALL_DASHBOARDS}" != true ]]; then
    if [[ -n "${EXPLICIT_UID}" ]]; then
        DASH_UID="${EXPLICIT_UID}"
    elif [[ -z "${DASHBOARD_URL}" ]]; then
        echo "Ошибка: не задан дашборд (-u/--url, -U/--uid или GRAFANA_DASHBOARD_URL в env)" >&2
        echo "       Или используйте -a для org-wide аннотации." >&2
        exit 1
    else
        DASH_PATH="${DASHBOARD_URL%%[?#]*}"
        case "${DASH_PATH}" in
            */d/*) DASH_UID="${DASH_PATH#*/d/}"; DASH_UID="${DASH_UID%%/*}" ;;
            *) echo "Ошибка: не удалось извлечь UID дашборда из URL (ожидается путь /d/<uid>/...)" >&2; exit 1 ;;
        esac
        [[ -n "${DASH_UID}" ]] || { echo "Ошибка: UID дашборда пуст" >&2; exit 1; }
    fi
fi

PAYLOAD="$(jq -nc \
    --arg text "${ANN_TEXT}" \
    --arg tags "${TAGS_CSV}" \
    --arg uid "${DASH_UID}" \
    --argjson time "${TIME_MS}" \
    --argjson timeEnd "${TIME_END_MS}" \
    --argjson orgWide "${ALL_DASHBOARDS}" \
    '{time:$time,timeEnd:$timeEnd,tags:($tags|split(",")|map(gsub("^[[:space:]]+|[[:space:]]+$";"")|select(length>0))),text:$text}
     + if ($orgWide or ($uid|length)==0) then {} else {dashboardUID:$uid} end')"

resp_file=$(mktemp)
trap 'rm -f "${resp_file}"' EXIT
http_code=$(curl -sk --max-time 15 \
    -o "${resp_file}" -w "%{http_code}" \
    -XPOST "${GRAFANA_API_BASE%/}/api/annotations" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")

if [[ "${http_code}" != "200" ]]; then
    echo "Ошибка Grafana HTTP ${http_code}: $(cat "${resp_file}")" >&2
    exit 1
fi

jq -r '"id=\(.id // "?")"' "${resp_file}" 2>/dev/null || cat "${resp_file}"
