#!/usr/bin/env bash
# Преобразование scope (-1/-4/-A) в массив целевых хостов TARGET_HOSTS
# и человекочитаемый ярлык SCOPE_LABEL ("node" / "dc" / "dc_alt").
#
# Должно вызываться после chaos_parse_common.

TARGET_HOSTS=()
SCOPE_LABEL=""

chaos_resolve_targets() {
    TARGET_HOSTS=()
    # --hosts имеет приоритет над -1/-4/-A.
    if [[ -n "${EXPLICIT_HOSTS[*]:-}" ]]; then
        TARGET_HOSTS=("${EXPLICIT_HOSTS[@]}")
        SCOPE_LABEL="explicit"
        return 0
    fi
    if [[ "${SCOPE_SINGLE}" == true ]]; then
        TARGET_HOSTS=("${NODE_HOST}")
        SCOPE_LABEL="node"
    elif [[ "${SCOPE_DC}" == true ]]; then
        TARGET_HOSTS=("${DC_HOSTS[@]}")
        SCOPE_LABEL="dc"
    elif [[ "${SCOPE_DC_ALT}" == true ]]; then
        TARGET_HOSTS=("${DC_ALT_HOSTS[@]}")
        SCOPE_LABEL="dc_alt"
    fi
}

# Список хостов для отката, когда -D без явного scope (-1/-4/-A).
# Объединяем NODE_HOST (-H), SINGLE_HOST, DC_HOSTS, DC_ALT_HOSTS и CLUSTER_HOSTS (дедуп),
# чтобы снять tc/iptables‑подобное со всех нод кластера: одной только пары SINGLE+DC
# недостаточно, если хаос запускали на ноде из CLUSTER_HOSTS или с «-1 -H другой_хост».
chaos_resolve_teardown_targets() {
    if [[ -n "${EXPLICIT_HOSTS[*]:-}" || "${SCOPE_SINGLE}" == true || "${SCOPE_DC}" == true || "${SCOPE_DC_ALT}" == true ]]; then
        chaos_resolve_targets
        return 0
    fi
    TARGET_HOSTS=()
    SCOPE_LABEL="all"
    local -a _cand=()
    [[ -n "${NODE_HOST:-}" ]] && _cand+=("${NODE_HOST}")
    [[ -n "${SINGLE_HOST:-}" ]] && _cand+=("${SINGLE_HOST}")
    [[ ${#DC_HOSTS[@]} -gt 0 ]] && _cand+=("${DC_HOSTS[@]}")
    [[ ${#DC_ALT_HOSTS[@]} -gt 0 ]] && _cand+=("${DC_ALT_HOSTS[@]}")
    [[ ${#CLUSTER_HOSTS[@]} -gt 0 ]] && _cand+=("${CLUSTER_HOSTS[@]}")

    local h existing found
    for h in "${_cand[@]}"; do
        [[ -z "${h}" ]] && continue
        found=false
        for existing in "${TARGET_HOSTS[@]+"${TARGET_HOSTS[@]}"}"; do
            [[ "${existing}" == "${h}" ]] && { found=true; break; }
        done
        [[ "${found}" == false ]] && TARGET_HOSTS+=("${h}")
    done

    if [[ ${#TARGET_HOSTS[@]} -eq 0 ]]; then
        echo "chaos_resolve_teardown_targets: для -D без -1/-4/-A список хостов пуст." >&2
        echo "  Задайте CLUSTER_HOSTS (и при необходимости SINGLE_HOST/DC_HOSTS) в env.sh," >&2
        echo "  или вызывайте явный scope: ./NN-test.sh -1 -D / -4 -D / -A -D." >&2
        return 1
    fi
    return 0
}

# Краткое описание целей для chaos_term_target.
chaos_target_description() {
    case "${SCOPE_LABEL}" in
        node)   printf 'Сервер теста: %s' "${TARGET_HOSTS[0]}" ;;
        dc)     printf 'Серверы теста: ДЦ (%d хостов: %s)' "${#TARGET_HOSTS[@]}" "${TARGET_HOSTS[*]}" ;;
        dc_alt) printf 'Серверы теста: альт. ДЦ (%d хостов: %s)' "${#TARGET_HOSTS[@]}" "${TARGET_HOSTS[*]}" ;;
        all)    printf 'Снятие хаоса со всех известных хостов (%d)' "${#TARGET_HOSTS[@]}" ;;
        *)      printf 'Хосты: %s' "${TARGET_HOSTS[*]}" ;;
    esac
}
