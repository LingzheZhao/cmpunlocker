#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"
INVENTORY_FILE="${INSTALL_MOD_DIR}/gpu_inventory"

source "${SCRIPT_DIR}/common/lib.sh"

CAPACITY_TOLERANCE_MIB=512
MAX_REPORTED_MEMORY_MIB=1048576

is_canonical_memory_mib() {
    local value="$1"
    # Bash arithmetic is signed and otherwise accepts values large enough to
    # wrap.  nvidia-smi is only evidence after a bounded canonical-decimal
    # parse; one TiB is already far above either supported profile.
    [[ "${value}" =~ ^(0|[1-9][0-9]{0,6})$ ]] || return 1
    (( 10#${value} <= MAX_REPORTED_MEMORY_MIB ))
}

is_unlocked_memory() {
    local expected_mib="$1"
    local mem_mib="$2"
    is_canonical_memory_mib "${expected_mib}" &&
        is_canonical_memory_mib "${mem_mib}" || return 1
    (( 10#${mem_mib} >= 10#${expected_mib} - CAPACITY_TOLERANCE_MIB &&
       10#${mem_mib} <= 10#${expected_mib} + CAPACITY_TOLERANCE_MIB ))
}

is_stock_memory() {
    local profile="$1"
    local mem_mib="$2"
    is_canonical_memory_mib "${mem_mib}" || return 1
    case "${profile}" in
        8gb)
            (( 10#${mem_mib} >= 7680 && 10#${mem_mib} <= 8704 )) && return 0
            ;;
        10gb)
            (( 10#${mem_mib} >= 9728 && 10#${mem_mib} <= 10752 )) && return 0
            ;;
    esac
    return 1
}

expected_fb_size_for_devid() {
    case "$1" in
        20c2) echo "0x1000000000" ;;
        2082) echo "0xa00000000" ;;
        *) echo "" ;;
    esac
}

banner
step_init 4

step "Locating GPU inventory"
failures=0
indeterminate=0
SMI_SNAPSHOT_OK=0
declare -A SMI_MEM_BY_BDF=()
declare -A SMI_INDEX_BY_BDF=()
declare -A SMI_BDF_BY_INDEX=()
if command -v nvidia-smi &>/dev/null && command -v timeout &>/dev/null; then
    if SMI_SNAPSHOT="$(timeout 10s nvidia-smi \
        --query-gpu=index,pci.bus_id,memory.total \
        --format=csv,noheader,nounits 2>/dev/null)" && [[ -n "${SMI_SNAPSHOT}" ]]; then
        smi_snapshot_invalid=0
        smi_snapshot_records=0
        while IFS= read -r smi_line; do
            [[ -n "${smi_line}" ]] || { smi_snapshot_invalid=1; continue; }
            if [[ ! "${smi_line}" =~ ^([^,]*),([^,]*),([^,]*)$ ]]; then
                smi_snapshot_invalid=1
                continue
            fi
            smi_index="$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            smi_bus_raw="$(printf '%s' "${BASH_REMATCH[2]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            smi_mem="$(printf '%s' "${BASH_REMATCH[3]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            if [[ ! "${smi_index}" =~ ^(0|[1-9][0-9]{0,9})$ ]] ||
               [[ ! "${smi_bus_raw}" =~ ^[0-9A-Fa-f]{1,8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]] ||
               ! is_canonical_memory_mib "${smi_mem}"; then
                smi_snapshot_invalid=1
                continue
            fi
            smi_bus="$(normalize_bus_id "${smi_bus_raw}")"
            if [[ ! "${smi_bus}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] ||
               [[ -n "${SMI_MEM_BY_BDF[${smi_bus}]:-}" ]] ||
               [[ -n "${SMI_BDF_BY_INDEX[${smi_index}]:-}" ]]; then
                smi_snapshot_invalid=1
                continue
            fi
            SMI_MEM_BY_BDF["${smi_bus}"]="${smi_mem}"
            SMI_INDEX_BY_BDF["${smi_bus}"]="${smi_index}"
            SMI_BDF_BY_INDEX["${smi_index}"]="${smi_bus}"
            smi_snapshot_records=$((smi_snapshot_records + 1))
        done <<< "${SMI_SNAPSHOT}"
        if (( smi_snapshot_invalid == 0 && smi_snapshot_records > 0 )); then
            SMI_SNAPSHOT_OK=1
        else
            SMI_MEM_BY_BDF=()
            SMI_INDEX_BY_BDF=()
            SMI_BDF_BY_INDEX=()
            err "nvidia-smi returned malformed or duplicate GPU identity data"
            indeterminate=$((indeterminate + 1))
        fi
    fi
fi
if (( SMI_SNAPSHOT_OK == 0 )); then
    warn "One coherent nvidia-smi identity/memory snapshot is unavailable; kernel-log safety analysis will still run"
fi

smi_index_for_bus() {
    local want="$1"
    (( SMI_SNAPSHOT_OK == 1 )) || return 1
    [[ -n "${SMI_INDEX_BY_BDF[${want}]:-}" ]] || return 1
    printf '%s\n' "${SMI_INDEX_BY_BDF[${want}]}"
}

smi_memory_for_bus() {
    local want="$1"
    (( SMI_SNAPSHOT_OK == 1 )) || return 1
    [[ -n "${SMI_MEM_BY_BDF[${want}]:-}" ]] || return 1
    printf '%s\n' "${SMI_MEM_BY_BDF[${want}]}"
}

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()
GPU_EXPECTED_FB=()
GPU_LOG_LABELS=()
declare -A INVENTORY_DEVID_BY_BDF=()
declare -A LIVE_DEVID_BY_BDF=()
inventory_present=0
live_enumeration_ok=0

if [[ -s "${INVENTORY_FILE}" ]] && [[ ! -r "${INVENTORY_FILE}" ]]; then
    inventory_present=1
    err "Installed inventory is non-empty but unreadable: ${INVENTORY_FILE}"
    indeterminate=$((indeterminate + 1))
elif [[ -r "${INVENTORY_FILE}" ]] && [[ -s "${INVENTORY_FILE}" ]]; then
    inventory_present=1
    info "Using installed inventory: ${INVENTORY_FILE}"
    while read -r bdf devid profile expected extra || [[ -n "${bdf:-}" ]]; do
        [[ -n "${bdf:-}" ]] || continue
        [[ "${bdf}" =~ ^# ]] && continue
        normalized_bdf="$(normalize_bus_id "${bdf}")"
        normalized_devid="$(printf '%s' "${devid:-}" | tr '[:upper:]' '[:lower:]')"
        canonical_profile="$(profile_from_devid "${normalized_devid}")"
        canonical_expected="$(expected_mib_for_profile "${canonical_profile}")"
        if [[ ! "${normalized_bdf}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] ||
           [[ "${canonical_profile}" == "unsupported" ]] || [[ -n "${extra:-}" ]]; then
            err "Ignoring malformed gpu_inventory record: ${bdf} ${devid:-} ${profile:-} ${expected:-} ${extra:-}"
            indeterminate=$((indeterminate + 1))
            continue
        fi
        if [[ -n "${INVENTORY_DEVID_BY_BDF[${normalized_bdf}]:-}" ]]; then
            err "Duplicate gpu_inventory BDF ${normalized_bdf}; inventory is not trustworthy"
            indeterminate=$((indeterminate + 1))
            continue
        fi
        INVENTORY_DEVID_BY_BDF["${normalized_bdf}"]="${normalized_devid}"
        if [[ "${profile:-}" != "${canonical_profile}" || "${expected:-}" != "${canonical_expected}" ]]; then
            err "gpu_inventory metadata for ${normalized_bdf} does not match PCI ID ${normalized_devid}"
            indeterminate=$((indeterminate + 1))
        fi
    done < "${INVENTORY_FILE}"
else
    info "No installed gpu_inventory; live PCI enumeration will define the verification scope"
fi

# Always enumerate the live PCI topology.  A non-empty installed inventory is
# historical input, not authority for which supported cards exist right now.
if command -v lspci &>/dev/null; then
    if LSPCI_OUTPUT="$(lspci -Dnn 2>/dev/null)"; then
        live_enumeration_ok=1
        while IFS= read -r PCI_LINE; do
            PCI_LINE_LOWER="$(printf '%s' "${PCI_LINE}" | tr '[:upper:]' '[:lower:]')"
            [[ "${PCI_LINE_LOWER}" =~ \[10de:(20c2|2082)\] ]] || continue
            PCI="${PCI_LINE%%[[:space:]]*}"
            PCI_FULL="$(normalize_bus_id "${PCI}")"
            DEVID="$(printf '%s\n' "${PCI_LINE}" | grep -oEi '10de:(20c2|2082)' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
            if [[ ! "${PCI_FULL}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || [[ -z "${DEVID}" ]]; then
                err "Could not parse live supported GPU record: ${PCI_LINE}"
                indeterminate=$((indeterminate + 1))
                continue
            fi
            if [[ -n "${LIVE_DEVID_BY_BDF[${PCI_FULL}]:-}" && "${LIVE_DEVID_BY_BDF[${PCI_FULL}]}" != "${DEVID}" ]]; then
                err "Conflicting live PCI IDs reported for ${PCI_FULL}"
                indeterminate=$((indeterminate + 1))
                continue
            fi
            LIVE_DEVID_BY_BDF["${PCI_FULL}"]="${DEVID}"
        done <<< "${LSPCI_OUTPUT}"
    else
        err "lspci failed; live supported-GPU scope cannot be proven"
        indeterminate=$((indeterminate + 1))
    fi
else
    err "lspci is unavailable; live supported-GPU scope cannot be proven"
    indeterminate=$((indeterminate + 1))
fi

if (( inventory_present && live_enumeration_ok )); then
    for bdf in "${!INVENTORY_DEVID_BY_BDF[@]}"; do
        if [[ -z "${LIVE_DEVID_BY_BDF[${bdf}]:-}" ]]; then
            err "Inventory/live mismatch: ${bdf} (${INVENTORY_DEVID_BY_BDF[${bdf}]}) is absent from live PCI enumeration"
            indeterminate=$((indeterminate + 1))
        elif [[ "${LIVE_DEVID_BY_BDF[${bdf}]}" != "${INVENTORY_DEVID_BY_BDF[${bdf}]}" ]]; then
            err "Inventory/live mismatch: ${bdf} changed from ${INVENTORY_DEVID_BY_BDF[${bdf}]} to ${LIVE_DEVID_BY_BDF[${bdf}]}"
            indeterminate=$((indeterminate + 1))
        fi
    done
    for bdf in "${!LIVE_DEVID_BY_BDF[@]}"; do
        if [[ -z "${INVENTORY_DEVID_BY_BDF[${bdf}]:-}" ]]; then
            err "Inventory/live mismatch: newly detected ${bdf} (${LIVE_DEVID_BY_BDF[${bdf}]}); including it in verification"
            indeterminate=$((indeterminate + 1))
        fi
    done
fi

# Verify the union so a newly added live GPU cannot fall outside capacity/log
# checks.  Live PCI identity wins for a BDF whose stored identity is stale.
declare -A SELECTED_DEVID_BY_BDF=()
for bdf in "${!INVENTORY_DEVID_BY_BDF[@]}"; do
    SELECTED_DEVID_BY_BDF["${bdf}"]="${INVENTORY_DEVID_BY_BDF[${bdf}]}"
done
for bdf in "${!LIVE_DEVID_BY_BDF[@]}"; do
    SELECTED_DEVID_BY_BDF["${bdf}"]="${LIVE_DEVID_BY_BDF[${bdf}]}"
done
mapfile -t GPU_BDFS < <(printf '%s\n' "${!SELECTED_DEVID_BY_BDF[@]}" | sed '/^$/d' | sort)
for bdf in "${GPU_BDFS[@]}"; do
    devid="${SELECTED_DEVID_BY_BDF[${bdf}]}"
    profile="$(profile_from_devid "${devid}")"
    GPU_DEVIDS+=("${devid}")
    GPU_PROFILES+=("${profile}")
    GPU_EXPECTED+=("$(expected_mib_for_profile "${profile}")")
    GPU_EXPECTED_FB+=("$(expected_fb_size_for_devid "${devid}")")
done

if [[ ${#GPU_BDFS[@]} -eq 0 ]]; then
    err "No unlockable CMP 170HX GPU could be placed in the verification scope"
    indeterminate=$((indeterminate + 1))
fi

step "Checking memory unlock status"
printf "\n%-16s %-8s %-8s %-12s %-12s %s\n" "BDF" "PCI ID" "Variant" "Expect" "Actual" "Status"
for i in "${!GPU_BDFS[@]}"; do
    bdf="${GPU_BDFS[$i]}"
    devid="${GPU_DEVIDS[$i]}"
    profile="${GPU_PROFILES[$i]}"
    expected="${GPU_EXPECTED[$i]}"
    actual="$(smi_memory_for_bus "${bdf}" || true)"
    [[ -n "${actual}" ]] || actual="?"
    gpu_index="$(smi_index_for_bus "${bdf}" || true)"
    if [[ "${gpu_index}" =~ ^[0-9]+$ ]]; then
        GPU_LOG_LABELS+=("GPU${gpu_index}")
    else
        GPU_LOG_LABELS+=("")
    fi

    status="FAIL"
    if [[ "${actual}" == "?" ]]; then
        status="INDETERMINATE"
        err "${bdf}: memory capacity unavailable from nvidia-smi"
        indeterminate=$((indeterminate + 1))
    elif ! is_canonical_memory_mib "${actual}"; then
        status="INDETERMINATE"
        err "${bdf}: nvidia-smi returned a non-canonical or out-of-range memory value: ${actual}"
        indeterminate=$((indeterminate + 1))
    elif is_unlocked_memory "${expected}" "${actual}"; then
        status="OK"
        ok "${bdf}: ${actual} MiB (unlocked ${profile})"
    elif is_stock_memory "${profile}" "${actual}"; then
        status="STOCK"
        err "${bdf}: still stock ${actual} MiB (expect ~${expected})"
        failures=$((failures + 1))
    else
        status="UNEXPECTED"
        err "${bdf}: unexpected ${actual} MiB (expect ~${expected} for ${profile})"
        failures=$((failures + 1))
    fi

    printf "%-16s %-8s %-8s %s±%-7s %-12s %s\n" "${bdf}" "${devid}" "${profile}" "${expected}" "${CAPACITY_TOLERANCE_MIB}" "${actual}" "${status}"
done

step "Checking current-boot memory safety"
ANALYZER="${SCRIPT_DIR}/tools/analyze-kernel-log.py"
JOURNAL_LOG="$(mktemp -t cmpunlocker-verify-journal.XXXXXX)"
DMESG_LOG="$(mktemp -t cmpunlocker-verify-dmesg.XXXXXX)"
trap 'rm -f -- "${JOURNAL_LOG}" "${DMESG_LOG}"' EXIT
proof_log=""
proof_log_source=""
secondary_log=""
secondary_log_source=""

if command -v journalctl &>/dev/null &&
   journalctl -q -k -b 0 --no-pager -o cat > "${JOURNAL_LOG}" 2>/dev/null &&
   [[ -s "${JOURNAL_LOG}" ]]; then
    proof_log="${JOURNAL_LOG}"
    proof_log_source="journalctl (current boot)"
fi
if dmesg --color=never > "${DMESG_LOG}" 2>/dev/null && [[ -s "${DMESG_LOG}" ]]; then
    if [[ -z "${proof_log}" ]]; then
        proof_log="${DMESG_LOG}"
        proof_log_source="dmesg (current boot)"
    else
        secondary_log="${DMESG_LOG}"
        secondary_log_source="dmesg (independent hazard scan)"
    fi
fi

if [[ -z "${proof_log}" ]]; then
    err "Kernel log is unreadable; memory safety is indeterminate"
    info "Re-run as root, or grant access to the current boot's kernel journal"
    indeterminate=$((indeterminate + 1))
else
    info "Analyzing ${proof_log_source}; boot ID: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
    if [[ ! -x "${ANALYZER}" ]]; then
        err "Missing executable log analyzer: ${ANALYZER}"
        indeterminate=$((indeterminate + 1))
    else
        analyzer_args=()
        declare -A required_log_gpus=()
        for i in "${!GPU_BDFS[@]}"; do
            log_gpu="${GPU_LOG_LABELS[$i]}"
            if [[ -z "${log_gpu}" ]]; then
                err "Cannot map ${GPU_BDFS[$i]} to an NVIDIA GPU index; its safety anchors cannot be proven"
                indeterminate=$((indeterminate + 1))
            elif [[ -n "${required_log_gpus[${log_gpu}]:-}" ]]; then
                err "Duplicate NVIDIA log identity ${log_gpu}; per-GPU safety anchors cannot be proven"
                indeterminate=$((indeterminate + 1))
            else
                required_log_gpus["${log_gpu}"]=1
                analyzer_args+=(
                    --require-gpu-fb-size
                    "${log_gpu}=${GPU_EXPECTED_FB[$i]}"
                )
            fi
        done

        if analyzer_output="$(python3 "${ANALYZER}" "${analyzer_args[@]}" "${proof_log}" 2>&1)"; then
            analyzer_status=0
        else
            analyzer_status=$?
        fi
        printf '%s\n' "${analyzer_output}" | sed 's/^/  /'
        analyzer_declared_status="$(printf '%s\n' "${analyzer_output}" | tail -n 1)"
        analyzer_evidence_class="$(printf '%s\n' "${analyzer_output}" | tail -n 2 | head -n 1)"
        case "${analyzer_status}" in
            0) analyzer_expected_class="Evidence class: CLEAN" ;;
            1) analyzer_expected_class="Evidence class: HAZARD" ;;
            2) analyzer_expected_class="Evidence class: INCOMPLETE|Evidence class: EMPTY" ;;
            *) analyzer_expected_class="" ;;
        esac
        if [[ "${analyzer_declared_status}" != "Exit status: ${analyzer_status}" ]]; then
            err "Kernel log analyzer did not emit a matching authenticated result footer"
            analyzer_status=99
        elif [[ -z "${analyzer_expected_class}" ]] ||
             { [[ "${analyzer_status}" -eq 2 ]] &&
               [[ "${analyzer_evidence_class}" != "Evidence class: INCOMPLETE" ]] &&
               [[ "${analyzer_evidence_class}" != "Evidence class: EMPTY" ]]; } ||
             { [[ "${analyzer_status}" -ne 2 ]] &&
               [[ "${analyzer_evidence_class}" != "${analyzer_expected_class}" ]]; }; then
            err "Kernel log analyzer emitted an inconsistent evidence class"
            analyzer_status=99
        fi

        case "${analyzer_status}" in
            0)
                ok "No checked hazard; every GPU has an exact-size WPR → native-layout → PMA proof chain"
                ;;
            1)
                err "Current-boot kernel log contains unsafe PMA/WPR, guard-refusal, layout, or runtime-fault evidence"
                failures=$((failures + 1))
                ;;
            2)
                err "Kernel log lacks enough per-GPU cmpunlocker records to prove memory safety"
                indeterminate=$((indeterminate + 1))
                ;;
            *)
                err "Kernel log analyzer failed with unexpected status ${analyzer_status}"
                indeterminate=$((indeterminate + 1))
                ;;
        esac

        # Do not concatenate journal and dmesg: duplicated/out-of-order records
        # could make an older guard appear to follow a newer WPR.  Analyze them
        # independently.  A secondary source containing any layout/guard state
        # must satisfy the same strict anchors; a source without such state is
        # still scanned best-effort so a runtime fault in either source wins.
        if [[ -n "${secondary_log}" ]]; then
            secondary_args=(--best-effort)
            secondary_requires_anchors=0
            if grep -qiE 'WPR meta updated|SEC2_DEBUG_FB_LAYOUT:|SEC2_DEBUG_PMA_GUARD:|SEC2_DEBUG_LATE_PMA' "${secondary_log}"; then
                secondary_args=("${analyzer_args[@]}")
                secondary_requires_anchors=1
            fi
            if secondary_output="$(python3 "${ANALYZER}" "${secondary_args[@]}" "${secondary_log}" 2>&1)"; then
                secondary_status=0
            else
                secondary_status=$?
            fi
            secondary_declared_status="$(printf '%s\n' "${secondary_output}" | tail -n 1)"
            if [[ "${secondary_declared_status}" != "Exit status: ${secondary_status}" ]]; then
                secondary_status=99
            fi
            if [[ "${secondary_status}" -eq 1 ]]; then
                err "${secondary_log_source} contains independent hazard evidence"
                printf '%s\n' "${secondary_output}" | sed 's/^/  /'
                failures=$((failures + 1))
            elif [[ "${secondary_status}" -eq 2 ]]; then
                secondary_evidence_class="$(printf '%s\n' "${secondary_output}" | tail -n 2 | head -n 1)"
                if [[ "${secondary_requires_anchors}" -eq 0 && \
                      "${secondary_evidence_class}" == "Evidence class: EMPTY" ]]; then
                    :
                else
                    err "${secondary_log_source} was not completely analyzable"
                    printf '%s\n' "${secondary_output}" | sed 's/^/  /'
                    indeterminate=$((indeterminate + 1))
                fi
            elif [[ "${secondary_status}" -ne 0 && "${secondary_status}" -ne 2 ]]; then
                err "Secondary kernel-log hazard scan failed with unexpected status ${secondary_status}"
                indeterminate=$((indeterminate + 1))
            fi
        fi
    fi

    sec2_logs="$(grep 'SEC2_DEBUG' "${proof_log}" || true)"
    if [[ -n "${sec2_logs}" ]]; then
        info "Latest safety/layout records:"
        printf '%s\n' "${sec2_logs}" |
            grep -E 'WPR meta updated|FB_LAYOUT|PMA_GUARD|SEC2_DEBUG_HEAP' |
            tail -n 12 |
            sed 's/^/  /' || true
    fi
fi

echo ""
if [[ -r "${INSTALL_MOD_DIR}/card_profile" ]]; then
    info "Installed profile: $(cat "${INSTALL_MOD_DIR}/card_profile") / geometry: $(cat "${INSTALL_MOD_DIR}/unlock_geometry" 2>/dev/null || echo '?')"
fi

step "Checking negotiated PCIe generation"
if [[ -x "${SCRIPT_DIR}/tools/service.sh" ]]; then
    if [[ "${EUID}" -eq 0 ]]; then
        if service_output="$("${SCRIPT_DIR}/tools/service.sh" verify 2>&1)"; then
            service_status=0
        else
            service_status=$?
        fi
        printf '%s\n' "${service_output}"
        service_declared_status="$(printf '%s\n' "${service_output}" | tail -n 1)"
        case "${service_status}" in
            0)
                if [[ "${service_declared_status}" != "PCIe verification result: OK" ]]; then
                    err "PCIe helper returned success without an exact OK result footer"
                    indeterminate=$((indeterminate + 1))
                fi
                ;;
            1)
                if [[ "${service_declared_status}" == "PCIe verification result: GEN1" ]]; then
                    err "PCIe Gen2 is not active"
                    failures=$((failures + 1))
                else
                    err "PCIe helper failed without definite Gen1 evidence"
                    indeterminate=$((indeterminate + 1))
                fi
                ;;
            2)
                err "PCIe generation could not be verified"
                indeterminate=$((indeterminate + 1))
                ;;
            *)
                err "PCIe helper failed with unexpected status ${service_status}"
                indeterminate=$((indeterminate + 1))
                ;;
        esac
    else
        warn "Skipping setpci-based link verification without root privileges"
        indeterminate=$((indeterminate + 1))
    fi
else
    err "PCIe verification helper is missing or not executable: ${SCRIPT_DIR}/tools/service.sh"
    indeterminate=$((indeterminate + 1))
fi

echo ""
if (( failures > 0 )); then
    die "Verification failed with ${failures} definite safety/status error(s). Do not run GPU workloads; install the fixed modules and cold power-cycle."
fi
if (( indeterminate > 0 )); then
    err "Verification is indeterminate (${indeterminate} incomplete check(s)); no healthy verdict was issued"
    exit 2
fi

ok "All ${#GPU_BDFS[@]} unlockable GPU(s) passed capacity, PMA/WPR safety, runtime-log, and PCIe checks"
exit 0
