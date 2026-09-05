#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

captured=""
log() { :; }
log_chaos_apply() { :; }
chaos_term_remote_cmd() { :; }
chaos_log_remote_script() { :; }
ssh() { captured="$(cat)"; }

SSH_OPTS=()
YDBD_BIN=/opt/ydb/bin/ydbd
YDBD_STORAGE_SERVICE=ydbd-storage.service
YDBD_TENANT_SERVICES=(ydbd-database-a.service)

# shellcheck source=../nemesis/proc.sh
source "${ROOT}/nemesis/proc.sh"

nemesis_proc_kill_hold_apply node-1
grep -Fq 'sudo kill -9 ${pids}' <<<"${captured}"
grep -Fq 'sudo systemctl stop "${TENANTS[@]}"' <<<"${captured}"
grep -Fq 'sudo systemctl stop "${STORAGE_SERVICE}"' <<<"${captured}"

captured=""
nemesis_proc_kill_teardown node-1
grep -Fq 'sudo systemctl start "${STORAGE_SERVICE}"' <<<"${captured}"
grep -Fq 'sudo systemctl start "${TENANTS[@]}"' <<<"${captured}"

echo "proc kill hold smoke: OK"
