#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/test_runner.sh"

EVENTS=()
TARGET_HOSTS=(h1 h2)
SCOPE_LABEL=explicit
TIMEOUT=1

log() { :; }
log_tl() { :; }
log_wait_sec() { :; }
chaos_json_emit() { :; }
chaos_wait_with_timer() { EVENTS+=(wait); }

apply_fail() { EVENTS+=(apply); return 1; }
apply_ok() { EVENTS+=(apply); }
teardown_ok() { EVENTS+=(teardown); }
teardown_fail() { EVENTS+=(teardown); return 1; }

if chaos_run_window test apply_fail teardown_ok; then
    echo 'Ошибка apply не была возвращена' >&2
    exit 1
fi
[[ "${EVENTS[*]}" == 'apply teardown' ]]

EVENTS=()
if chaos_run_window test apply_ok teardown_fail; then
    echo 'Ошибка teardown не была возвращена' >&2
    exit 1
fi
[[ "${EVENTS[*]}" == 'apply wait teardown' ]]

EVENTS=()
chaos_run_window test apply_ok teardown_ok
[[ "${EVENTS[*]}" == 'apply wait teardown' ]]

echo 'run window tests: ok'
