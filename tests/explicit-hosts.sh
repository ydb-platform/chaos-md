#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${ROOT}/lib/operation.sh"
source "${ROOT}/lib/json.sh"
source "${ROOT}/lib/cli.sh"
source "${ROOT}/lib/hosts.sh"
SINGLE_HOST=node-a
NODE_HOST=node-a
DC_HOSTS=(node-a node-b)
DC_ALT_HOSTS=(node-c)
CLUSTER_HOSTS=(node-a node-b node-c protected)
chaos_parse_common --single --host node-a
chaos_require_scope
chaos_resolve_targets
[[ "${TARGET_HOSTS[*]}" == node-a ]]
SCOPE_SINGLE=false
chaos_parse_common --hosts node-b,node-c --teardown
chaos_resolve_teardown_targets
[[ "${TARGET_HOSTS[*]}" == 'node-b node-c' ]]
EXPLICIT_HOSTS=()
SCOPE_DC=true
chaos_resolve_targets
[[ "${TARGET_HOSTS[*]}" == 'node-a node-b' ]]
SCOPE_DC=false
chaos_resolve_teardown_targets
[[ "${TARGET_HOSTS[*]}" == 'node-a node-b node-c protected' ]]
printf 'host selection passed\n'
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT
TEST_NAME=explicit-hosts
BLADE_REMOTE=blade
SSH_OPTS=()
source "${ROOT}/nemesis/blade.sh"
state_file() { printf '%s/%s.%s.%s' "${LOG_DIR}" "${TEST_NAME}" "$1" "$2"; }
log() { :; }
chaos_term_remote_cmd() { :; }
chaos_remote_line_kind() { printf off; }
chaos_log_remote_line() { :; }
printf uid-a > "${LOG_DIR}/explicit-hosts.node-a.uid"
printf uid-b > "${LOG_DIR}/explicit-hosts.node-b.uid"
ssh() { printf '{"success":true,"result":true}'; }
nemesis_blade_destroy_all uid node-a
[[ ! -f "${LOG_DIR}/explicit-hosts.node-a.uid" && -f "${LOG_DIR}/explicit-hosts.node-b.uid" ]]
ssh() { return 255; }
if nemesis_blade_destroy_all uid node-b; then exit 1; fi
[[ -f "${LOG_DIR}/explicit-hosts.node-b.uid" ]]
ssh() { printf '{"success":false,"error":"unreachable"}'; }
if nemesis_blade_destroy_all uid node-b; then exit 1; fi
[[ -f "${LOG_DIR}/explicit-hosts.node-b.uid" ]]
ssh() { printf '{"success":true}'; }
nemesis_blade_destroy_all uid node-b
[[ ! -f "${LOG_DIR}/explicit-hosts.node-b.uid" ]]
printf 'scoped cleanup and retry passed\n'
