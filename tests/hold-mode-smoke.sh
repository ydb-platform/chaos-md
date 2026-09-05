#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli.sh
source "${ROOT}/lib/cli.sh"
chaos_parse_common -1 --hold -t 321
[[ "${SCOPE_SINGLE}" == true ]]
[[ "${MODE_HOLD}" == true ]]
[[ "${TIMEOUT}" == 321 ]]

events=()
TARGET_HOSTS=(node-1)
SCOPE_LABEL=node
TIMEOUT=321

log() { :; }
log_tl() { events+=("$1"); }
apply() { events+=(apply); }
teardown() { events+=(teardown); }
log_wait_sec() { events+=(wait-log); }
chaos_wait_with_timer() { events+=(wait); }

# shellcheck source=../lib/test_runner.sh
source "${ROOT}/lib/test_runner.sh"

MODE_HOLD=true
chaos_run_window "smoke" apply teardown
[[ "${events[*]}" == "apply CHAOS_START" ]]

events=()
MODE_HOLD=false
chaos_run_window "smoke" apply teardown
[[ "${#events[@]}" == 6 ]]
[[ "${events[0]}" == apply ]]
[[ "${events[1]}" == CHAOS_START ]]
[[ "${events[2]}" == wait-log ]]
[[ "${events[3]}" == wait ]]
[[ "${events[4]}" == teardown ]]
[[ "${events[5]}" == "CHAOS_END  " ]]

echo "hold mode smoke: OK"
