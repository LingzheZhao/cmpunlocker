#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"
INVENTORY_FILE="${INSTALL_MOD_DIR}/gpu_inventory"

source "${SCRIPT_DIR}/common/lib.sh"

is_unlocked_memory() {
    local profile="$1"
    local mem_mib="$2"
    [[ "${mem_mib}" =~ ^[0-9]+$ ]] || return 1
    case "${profile}" in
        8gb)
            (( mem_mib >= 60000 )) && return 0
            ;;
        10gb)
            (( mem_mib >= 35000 && mem_mib < 60000 )) && return 0
            ;;
    esac
    return 1
}

is_stock_memory() {
    local profile="$1"
    local mem_mib="$2"
    [[ "${mem_mib}" =~ ^[0-9]+$ ]] || return 1
    case "${profile}" in
        8gb)
            (( mem_mib >= 7680 && mem_mib <= 8704 )) && return 0
            ;;
        10gb)
            (( mem_mib >= 9728 && mem_mib <= 10752 )) && return 0
            ;;
    esac
    return 1
}

smi_index_for_bus() {
    local want="$1"
    local line index bus

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        index="$(echo "${line}" | cut -d, -f1 | tr -d '[:space:]')"
        bus="$(normalize_bus_id "$(echo "${line}" | cut -d, -f2)")"
        if [[ "${index}" =~ ^[0-9]+$ && "${bus}" == "${want}" ]]; then
            echo "${index}"
            return 0
        fi
    done <<< "${SMI_INDEX_CACHE:-}"
    return 1
}

runtime_hazards_for_gpu() {
    local bdf="$1"
    local gpu_index="$2"
    local log_text="$3"
    local xid_bdf="${bdf%.*}"

    {
        # Xid messages use the PCI address without the function suffix. Match
        # the complete prefix so a Booter status such as 0x31 cannot be
        # mistaken for Xid 31.
        printf '%s\n' "${log_text}" | \
            grep -F "NVRM: Xid (PCI:${xid_bdf}):" || true

        # Fault and scrub diagnostics use the NVIDIA GPU index, so only this
        # GPU is matched. A region violation is unsafe for any access type.
        printf '%s\n' "${log_text}" | \
            grep -F "NVRM: GPU${gpu_index} " | \
            grep -E 'FAULT_INFO_TYPE_REGION_VIOLATION|_scrubWaitAndSave: Timed out when waiting for scrub jobs to finish\.' || true
    } | awk '!seen[$0]++'
}

banner
step_init 3

step "Locating GPU inventory"
command -v nvidia-smi &>/dev/null || die "nvidia-smi not found"
SMI_MEM_CACHE="$(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
[[ -n "${SMI_MEM_CACHE}" ]] || die "nvidia-smi returned no GPU memory data"
SMI_INDEX_CACHE="$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits 2>/dev/null || true)"
[[ -n "${SMI_INDEX_CACHE}" ]] || die "nvidia-smi returned no GPU index data"

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()

