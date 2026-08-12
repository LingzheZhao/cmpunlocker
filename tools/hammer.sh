#!/bin/bash
set -uo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly VENDOR_ID="10de"
readonly LOG_FILE="/var/log/cmpunlocker-gen2.log"
readonly TARGET_GEN="${CMP170HX_GEN2_TARGET:-2}"
readonly MAX_ITERATIONS="${CMP170HX_GEN2_MAX_ITERATIONS:-600}"
readonly RETRAIN_INTERVAL="${CMP170HX_GEN2_RETRAIN_INTERVAL:-0.05}"
readonly MAX_SECONDS="${CMP170HX_GEN2_MAX_SECONDS:-40}"

log() {
    local line
    line="[$(date -Is)] $*"
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true
}

read_link_status() {
    setpci -s "$1" CAP_EXP+12.w 2>/dev/null || true
}

link_generation() {
    local status
    status="$(read_link_status "$1")"
    if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
        echo $((0x${status} & 0x0f))
    else
        echo "?"
    fi
}

is_supported_gpu() {
    local bdf="$1"
    local vendor device
    [[ -r "/sys/bus/pci/devices/${bdf}/vendor" ]] || return 1
    [[ -r "/sys/bus/pci/devices/${bdf}/device" ]] || return 1
    vendor="$(<"/sys/bus/pci/devices/${bdf}/vendor")"
    device="$(<"/sys/bus/pci/devices/${bdf}/device")"
    [[ "${vendor,,}" == "0x${VENDOR_ID}" ]] || return 1
    [[ "${device,,}" == "0x20c2" || "${device,,}" == "0x2082" ]]
}

upstream_bridge() {
    local bdf="$1"
    local parent
    parent="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${bdf}")")")"
    [[ "${parent}" != "${bdf}" ]] || return 1
    [[ -e "/sys/bus/pci/devices/${parent}" ]] || return 1
    echo "${parent}"
}

is_pci_bridge() {
    local bdf="$1"
    local class
    [[ -r "/sys/bus/pci/devices/${bdf}/class" ]] || return 1
    class="$(<"/sys/bus/pci/devices/${bdf}/class")"
    [[ "${class,,}" == 0x0604* ]]
}

retrain_all() {
    local -a gpus=("$@")
    local -a bridges=()
    local -a completed=()
    local gpu bridge initial status generation cap2
    local i round remaining deadline rc=0

    for i in "${!gpus[@]}"; do
        gpu="${gpus[$i]}"
        if ! is_supported_gpu "${gpu}"; then
            log "${gpu}: vendor/device guard failed; refusing to touch the device"
            completed[$i]=1
            bridges[$i]=""
            rc=1
            continue
        fi
        bridge="$(upstream_bridge "${gpu}" || true)"
        if [[ -z "${bridge}" ]] || ! is_pci_bridge "${bridge}"; then
            log "${gpu}: no valid upstream PCI bridge found; skipping"
            completed[$i]=1
            bridges[$i]=""
            rc=1
            continue
        fi
        bridges[$i]="${bridge}"
        initial="$(link_generation "${gpu}")"
        if [[ "${initial}" =~ ^[0-9]+$ ]] && (( initial >= TARGET_GEN )); then
            log "${gpu}: already Gen${initial}; no retrain needed"
            completed[$i]=1
        else
            completed[$i]=0
            log "${gpu}: queued via upstream ${bridge}; initial Gen${initial}; target Gen${TARGET_GEN}"
            setpci -s "${bridge}" CAP_EXP+30.w=0002:000f 2>/dev/null || true
            setpci -s "${gpu}" CAP_EXP+30.w=0002:000f 2>/dev/null || true
        fi
    done

    deadline=$((SECONDS + MAX_SECONDS))
    for ((round = 1; round <= MAX_ITERATIONS && SECONDS < deadline; round++)); do
        remaining=0
        for i in "${!gpus[@]}"; do
            (( completed[$i] == 0 )) || continue
            gpu="${gpus[$i]}"
            bridge="${bridges[$i]}"
            if ! is_supported_gpu "${gpu}" || ! is_pci_bridge "${bridge}"; then
                log "${gpu}: device or upstream bridge disappeared; stopping attempts"
                completed[$i]=1
                rc=1
                continue
            fi

            setpci -s "${bridge}" CAP_EXP+10.w=0020:0020 2>/dev/null || true
            status="$(read_link_status "${gpu}")"
            if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
                generation=$((0x${status} & 0x0f))
                if (( generation >= TARGET_GEN )); then
                    cap2="$(setpci -s "${gpu}" CAP_EXP+2c.l 2>/dev/null || echo unreadable)"
                    log "${gpu}: SUCCESS Gen${generation} at round ${round}; LnkSta=0x${status}; LnkCap2=0x${cap2}"
                    completed[$i]=1
                    continue
                fi
            fi
            remaining=$((remaining + 1))
        done
        (( remaining > 0 )) || break
        sleep "${RETRAIN_INTERVAL}"
    done

    for i in "${!gpus[@]}"; do
        (( completed[$i] == 0 )) || continue
        generation="$(link_generation "${gpus[$i]}")"
        log "${gpus[$i]}: no Gen2 window caught within ${MAX_SECONDS}s/${MAX_ITERATIONS} rounds; final Gen${generation}"
        rc=1
    done
    return "${rc}"
}

