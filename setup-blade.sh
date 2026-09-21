#!/usr/bin/env bash
# Тонкая обёртка: только установка ChaosBlade через prepare-hosts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/prepare-hosts.sh" \
    --no-packages \
    --no-upgrade-dist \
    "$@"
