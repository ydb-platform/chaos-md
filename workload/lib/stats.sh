#!/usr/bin/env bash
# Парсер вывода `ydb workload stock run` → InfluxDB line-protocol → VictoriaMetrics.
#
# Ожидаемый формат построчного вывода (точные имена столбцов могут отличаться
# между версиями YDB CLI; парсер опирается на хедер):
#   Timestamp                 Window  Txs/Sec  Retries  Errors  p50(ms)  p95(ms)  p99(ms)  pMax(ms)
#   2026-05-07T13:30:01Z      1       120.5    2        0       5.1      8.3      12.4     15.0
#
# Если --print-timestamp не задан, столбец Timestamp отсутствует.
# Хедер определяется по подстроке "Txs/Sec" в строке (case-insensitive).
#
# Реализовано через awk → совместимо с bash 3.2 (macOS) и bash 4+ (Linux).

# Прочитать stdin (вывод workload stock), эмитить line-protocol в stdout.
# Аргументы: scenario, application_tag.
stats_stream_to_lp() {
    local scenario="${1:-unknown}"
    local app="${2:-${WL_APPLICATION:-chaos-stock}}"
    awk -v scenario="${scenario}" -v app="${app}" '
        function norm(s,    r) {
            r = tolower(s)
            gsub(/\(ms\)/, "", r)
            gsub(/[[:space:]]/, "", r)
            gsub(/\//, "_", r)
            gsub(/-/, "_", r)
            return r
        }
        function now_ns(    cmd, t) {
            cmd = "date +%s%N 2>/dev/null"
            cmd | getline t
            close(cmd)
            if (t !~ /^[0-9]{19}$/) {
                cmd = "date +%s"
                cmd | getline t
                close(cmd)
                t = t "000000000"
            }
            return t
        }
        function iso_to_ns(s,    cmd, t, base) {
            base = s
            sub(/\.[0-9]+Z$/, "Z", base)
            if (base !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return ""
            cmd = "date -u -d " base " +%s 2>/dev/null"
            cmd | getline t
            close(cmd)
            if (t == "") {
                cmd = "date -j -u -f %Y-%m-%dT%H:%M:%SZ " base " +%s 2>/dev/null"
                cmd | getline t
                close(cmd)
            }
            if (t !~ /^[0-9]+$/) return ""
            return t "000000000"
        }
        BEGIN { got_header = 0; ncols = 0 }
        {
            # Skip blanks / separators
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "") next
            if (line ~ /^[-=]+$/) next

            # Header detection
            if (tolower(line) ~ /txs\/sec/) {
                ncols = NF
                for (i = 1; i <= NF; i++) header[i] = norm($i)
                got_header = 1
                next
            }

            if (!got_header) next
            if (NF != ncols) next

            # Build row map by column index
            delete row
            for (i = 1; i <= NF; i++) row[header[i]] = $i

            ts_ns = ""
            if (("timestamp" in row) && row["timestamp"] != "") ts_ns = iso_to_ns(row["timestamp"])
            if (ts_ns == "") ts_ns = now_ns()

            rps     = ("txs_sec"  in row) ? row["txs_sec"]  : ""
            retries = ("retries"  in row) ? row["retries"]  : ""
            errors  = ("errors"   in row) ? row["errors"]   : "0"
            p50     = ("p50"      in row) ? row["p50"]      : ""
            p95     = ("p95"      in row) ? row["p95"]      : ""
            p99     = ("p99"      in row) ? row["p99"]      : ""
            pmax    = ("pmax"     in row) ? row["pmax"]     : ""

            sep = ""; fields = ""
            if (rps     != "") { fields = fields sep "rps=" rps;          sep = "," }
            if (p50     != "") { fields = fields sep "pct50=" p50;        sep = "," }
            if (p95     != "") { fields = fields sep "pct95=" p95;        sep = "," }
            if (p99     != "") { fields = fields sep "pct99=" p99;        sep = "," }
            if (pmax    != "") { fields = fields sep "pmax=" pmax;        sep = "," }
            if (retries != "") { fields = fields sep "retries=" retries "i"; sep = "," }
            if (fields != "") {
                printf "ydb_workload,application=%s,scenario=%s,statut=ok %s %s\n", app, scenario, fields, ts_ns
            }
            printf "ydb_workload,application=%s,scenario=%s,statut=ko countError=%si %s\n", app, scenario, errors, ts_ns
        }
    '
}

# Полный пайплайн: stdin (вывод воркер-процесса) → line-protocol → VM (если URL задан)
# и эхо в stdout/лог. На 1Hz статистики — ~1 curl/сек/сценарий, без батчинга.
stats_pipe_to_vm() {
    local scenario="$1"
    stats_stream_to_lp "${scenario}" | while IFS= read -r lp_line; do
        printf '%s\n' "${lp_line}"
        printf '%s\n' "${lp_line}" | vm_post_lines
    done
}
