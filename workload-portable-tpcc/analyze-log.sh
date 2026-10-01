#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: $0 RUN_LOG" >&2; exit 2; }

awk '
    /=== TPC-C Results ===/ { active = 1; duration = 0; tpmc = 0; failed = -1; total_ok = 0; tx_count = 0; p90 = -1; invalid = 0; next }
    !active { next }
    /INVALID RUN \(latency constraints not met\)/ { invalid = 1 }
    /Measured Duration:/ {
        value = $0; sub(/^.*Measured Duration: */, "", value); sub(/s.*/, "", value); duration = value + 0
    }
    /New-Order Throughput:/ {
        value = $0; sub(/^.*New-Order Throughput: */, "", value); sub(/ tpmC.*/, "", value); tpmc = value + 0
    }
    /Total Failed:/ {
        value = $0; sub(/^.*Total Failed: */, "", value); failed = value + 0
    }
    /(NewOrder|Delivery|OrderStatus|Payment|StockLevel): OK=/ {
        value = $0; sub(/^.*: OK=/, "", value); sub(/ .*/, "", value); total_ok += value + 0; tx_count++
        if (/NewOrder: OK=/) {
            value = $0; sub(/^.*p90=/, "", value); sub(/ms.*/, "", value); p90 = value + 0
        }
    }
    END {
        if (!active || duration <= 0 || failed < 0 || tx_count != 5 || p90 < 0) {
            print "Incomplete TPC-C results" > "/dev/stderr"; exit 1
        }
        printf "%.3f\t%.3f\t%.3f\t%d\t%d\n", total_ok / duration, tpmc / 60, p90, failed, invalid
    }
' "$1"
