#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: $0 RUN_LOG" >&2; exit 2; }

awk '
    /=== TPC-C Results ===/ {
        active = 1; duration = 0; tpmc = -1; efficiency = -1; failed = -1
        delete p90
        next
    }
    !active { next }
    /Measured Duration:/ {
        value = $0; sub(/^.*Measured Duration: */, "", value); sub(/s.*/, "", value); duration = value + 0
    }
    /New-Order Throughput:/ {
        value = $0; sub(/^.*New-Order Throughput: */, "", value); sub(/ tpmC.*/, "", value); tpmc = value + 0
    }
    /Efficiency:/ {
        value = $0; sub(/^.*Efficiency: */, "", value); sub(/%.*/, "", value); efficiency = value + 0
    }
    /Total Failed:/ {
        value = $0; sub(/^.*Total Failed: */, "", value); failed = value + 0
    }
    /: OK=.*p90=/ {
        name = $0; sub(/^.*INFO:   /, "", name); sub(/:.*/, "", name)
        value = $0; sub(/^.*p90=/, "", value); sub(/ms.*/, "", value)
        p90[name] = value + 0
    }
    END {
        count = split("NewOrder Payment OrderStatus Delivery StockLevel", names, " ")
        if (!active || duration <= 0 || tpmc < 0 || efficiency < 0 || failed < 0) {
            print "Incomplete final TPC-C results" > "/dev/stderr"; exit 2
        }
        passed = efficiency > 90
        for (i = 1; i <= count; ++i) {
            if (!(names[i] in p90)) {
                print "Missing p90 for " names[i] > "/dev/stderr"; exit 2
            }
            if (p90[names[i]] >= 5000) passed = 0
        }
        printf "result=%s duration_s=%.0f efficiency_pct=%.1f tpmc=%.2f failed=%d", \
            passed ? "PASS" : "FAIL", duration, efficiency, tpmc, failed
        for (i = 1; i <= count; ++i) printf " %s_p90_ms=%.0f", names[i], p90[names[i]]
        print ""
    }
' "$1"
