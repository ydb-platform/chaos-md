#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${dir}/config.sh"

mkdir -p "$TPCC_OUT_DIR"

if [[ ! -d "${TPCC_SOURCE_DIR}/.git" ]]; then
    git clone "${TPCC_SOURCE_URL}" "${TPCC_SOURCE_DIR}"
fi
git -C "${TPCC_SOURCE_DIR}" fetch origin "${TPCC_SOURCE_COMMIT}"
git -C "${TPCC_SOURCE_DIR}" checkout --detach "${TPCC_SOURCE_COMMIT}"
[[ "$(git -C "${TPCC_SOURCE_DIR}" rev-parse HEAD)" == "${TPCC_SOURCE_COMMIT}" ]]
patch="${dir}/patches/standalone-drain.patch"
if git -C "${TPCC_SOURCE_DIR}" apply --reverse --check "$patch" 2>/dev/null; then
    :
else
    git -C "${TPCC_SOURCE_DIR}" apply "$patch"
fi

cd "${TPCC_SOURCE_DIR}"
./ya make -r -DHAVE_CUDA=no -DCUDA_VERSION=11.4 tpcc/app/ydb
test -x "${TPCC_BIN}"
"${TPCC_BIN}" --help | head -5
