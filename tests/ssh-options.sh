#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

cat > "${SANDBOX}/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CHAOS_SSH_ARGS_FILE}"
FAKE
cp "${SANDBOX}/ssh" "${SANDBOX}/scp"
chmod +x "${SANDBOX}/ssh" "${SANDBOX}/scp"

export PATH="${SANDBOX}:${PATH}"
export CHAOS_SSH_ARGS_FILE="${SANDBOX}/args"
SSH_OPTS=(-o BatchMode=yes)
source "${ROOT}/lib/ssh.sh"

assert_arg() {
    grep -Fxq -- "$1" "${CHAOS_SSH_ARGS_FILE}"
}

ssh "${SSH_OPTS[@]}" node-a true
assert_arg ConnectTimeout=8
assert_arg ConnectionAttempts=1
assert_arg ServerAliveInterval=5
assert_arg ServerAliveCountMax=2
assert_arg BatchMode=yes
assert_arg node-a

CHAOS_SSH_CONNECT_TIMEOUT=3
CHAOS_SSH_SERVER_ALIVE_INTERVAL=4
CHAOS_SSH_SERVER_ALIVE_COUNT_MAX=5
scp "${SSH_OPTS[@]}" file node-a:/tmp/file
assert_arg ConnectTimeout=3
assert_arg ServerAliveInterval=4
assert_arg ServerAliveCountMax=5
assert_arg node-a:/tmp/file

rm "${CHAOS_SSH_ARGS_FILE}"
CHAOS_DRY_RUN=true
ssh node-a true
[[ ! -e "${CHAOS_SSH_ARGS_FILE}" ]]
CHAOS_DRY_RUN=false

for invalid in 0 -1 text; do
    CHAOS_SSH_CONNECT_TIMEOUT="${invalid}"
    if ssh node-a true 2>/dev/null; then
        printf 'invalid SSH timeout was accepted: %s\n' "${invalid}" >&2
        exit 1
    fi
done

printf 'ssh transport option tests: ok\n'
