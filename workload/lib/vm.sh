#!/usr/bin/env bash
# Push InfluxDB line-protocol в VictoriaMetrics. Не валит run при сетевых сбоях.

vm_post_lines() {
    # Stdin → POST /write. Если URL не задан — no-op.
    [[ -z "${WL_VM_WRITE_URL:-}" ]] && { cat >/dev/null; return 0; }
    local ck=()
    [[ "${WL_VM_INSECURE:-0}" == "1" ]] && ck=(-k)
    local err
    if ! err=$(curl -fsS "${ck[@]}" --max-time 5 \
                    -X POST "${WL_VM_WRITE_URL}" \
                    --data-binary @- 2>&1 >/dev/null); then
        log_warn "vm push failed: ${err}"
    fi
}

# Текущее время в наносекундах (для line-protocol с precision=ns).
vm_time_ns() {
    if date +%s%N 2>/dev/null | grep -q '^[0-9]\{19\}$'; then
        date +%s%N
    else
        # macOS BSD date без %N — деградируем до секундной точности.
        echo $(( $(date +%s) * 1000000000 ))
    fi
}