if [[ -r "${INVENTORY_FILE}" ]] && [[ -s "${INVENTORY_FILE}" ]]; then
    info "Using inventory: ${INVENTORY_FILE}"
    while read -r bdf devid profile expected || [[ -n "${bdf:-}" ]]; do
        [[ -n "${bdf:-}" ]] || continue
        [[ "${bdf}" =~ ^# ]] && continue
        GPU_BDFS+=("$(normalize_bus_id "${bdf}")")
        GPU_DEVIDS+=("${devid}")
        GPU_PROFILES+=("${profile}")
        GPU_EXPECTED+=("${expected}")
    done < "${INVENTORY_FILE}"
else
    info "No installed gpu_inventory; enumerating via lspci"
    mapfile -t PCI_LINES < <(lspci -nn 2>/dev/null | grep -iE '10de:20c2|10de:2082' || true)
    [[ ${#PCI_LINES[@]} -gt 0 ]] || die "No unlockable CMP 170HX GPU found (10de:20c2 / 10de:2082)"
    for PCI_LINE in "${PCI_LINES[@]}"; do
        PCI="$(echo "${PCI_LINE}" | awk '{print $1}')"
        PCI_FULL="$(normalize_bus_id "${PCI}")"
        DEVID="$(echo "${PCI_LINE}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
        PROF="$(profile_from_devid "${DEVID}")"
        [[ "${PROF}" != "unsupported" ]] || continue
        EXP="$(expected_mib_for_profile "${PROF}")"
        GPU_BDFS+=("${PCI_FULL}")
        GPU_DEVIDS+=("${DEVID}")
        GPU_PROFILES+=("${PROF}")
        GPU_EXPECTED+=("${EXP}")
    done
fi

[[ ${#GPU_BDFS[@]} -gt 0 ]] || die "No unlockable GPUs to verify"

step "Checking memory unlock status"
failures=0
printf "\n%-16s %-8s %-8s %-12s %-12s %s\n" "BDF" "PCI ID" "Variant" "Expect" "Actual" "Status"
for i in "${!GPU_BDFS[@]}"; do
    bdf="${GPU_BDFS[$i]}"
    devid="${GPU_DEVIDS[$i]}"
    profile="${GPU_PROFILES[$i]}"
    expected="${GPU_EXPECTED[$i]}"
    actual="$(smi_memory_for_bus "${bdf}" || true)"
    [[ -n "${actual}" ]] || actual="?"

    status="FAIL"
    if is_unlocked_memory "${profile}" "${actual}"; then
        status="OK"
        ok "${bdf}: ${actual} MiB (unlocked ${profile})"
    elif is_stock_memory "${profile}" "${actual}"; then
        status="STOCK"
        err "${bdf}: still stock ${actual} MiB (expect ~${expected})"
        failures=$((failures + 1))
    elif [[ "${actual}" == "?" ]]; then
        status="MISSING"
        err "${bdf}: not found in nvidia-smi"
        failures=$((failures + 1))
    else
        status="UNEXPECTED"
        err "${bdf}: unexpected ${actual} MiB (expect ~${expected} for ${profile})"
        failures=$((failures + 1))
    fi

    printf "%-16s %-8s %-8s ~%-11s %-12s %s\n" "${bdf}" "${devid}" "${profile}" "${expected}" "${actual}" "${status}"
done

step "Checking unlock logs and installed profile"
kernel_log="$(dmesg 2>/dev/null || true)"
if [[ -z "${kernel_log}" ]]; then
    err "Cannot read the current boot kernel log; memory safety cannot be proven"
    failures=$((failures + 1))
else
    for i in "${!GPU_BDFS[@]}"; do
        bdf="${GPU_BDFS[$i]}"
        gpu_index="$(smi_index_for_bus "${bdf}" || true)"
        if [[ -z "${gpu_index}" ]]; then
            err "${bdf}: cannot map PCI device to an NVIDIA GPU index"
            failures=$((failures + 1))
            continue
        fi

        gpu_logs="$(printf '%s\n' "${kernel_log}" | grep -F "NVRM: GPU${gpu_index} " || true)"
        layout_logs="$(printf '%s\n' "${gpu_logs}" | grep -F 'SEC2_DEBUG_FB_LAYOUT:' || true)"
        pma_logs="$(printf '%s\n' "${gpu_logs}" | grep -F 'SEC2_DEBUG_PMA_GUARD:' || true)"
        safe_layout_logs="$(printf '%s\n' "${layout_logs}" | \
            grep -F 'SEC2_DEBUG_FB_LAYOUT: validated' | \
            grep -F 'status=safe build=cmpunlocker-safety-v4' || true)"
        unsafe_pma_logs="$(grep -Fv 'status=safe build=cmpunlocker-safety-v4' \
            <<< "${pma_logs}" || true)"

        if [[ -z "${safe_layout_logs}" ]]; then
            err "${bdf}: missing the required safe native framebuffer-layout proof"
            failures=$((failures + 1))
        elif grep -Fq 'SEC2_DEBUG_FB_LAYOUT: rejected' <<< "${layout_logs}"; then
            err "${bdf}: the current boot contains a rejected framebuffer layout"
            failures=$((failures + 1))
        else
            ok "${bdf}: native framebuffer layout is safe"
        fi

        if ! grep -Fq 'status=safe build=cmpunlocker-safety-v4' <<< "${pma_logs}"; then
            err "${bdf}: missing the required safe physical-memory-allocator proof"
            failures=$((failures + 1))
        elif [[ -n "${unsafe_pma_logs}" ]]; then
            err "${bdf}: the current boot contains an unsafe allocator diagnostic"
            failures=$((failures + 1))
        else
            ok "${bdf}: physical memory allocator matches the validated public range"
        fi

        runtime_hazards="$(runtime_hazards_for_gpu \
            "${bdf}" "${gpu_index}" "${kernel_log}")"
        if [[ -n "${runtime_hazards}" ]]; then
            err "${bdf}: the current boot contains an NVIDIA Xid, framebuffer region violation, or scrub timeout"
            while IFS= read -r hazard; do
                [[ -n "${hazard}" ]] && warn "${hazard}"
            done <<< "${runtime_hazards}"
            failures=$((failures + 1))
        else
            ok "${bdf}: no matching runtime memory fault in the current boot"
        fi
    done
fi

echo ""
if [[ -r "${INSTALL_MOD_DIR}/card_profile" ]]; then
    info "Installed profile: $(cat "${INSTALL_MOD_DIR}/card_profile") / geometry: $(cat "${INSTALL_MOD_DIR}/unlock_geometry" 2>/dev/null || echo '?')"
fi

if (( failures > 0 )); then
    echo ""
    die "${failures} unlock or memory-safety verification check(s) failed"
fi

echo ""
ok "All ${#GPU_BDFS[@]} unlockable GPU(s) report unlocked memory with safe allocator proofs"

if [[ -x "${SCRIPT_DIR}/tools/service.sh" ]]; then
    echo ""
    info "Checking negotiated PCIe generation"
    if ! "${SCRIPT_DIR}/tools/service.sh" verify; then
        warn "Memory unlock is healthy, but PCIe Gen2 is not active"
        exit 1
    fi
fi
exit 0
