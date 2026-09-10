#!/usr/bin/env bash
# Деплой дашборда Grafana через API из grafana/dashboards/chaos-tests.json.
# Создаёт дашборд если не существует, обновляет существующий (по заголовку).
# Последнее использованное имя сохраняет в grafana/.chaos-grafana-last.
#
# Используется для горячего апдейта дашборда на уже работающей Grafana
# (любой стенд). Альтернатива — provisioning из 04-dashboards-provision.sh.
#
# Сценарий использования:
#   ./grafana/deploy-dashboard.sh           # интерактивно; дефолт — последнее имя
#   GRAFANA_DASH_NAME="Chaos Tests" ./grafana/deploy-dashboard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/env.sh"

DASHBOARD_JSON="${SCRIPT_DIR}/dashboards/chaos/chaos-tests.json"
STATE_FILE="${SCRIPT_DIR}/.chaos-grafana-last"
FALLBACK_NAME="Chaos Tests"

if [[ -z "${GRAFANA_URL:-}" || -z "${GRAFANA_TOKEN:-}" ]]; then
    echo "Ошибка: GRAFANA_URL и GRAFANA_TOKEN должны быть заданы (env.local.sh)" >&2
    exit 1
fi

if [[ ! -f "${DASHBOARD_JSON}" ]]; then
    echo "Ошибка: ${DASHBOARD_JSON} не найден" >&2
    exit 1
fi

default="${FALLBACK_NAME}"
[[ -f "${STATE_FILE}" ]] && default=$(tr -d '\n' < "${STATE_FILE}")

if [[ -n "${GRAFANA_DASH_NAME:-}" ]]; then
    title="${GRAFANA_DASH_NAME}"
else
    printf "Имя дашборда [%s]: " "${default}"
    read -r input_name
    title="${input_name:-${default}}"
fi

echo "Деплой: ${title}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
search_file="${tmp_dir}/search.json"
full_file="${tmp_dir}/full.json"
payload_file="${tmp_dir}/payload.json"
response_file="${tmp_dir}/response.json"

http_code="$(curl -sk --max-time 15 -o "${search_file}" -w '%{http_code}' \
    -G "${GRAFANA_URL%/}/api/search" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    --data-urlencode "query=${title}" \
    --data-urlencode 'type=dash-db')"
[[ "${http_code}" == 200 ]] || { echo "Ошибка Grafana HTTP ${http_code}: $(cat "${search_file}")" >&2; exit 1; }

uid="$(jq -r --arg title "${title}" '[.[] | select(.title == $title)][0].uid // empty' "${search_file}")"
if [[ -n "${uid}" ]]; then
    http_code="$(curl -sk --max-time 15 -o "${full_file}" -w '%{http_code}' \
        "${GRAFANA_URL%/}/api/dashboards/uid/${uid}" \
        -H "Authorization: Bearer ${GRAFANA_TOKEN}")"
    [[ "${http_code}" == 200 ]] || { echo "Ошибка Grafana HTTP ${http_code}: $(cat "${full_file}")" >&2; exit 1; }
    dash_id="$(jq -r '.dashboard.id' "${full_file}")"
    version="$(jq -r '.dashboard.version // 1' "${full_file}")"
    jq -n \
        --slurpfile dashboards "${DASHBOARD_JSON}" \
        --arg title "${title}" --arg uid "${uid}" \
        --argjson id "${dash_id}" --argjson version "${version}" \
        '{dashboard:($dashboards[0] + {title:$title,id:$id,uid:$uid,version:$version}),overwrite:true,message:"deploy-dashboard.sh"}' \
        > "${payload_file}"
    echo "Обновление uid=${uid}"
else
    jq -n --slurpfile dashboards "${DASHBOARD_JSON}" --arg title "${title}" \
        '{dashboard:($dashboards[0] + {title:$title} | del(.id,.uid)),overwrite:false,message:"deploy-dashboard.sh"}' \
        > "${payload_file}"
    echo "Создание нового дашборда"
fi

http_code="$(curl -sk --max-time 15 -o "${response_file}" -w '%{http_code}' \
    -XPOST "${GRAFANA_URL%/}/api/dashboards/db" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${payload_file}")"
[[ "${http_code}" == 200 ]] || { echo "Ошибка Grafana HTTP ${http_code}: $(cat "${response_file}")" >&2; exit 1; }
dash_url="${GRAFANA_URL%/}$(jq -r '.url // empty' "${response_file}")"

echo "${title}" > "${STATE_FILE}"
echo "Готово: ${dash_url}"
