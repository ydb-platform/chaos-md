#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/repo/cluster" "${TMP}/repo/lib" "${TMP}/bin" "${TMP}/state"
cp "${ROOT}/cluster/dynamic-nodes.sh" "${TMP}/repo/cluster/"
cp "${ROOT}/lib/config.sh" "${ROOT}/lib/grafana.sh" "${ROOT}/lib/ssh.sh" \
  "${ROOT}/lib/term.sh" "${TMP}/repo/lib/"

cat >"${TMP}/repo/env.sh" <<EOF
DYNAMIC_NODE_HOSTS=(node-1 node-2 node-3)
YDBD_DYNAMIC_SERVICE="ydbd-database.service"
YDBD_STORAGE_SERVICE="ydbd-storage.service"
DYNAMIC_NODE_WAIT_SECONDS=5
DYNAMIC_NODE_COMMAND_TIMEOUT_SECONDS=2
SSH_OPTS=()
LOG_DIR="${TMP}/logs"
GRAFANA_URL=""
EOF

cat >"${TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
host="$1"
shift
state="${FAKE_STATE}/${host}"
case "$*" in
  *"systemctl is-active"*) [[ -f "${state}" ]] || exit 3 ;;
  *"systemctl start --no-block"*) touch "${state}"; printf '%s start\n' "${host}" >>"${FAKE_LOG}" ;;
  *"systemctl stop --no-block"*) rm -f "${state}"; printf '%s stop\n' "${host}" >>"${FAKE_LOG}" ;;
  *) echo "unexpected fake ssh command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "${TMP}/bin/ssh"

export PATH="${TMP}/bin:${PATH}"
export FAKE_STATE="${TMP}/state"
export FAKE_LOG="${TMP}/ssh.log"
touch "${FAKE_STATE}/node-1" "${FAKE_STATE}/node-2"

bash "${TMP}/repo/cluster/dynamic-nodes.sh" set 3 --wait 5 >/dev/null
grep -Fxq 'node-3 start' "${FAKE_LOG}"
[[ -f "${FAKE_STATE}/node-1" && -f "${FAKE_STATE}/node-2" && -f "${FAKE_STATE}/node-3" ]]

bash "${TMP}/repo/cluster/dynamic-nodes.sh" set 1 --wait 5 >/dev/null
grep -Fxq 'node-2 stop' "${FAKE_LOG}"
grep -Fxq 'node-3 stop' "${FAKE_LOG}"
[[ -f "${FAKE_STATE}/node-1" && ! -f "${FAKE_STATE}/node-2" && ! -f "${FAKE_STATE}/node-3" ]]

# An already active target must not receive another start command.
[[ "$(grep -c 'node-1 start' "${FAKE_LOG}" || true)" == 0 ]]

echo "dynamic node control smoke: OK"
