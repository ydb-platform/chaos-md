#!/usr/bin/env bash
# Переключение активного env: env.sh → env-<имя>.sh (символическая ссылка).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
    cat <<EOF
Использование: $(basename "$0") <имя>|--status

  Создаёт симлинк env.sh на файл env-<имя>.sh в каталоге репозитория.
  Если env-<имя>.sh нет — выход с ошибкой (ничего не меняется).

Примеры:
  $(basename "$0") scale-yc    → env-scale-yc.sh
  $(basename "$0") scale       → env-scale.sh
  $(basename "$0") --status
EOF
}

status() {
    if [[ -L env.sh ]]; then
        echo "env.sh -> $(readlink env.sh)"
    elif [[ -e env.sh ]]; then
        echo "env.sh (regular file)"
    else
        echo "env.sh (missing)"
    fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -eq 0 || "${1:-}" == "-s" || "${1:-}" == "--status" ]]; then
    status
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

name="$1"
src="env-${name}.sh"
src_path="${SCRIPT_DIR}/${src}"
link_path="${SCRIPT_DIR}/env.sh"

if [[ ! -f "${src_path}" ]]; then
    echo "Ошибка: файл «${src}» не найден в ${SCRIPT_DIR}" >&2
    exit 1
fi

ln -sfn "${src}" env.sh

echo "OK: env.sh → ${src}"
