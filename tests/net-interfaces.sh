#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/net.sh
source "${ROOT}/lib/net.sh"

fail() {
    printf 'net interfaces test failed: %s\n' "$*" >&2
    exit 1
}

resolve() {
    chaos_net_ifaces_for_host "$1"
    local iface
    for iface in "${CHAOS_NET_IFACES_ARR[@]}"; do
        printf '%s\n' "${iface}"
    done
}

NET_IFACES=()
NET_IFACES_TABLE=()
CHAOS_HOST_IFACE_TABLE=()
[[ "$(resolve db-a)" == eth0 ]] || fail 'empty declared arrays must use eth0 fallback'

unset NET_IFACES_TABLE CHAOS_HOST_IFACE_TABLE
NET_IFACES=(ens5 ens6)
[[ "$(resolve db-a)" == $'ens5\nens6' ]] || fail 'base interface array was not used'

NET_IFACES=()
NET_IFACES_TABLE=("db-a|eth1,eth2" "*|eth9")
[[ "$(resolve db-a)" == $'eth1\neth2' ]] || fail 'host table was not used'
[[ "$(resolve db-b)" == eth9 ]] || fail 'host table fallback was not used'

NET_IFACES_TABLE=()
CHAOS_HOST_IFACE_TABLE=("db-a|eno1")
[[ "$(resolve db-a)" == eno1 ]] || fail 'legacy host table was not used'

unset NET_IFACES NET_IFACES_TABLE CHAOS_HOST_IFACE_TABLE
[[ "$(resolve db-a)" == eth0 ]] || fail 'unset arrays must use eth0 fallback'

printf 'net interfaces tests: ok\n'
