#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
BASH_BIN="${BASH:-bash}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/lib" "${SANDBOX}/nemesis"
cp "${ROOT}/04-net-delay.sh" "${SANDBOX}/"
for library in operation.sh json.sh cli.sh hosts.sh util.sh test_runner.sh; do
    cp "${ROOT}/lib/${library}" "${SANDBOX}/lib/${library}"
done
cat > "${SANDBOX}/lib/init.sh" <<'INIT'
SINGLE_HOST=default-node
DC_HOSTS=()
DC_ALT_HOSTS=()
DEFAULT_NET_DELAY=50
YDB_PORTS=2135
for library in operation json cli hosts util test_runner; do source "${SCRIPT_DIR}/lib/${library}.sh"; done
log() { :; }
log_tl() { :; }
chaos_log_script_start() { :; }
chaos_log_script_end() { local rc=$?; chaos_json_exit_trap "${rc}" || true; return "${rc}"; }
INIT
cat > "${SANDBOX}/nemesis/tc.sh" <<'NEMESIS'
nemesis_tc_check() { :; }
NEMESIS

operation=0123456789abcdef0123456789abcdef
"${BASH_BIN}" "${SANDBOX}/04-net-delay.sh" --json --check --hosts selected-a --operation "${operation}" \
    > "${SANDBOX}/explicit" 2>/dev/null
jq -se --arg operation "${operation}" \
    'length == 2 and all(.[]; .schemaVersion == 2 and .operation == $operation)' \
    "${SANDBOX}/explicit" >/dev/null

"${BASH_BIN}" "${SANDBOX}/04-net-delay.sh" --json --check --hosts selected-a \
    > "${SANDBOX}/generated" 2>/dev/null
jq -se 'length == 2 and .[0].operation == .[1].operation
    and (.[0].operation | test("^[0-9a-f]{32}$"))' "${SANDBOX}/generated" >/dev/null

if "${BASH_BIN}" "${SANDBOX}/04-net-delay.sh" --json --check --hosts selected-a \
    --operation invalid > "${SANDBOX}/invalid" 2>/dev/null; then
    echo 'invalid operation identifier was accepted' >&2
    exit 1
fi
[[ ! -s "${SANDBOX}/invalid" ]]
printf 'operation identifiers are stable and validated\n'
