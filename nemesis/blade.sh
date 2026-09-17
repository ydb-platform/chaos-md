#!/usr/bin/env bash
# Немезис: ChaosBlade. Один инструмент — много экспериментов.
# Конкретные blade-команды (cpu/mem/...) формируются в самих тестах.
#
# UID эксперимента сохраняется в logs/<TEST_NAME>.<host>.<suffix> (см. util.sh::state_file).
# suffix позволяет хранить несколько UID на одном хосте (например, ram + cache).
#
# Базовый API:
#   nemesis_blade_run         <host> <suffix> <blade_args...>
#   nemesis_blade_destroy     <host> <suffix>
#   nemesis_blade_destroy_all <suffix>

_blade_extract_uid() {
    sed -n 's/.*"result":"\([^"]*\)".*/\1/p'
}

# Шаблоны CLI ChaosBlade сильно зависят от сборки; при «unknown flag» задайте в env свои строки.
# Плейсхолдеры: @CPU_PERCENT@ @MEM_PERCENT@ @MEM_RATE@ @TIMEOUT@
nemesis_blade_template_expand() {
    local tpl="$1"
    tpl="${tpl//@CPU_PERCENT@/${CPU_PERCENT:-}}"
    tpl="${tpl//@MEM_PERCENT@/${MEM_PERCENT:-}}"
    tpl="${tpl//@MEM_RATE@/${MEM_RATE:-}}"
    tpl="${tpl//@TIMEOUT@/${BLADE_TIMEOUT:-}}"
    printf '%s' "${tpl}"
}

nemesis_blade_cmd_cpu_load() {
    if [[ -n "${CHAOS_BLADE_CPU_LOAD_TEMPLATE:-}" ]]; then
        nemesis_blade_template_expand "${CHAOS_BLADE_CPU_LOAD_TEMPLATE}"
        return
    fi
    printf 'create cpu load --cpu-percent %s --timeout %s' "${CPU_PERCENT}" "${BLADE_TIMEOUT}"
}

nemesis_blade_cmd_mem_ram() {
    if [[ -n "${CHAOS_BLADE_MEM_RAM_TEMPLATE:-}" ]]; then
        nemesis_blade_template_expand "${CHAOS_BLADE_MEM_RAM_TEMPLATE}"
        return
    fi
    printf 'create mem load --mode ram --mem-percent %s --rate %s --avoid-being-killed --include-buffer-cache --timeout %s' \
        "${MEM_PERCENT}" "${MEM_RATE}" "${BLADE_TIMEOUT}"
}

nemesis_blade_cmd_mem_cache() {
    if [[ -n "${CHAOS_BLADE_MEM_CACHE_TEMPLATE:-}" ]]; then
        nemesis_blade_template_expand "${CHAOS_BLADE_MEM_CACHE_TEMPLATE}"
        return
    fi
    printf 'create mem load --mode cache --mem-percent %s --avoid-being-killed --timeout %s' \
        "${MEM_PERCENT}" "${BLADE_TIMEOUT}"
}

# Запустить blade-эксперимент на хосте, сохранить UID.
nemesis_blade_run() {
    local host="$1" suffix="$2"; shift 2
    local args="$*"

    log_chaos_apply "blade ${host} [${suffix}]: ${args}"
    chaos_term_remote_cmd "ssh ${host}  ${BLADE_REMOTE} ${args}"

    local _bk _kl
    _bk="${BLADE_REMOTE} ${args}"
    _kl=$(chaos_remote_line_kind "${_bk}")
    case "${_kl}" in on | off) chaos_log_remote_line "${_kl}" "${_bk}" ;; *) log "  ${_bk}" ;; esac

    local out
    out=$(ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "${host}" "${BLADE_REMOTE} ${args}")
    log "blade ${host} [${suffix}]: ${out}"

    local uid; uid=$(echo "${out}" | _blade_extract_uid)
    if [[ -n "${uid}" ]]; then
        echo "${uid}" > "$(state_file "${host}" "${suffix}")"
        log "  UID: ${uid}"
    else
        log "  ПРЕДУПРЕЖДЕНИЕ: UID не извлечён"
    fi
}

# Отменить эксперимент по сохранённому UID.
nemesis_blade_destroy() {
    local host="$1" suffix="${2:-uid}"
    local sf; sf="$(state_file "${host}" "${suffix}")"
    if [[ ! -f "${sf}" ]]; then
        log "blade ${host}/${suffix}: нет сохранённого UID"
        return 0
    fi
    local uid; uid=$(cat "${sf}")
    chaos_term_remote_cmd "ssh ${host}  ${BLADE_REMOTE} destroy ${uid}"

    local _bk _kl
    _bk="${BLADE_REMOTE} destroy ${uid}"
    _kl=$(chaos_remote_line_kind "${_bk}")
    case "${_kl}" in on | off) chaos_log_remote_line "${_kl}" "${_bk}" ;; *) log "  ${_bk}" ;; esac

    local out
    if ! out=$(ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "${host}" "${BLADE_REMOTE} destroy ${uid}" 2>&1); then
        log "blade destroy failed ${host}: ${out}"
        return 1
    fi
    log "blade destroy ${host}: ${out}"
    if [[ "${out}" != *'"success":true'* && "${out}" != *'"success": true'* ]]; then
        log "blade destroy ${host}: success not confirmed; UID retained"
        return 1
    fi
    rm -f "${sf}"
}

# Показать статус blade-экспериментов по сохранённым UID.
nemesis_blade_check() {
    local host="${1:-${SINGLE_HOST}}"
    echo "=== blade на ${host} (${TEST_NAME}) ==="
    local files=("${LOG_DIR}/${TEST_NAME}.${host}".*)
    if [[ ! -f "${files[0]:-}" ]]; then
        echo "  нет сохранённых UID"
        return 0
    fi
    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || continue
        local suffix="${f##*.}" uid; uid=$(cat "${f}")
        echo "  [${suffix}] uid=${uid}"
        chaos_term_remote_cmd "ssh ${host}  blade status ${uid}"
        ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "${host}" "${BLADE_REMOTE} status ${uid}" 2>&1 | head -3 || true
    done
}

# Параллельно отменить все сохранённые UID текущего теста с заданным суффиксом.
nemesis_blade_destroy_all() {
    local suffix="${1:-uid}"
    [[ $# -gt 0 ]] && shift
    local allowed=() candidate include
    allowed=("$@")
    local files=("${LOG_DIR}/${TEST_NAME}".*."${suffix}")
    if [[ ! -f "${files[0]:-}" ]]; then
        log "Нет сохранённых UID (${TEST_NAME}, ${suffix})"
        return 0
    fi
    log "Отмена ${#files[@]} blade-экспериментов (${suffix})"
    local pids=() base host f
    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || continue
        base="${f##*/}"; base="${base#"${TEST_NAME}."}"
        host="${base%."${suffix}"}"
        if [[ -n "${allowed[*]:-}" ]]; then
            include=false
            for candidate in "${allowed[@]}"; do
                [[ "${host}" == "${candidate}" ]] && include=true
            done
            [[ "${include}" == true ]] || continue
        fi
        nemesis_blade_destroy "${host}" "${suffix}" &
        pids+=($!)
    done
    local pid rc=0
    for pid in "${pids[@]+"${pids[@]}"}"; do wait "${pid}" || rc=1; done
    return "${rc}"
}