main() {
    local resolved
    local -a gpus=()

    if [[ "${EUID}" -ne 0 ]]; then
        echo "cmpunlocker-gen2-hammer must run as root" >&2
        exit 1
    fi
    if [[ "${TARGET_GEN}" != "2" ]]; then
        echo "Only Gen2 is supported by this safety-constrained helper" >&2
        exit 1
    fi
    if ! [[ "${MAX_ITERATIONS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "CMP170HX_GEN2_MAX_ITERATIONS must be a positive integer" >&2
        exit 1
    fi
    if ! [[ "${MAX_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "CMP170HX_GEN2_MAX_SECONDS must be a positive integer" >&2
        exit 1
    fi
    if ! [[ "${RETRAIN_INTERVAL}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "CMP170HX_GEN2_RETRAIN_INTERVAL must be a non-negative number" >&2
        exit 1
    fi
    command -v lspci >/dev/null || { echo "lspci is required" >&2; exit 1; }
    command -v setpci >/dev/null || { echo "setpci is required" >&2; exit 1; }
    command -v modinfo >/dev/null || { echo "modinfo is required" >&2; exit 1; }

    resolved="$(modinfo -k "$(uname -r)" -n nvidia 2>/dev/null || true)"
    resolved="$(readlink -e -- "${resolved}" 2>/dev/null || true)"
    if [[ "${resolved}" != */updates/cmpunlocker/nvidia.ko ]] || \
       ! grep -aEq 'cmpunlocker-safety-v5-2082-(40g|80g-experimental)' "${resolved}"; then
        echo "Refusing PCIe retrain: current kernel does not resolve a v5 cmpunlocker nvidia.ko" >&2
        exit 1
    fi

    : > "${LOG_FILE}"
    log "early retrain started (global budget=${MAX_SECONDS}s, rounds=${MAX_ITERATIONS}, interval=${RETRAIN_INTERVAL}s)"

    mapfile -t gpus < <(
        for id in 20c2 2082; do
            lspci -D -d "${VENDOR_ID}:${id}" 2>/dev/null | awk '{print $1}'
        done
    )
    if [[ ${#gpus[@]} -eq 0 ]]; then
        log "no supported CMP 170HX found; nothing touched"
        return 0
    fi

    if retrain_all "${gpus[@]}"; then
        log "early retrain finished (rc=0)"
        return 0
    fi
    log "early retrain finished (rc=1)"
    return 1
}

main "$@"
