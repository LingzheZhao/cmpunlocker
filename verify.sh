#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"
INVENTORY_FILE="${INSTALL_MOD_DIR}/gpu_inventory"
TEN_GB_TARGET_FILE="${INSTALL_MOD_DIR}/ten_gb_target"
MANIFEST_FILE="${INSTALL_MOD_DIR}/modules.sha256"

source "${SCRIPT_DIR}/common/lib.sh"

MODULE_NAMES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm nvidia_peermem)
MODULE_FILES=(nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko)
METADATA_FILES=(driver_version card_profile ten_gb_target unlock_geometry build_fingerprint gpu_inventory)
MANIFEST_MEMBERS=("${MODULE_FILES[@]}" "${METADATA_FILES[@]}")

is_unlocked_memory() {
    local profile="$1"
    local expected_mib="$2"
    local mem_mib="$3"
    [[ "${mem_mib}" =~ ^[0-9]+$ ]] || return 1
    case "${profile}:${expected_mib}" in
        8gb:65536)
            (( mem_mib >= 60000 && mem_mib < 75000 )) && return 0
            ;;
        10gb:40960)
            (( mem_mib >= 35000 && mem_mib < 60000 )) && return 0
            ;;
        10gb:81920)
            (( mem_mib >= 75000 && mem_mib < 90000 )) && return 0
            ;;
    esac
    return 1
}

expected_fb_hex_for_mib() {
    case "$1" in
        40960) echo "0000000a00000000" ;;
        65536) echo "0000001000000000" ;;
        81920) echo "0000001400000000" ;;
        *) return 1 ;;
    esac
}

expected_fb_short_hex_for_mib() {
    case "$1" in
        40960) echo "a00000000" ;;
        65536) echo "1000000000" ;;
        81920) echo "1400000000" ;;
        *) return 1 ;;
    esac
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

trim_csv_field() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "${value}"
}

smi_memory_for_bus() {
    local value="${SMI_MEMORY_BY_BDF[$1]-}"
    [[ -n "${value}" ]] || return 1
    printf '%s\n' "${value}"
}

smi_index_for_bus() {
    local value="${SMI_INDEX_BY_BDF[$1]-}"
    [[ -n "${value}" ]] || return 1
    printf '%s\n' "${value}"
}

banner
step_init 3

for metadata_name in "${METADATA_FILES[@]}"; do
    metadata_path="${INSTALL_MOD_DIR}/${metadata_name}"
    [[ -f "${metadata_path}" && ! -L "${metadata_path}" && \
       -r "${metadata_path}" && -s "${metadata_path}" ]] || \
        die "Required v5 installation metadata is missing, empty, or unsafe: ${metadata_path}"
done

TEN_GB_TARGET="$(cat "${TEN_GB_TARGET_FILE}")"
case "${TEN_GB_TARGET}" in
    40gb) BUILD_FINGERPRINT="cmpunlocker-safety-v5-2082-40g" ;;
    80gb) BUILD_FINGERPRINT="cmpunlocker-safety-v5-2082-80g-experimental" ;;
    *) die "Invalid installed 10GB target '${TEN_GB_TARGET}' in ${TEN_GB_TARGET_FILE}" ;;
esac

step "Locating GPU inventory"
command -v nvidia-smi &>/dev/null || die "nvidia-smi not found"
command -v timeout &>/dev/null || die "timeout is required for bounded GPU verification"
smi_rc=0
SMI_SNAPSHOT="$(timeout --signal=TERM --kill-after=2s 10s \
    nvidia-smi \
    --query-gpu=index,pci.bus_id,memory.total,driver_version,mig.mode.current,compute_mode,vbios_version \
    --format=csv,noheader,nounits 2>/dev/null)" || smi_rc=$?
(( smi_rc == 0 )) || \
    die "nvidia-smi inventory snapshot failed or timed out (status ${smi_rc})"
[[ -n "${SMI_SNAPSHOT}" ]] || die "nvidia-smi returned an empty GPU snapshot"

declare -A SMI_INDEX_BY_BDF=()
declare -A SMI_MEMORY_BY_BDF=()
declare -A SMI_DRIVER_BY_BDF=()
declare -A SMI_MIG_BY_BDF=()
declare -A SMI_COMPUTE_BY_BDF=()
declare -A SMI_VBIOS_BY_BDF=()
while IFS=',' read -r smi_index smi_bus smi_memory smi_driver smi_mig smi_compute smi_vbios smi_extra; do
    smi_index="$(trim_csv_field "${smi_index}")"
    smi_bus="$(normalize_bus_id "$(trim_csv_field "${smi_bus}")")"
    smi_memory="$(trim_csv_field "${smi_memory}")"
    smi_driver="$(trim_csv_field "${smi_driver}")"
    smi_mig="$(trim_csv_field "${smi_mig}")"
    smi_compute="$(trim_csv_field "${smi_compute}")"
    smi_vbios="$(trim_csv_field "${smi_vbios}")"
    smi_extra="$(trim_csv_field "${smi_extra:-}")"
    [[ -z "${smi_extra}" ]] || die "Malformed extra field in nvidia-smi snapshot for ${smi_bus}"
    [[ "${smi_index}" =~ ^[0-9]+$ && \
       "${smi_bus}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ && \
       "${smi_memory}" =~ ^[0-9]+$ && \
       "${smi_driver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && \
       -n "${smi_mig}" && -n "${smi_compute}" && -n "${smi_vbios}" ]] || \
        die "Malformed nvidia-smi snapshot row for ${smi_bus:-unknown}"
    [[ -z "${SMI_INDEX_BY_BDF[${smi_bus}]+x}" ]] || \
        die "Duplicate nvidia-smi snapshot entry for ${smi_bus}"
    SMI_INDEX_BY_BDF["${smi_bus}"]="${smi_index}"
    SMI_MEMORY_BY_BDF["${smi_bus}"]="${smi_memory}"
    SMI_DRIVER_BY_BDF["${smi_bus}"]="${smi_driver}"
    SMI_MIG_BY_BDF["${smi_bus}"]="${smi_mig}"
    SMI_COMPUTE_BY_BDF["${smi_bus}"]="${smi_compute}"
    SMI_VBIOS_BY_BDF["${smi_bus}"]="${smi_vbios}"
done <<< "${SMI_SNAPSHOT}"
[[ ${#SMI_INDEX_BY_BDF[@]} -gt 0 ]] || die "nvidia-smi returned no usable GPU records"

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()
declare -A INSTALLED_INVENTORY=()
declare -A SEEN_INVENTORY=()

info "Checking installed inventory against current PCI hardware: ${INVENTORY_FILE}"
while read -r bdf devid profile expected extra || [[ -n "${bdf:-}" ]]; do
    [[ -n "${bdf:-}" ]] || continue
    [[ "${bdf}" =~ ^# ]] && continue
    [[ -z "${extra:-}" ]] || die "Malformed extra field in inventory line for ${bdf}"
    bdf="$(normalize_bus_id "${bdf}")"
    devid="${devid,,}"
    [[ "${bdf}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] || \
        die "Malformed inventory BDF: ${bdf}"
    [[ -z "${INSTALLED_INVENTORY[${bdf}]+x}" ]] || \
        die "Duplicate inventory entry for ${bdf}"
    canonical_profile="$(profile_from_devid "${devid}")"
    [[ "${canonical_profile}" == "${profile}" ]] || \
        die "Invalid inventory profile for ${bdf}: 10de:${devid} cannot use ${profile}"
    canonical_expected="$(expected_mib_for_profile "${profile}" "${TEN_GB_TARGET}")"
    [[ "${expected}" == "${canonical_expected}" ]] || \
        die "Stale/inconsistent inventory for ${bdf}: expected ${canonical_expected} MiB, file says ${expected}"
    INSTALLED_INVENTORY["${bdf}"]="${devid} ${profile} ${expected}"
done < "${INVENTORY_FILE}"
[[ ${#INSTALLED_INVENTORY[@]} -gt 0 ]] || die "Installed GPU inventory contains no devices"

mapfile -t PCI_LINES < <(lspci -Dnn 2>/dev/null | grep -iE '10de:20c2|10de:2082' || true)
[[ ${#PCI_LINES[@]} -gt 0 ]] || die "No unlockable CMP 170HX GPU found (10de:20c2 / 10de:2082)"
for PCI_LINE in "${PCI_LINES[@]}"; do
    PCI="$(echo "${PCI_LINE}" | awk '{print $1}')"
    PCI_FULL="$(normalize_bus_id "${PCI}")"
    DEVID="$(echo "${PCI_LINE}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
    PROF="$(profile_from_devid "${DEVID}")"
    [[ "${PROF}" != "unsupported" ]] || continue
    if [[ "${PROF}" == "10gb" ]]; then
        sub_vendor="$(cat "/sys/bus/pci/devices/${PCI_FULL}/subsystem_vendor" 2>/dev/null || true)"
        sub_device="$(cat "/sys/bus/pci/devices/${PCI_FULL}/subsystem_device" 2>/dev/null || true)"
        [[ "${sub_vendor,,}:${sub_device,,}" == "0x10de:0x1557" ]] || \
            die "GPU ${PCI_FULL} has unsupported 2082 subsystem ${sub_vendor:-?}:${sub_device:-?}"
    fi
    EXP="$(expected_mib_for_profile "${PROF}" "${TEN_GB_TARGET}")"
    installed_record="${INSTALLED_INVENTORY[${PCI_FULL}]-}"
    [[ -n "${installed_record}" ]] || \
        die "Current GPU ${PCI_FULL} (10de:${DEVID}) was not present at install time"
    [[ "${installed_record}" == "${DEVID} ${PROF} ${EXP}" ]] || \
        die "Current GPU ${PCI_FULL} does not match installed identity/geometry (${installed_record})"
    SEEN_INVENTORY["${PCI_FULL}"]=1
    GPU_BDFS+=("${PCI_FULL}")
    GPU_DEVIDS+=("${DEVID}")
    GPU_PROFILES+=("${PROF}")
    GPU_EXPECTED+=("${EXP}")
done

for installed_bdf in "${!INSTALLED_INVENTORY[@]}"; do
    [[ -n "${SEEN_INVENTORY[${installed_bdf}]-}" ]] || \
        die "Installed GPU ${installed_bdf} is missing or moved in the current PCI inventory"
done
ok "Current PCI inventory exactly matches the installed GPU set"

[[ ${#GPU_BDFS[@]} -gt 0 ]] || die "No unlockable GPUs to verify"

if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
    ten_gb_count=0
    ten_gb_bdf=""
    for i in "${!GPU_BDFS[@]}"; do
        [[ "${GPU_PROFILES[$i]}" == "10gb" ]] || continue
        ten_gb_count=$((ten_gb_count + 1))
        ten_gb_bdf="${GPU_BDFS[$i]}"
    done
    (( ten_gb_count == 1 && ${#GPU_BDFS[@]} == 1 )) || \
        die "Experimental 80GB verification requires one isolated 10de:2082 GPU"
    revision="$(cat "/sys/bus/pci/devices/${ten_gb_bdf}/revision" 2>/dev/null || true)"
    [[ "${revision,,}" == "0xa1" ]] || \
        die "${ten_gb_bdf} revision ${revision:-unknown} is outside the experimental 80GB whitelist"
    [[ "${SMI_MIG_BY_BDF[${ten_gb_bdf}]-}" == "Disabled" && \
       "${SMI_COMPUTE_BY_BDF[${ten_gb_bdf}]-}" == "Default" && \
       "${SMI_VBIOS_BY_BDF[${ten_gb_bdf}]-}" == "92.00.66.00.02" ]] || \
        die "${ten_gb_bdf} failed the experimental 80GB MIG/compute/VBIOS runtime whitelist"
    ok "Experimental 80GB runtime gate is intact for ${ten_gb_bdf}"
fi

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
    if is_unlocked_memory "${profile}" "${expected}" "${actual}"; then
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
[[ -f "${INSTALL_MOD_DIR}/nvidia.ko" && ! -L "${INSTALL_MOD_DIR}/nvidia.ko" ]] || \
    die "Installed cmpunlocker core module is missing: ${INSTALL_MOD_DIR}/nvidia.ko"
installed_fingerprint="$(cat "${INSTALL_MOD_DIR}/build_fingerprint")"
[[ "${installed_fingerprint}" == "${BUILD_FINGERPRINT}" ]] || \
    die "Installed fingerprint '${installed_fingerprint:-missing}' does not match target ${BUILD_FINGERPRINT}"
grep -aFq "${BUILD_FINGERPRINT}" "${INSTALL_MOD_DIR}/nvidia.ko" || \
    die "Installed nvidia.ko does not contain ${BUILD_FINGERPRINT}"
marker_count="$({ grep -aEo 'cmpunlocker-safety-v5-2082-(40g|80g-experimental)' \
    "${INSTALL_MOD_DIR}/nvidia.ko" || true; } | sort -u | wc -l | tr -d '[:space:]')"
[[ "${marker_count}" -eq 1 ]] || \
    die "Installed nvidia.ko has missing or conflicting geometry fingerprints"
[[ -f "${MANIFEST_FILE}" && ! -L "${MANIFEST_FILE}" && \
   -r "${MANIFEST_FILE}" && -s "${MANIFEST_FILE}" ]] || \
    die "Installed checksum manifest is missing, empty, or unsafe"
declare -A MANIFEST_EXPECTED=()
declare -A MANIFEST_SEEN=()
for manifest_name in "${MANIFEST_MEMBERS[@]}"; do
    MANIFEST_EXPECTED["${manifest_name}"]=1
    manifest_path="${INSTALL_MOD_DIR}/${manifest_name}"
    [[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] || \
        die "Manifest member is missing or not a regular file: ${manifest_name}"
done
manifest_count=0
while IFS= read -r manifest_line || [[ -n "${manifest_line}" ]]; do
    [[ "${manifest_line}" =~ ^[0-9a-f]{64}[[:space:]][[:space:]]([A-Za-z0-9._-]+)$ ]] || \
        die "Malformed checksum manifest entry"
    manifest_name="${BASH_REMATCH[1]}"
    [[ -n "${MANIFEST_EXPECTED[${manifest_name}]-}" ]] || \
        die "Unexpected checksum manifest member: ${manifest_name}"
    [[ -z "${MANIFEST_SEEN[${manifest_name}]+x}" ]] || \
        die "Duplicate checksum manifest member: ${manifest_name}"
    MANIFEST_SEEN["${manifest_name}"]=1
    manifest_count=$((manifest_count + 1))
done < "${MANIFEST_FILE}"
[[ "${manifest_count}" -eq "${#MANIFEST_MEMBERS[@]}" ]] || \
    die "Checksum manifest is incomplete: expected ${#MANIFEST_MEMBERS[@]} exact members, found ${manifest_count}"
for manifest_name in "${MANIFEST_MEMBERS[@]}"; do
    [[ -n "${MANIFEST_SEEN[${manifest_name}]-}" ]] || \
        die "Checksum manifest is missing ${manifest_name}"
done
(cd "${INSTALL_MOD_DIR}" && sha256sum --strict -c modules.sha256 >/dev/null) || \
    die "Installed cmpunlocker module/metadata checksum verification failed"

installed_driver_version="$(cat "${INSTALL_MOD_DIR}/driver_version")"
[[ "${installed_driver_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "Installed driver-version metadata is invalid: ${installed_driver_version:-missing}"
if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
    [[ "${installed_driver_version}" == "610.43.02" ]] || \
        die "Experimental 80GB is release-gated to nvidia-open 610.43.02"
    firmware_path="/lib/firmware/nvidia/${installed_driver_version}/gsp_tu10x.bin"
    [[ -f "${firmware_path}" && ! -L "${firmware_path}" ]] || \
        die "Verified stock GSP firmware is missing: ${firmware_path}"
    firmware_sha256="$(sha256sum "${firmware_path}" | awk '{print $1}')"
    [[ "${firmware_sha256}" == "c8fc1a92c90b034bbbe4d56ca94b0dc95afb52d3409a7880186ae03c7dde17f3" ]] || \
        die "Experimental 80GB GSP firmware checksum is not the verified stock 610.43.02 image"
fi
for i in "${!MODULE_NAMES[@]}"; do
    resolved="$(modinfo -k "${KVER}" -n "${MODULE_NAMES[$i]}" 2>/dev/null || true)"
    resolved="$(readlink -e -- "${resolved}" 2>/dev/null || true)"
    expected_path="$(readlink -e -- "${INSTALL_MOD_DIR}/${MODULE_FILES[$i]}" 2>/dev/null || true)"
    [[ -n "${resolved}" && "${resolved}" == "${expected_path}" ]] || \
        die "${MODULE_NAMES[$i]} resolves to '${resolved:-missing}', expected '${expected_path:-missing}'"
    module_vermagic="$(modinfo -F vermagic "${expected_path}" 2>/dev/null || true)"
    [[ "${module_vermagic%% *}" == "${KVER}" ]] || \
        die "${MODULE_NAMES[$i]} vermagic does not match running kernel ${KVER}"
    module_version="$(modinfo -F version "${expected_path}" 2>/dev/null || true)"
    [[ "${module_version}" == "${installed_driver_version}" ]] || \
        die "${MODULE_NAMES[$i]} version '${module_version:-missing}' does not match installed driver ${installed_driver_version}"
done
ok "All five module names resolve to the checksummed cmpunlocker overlay"

running_driver_version="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    /proc/driver/nvidia/version 2>/dev/null | head -1 || true)"
[[ -n "${installed_driver_version}" && \
   "${running_driver_version}" == "${installed_driver_version}" ]] || \
    die "Running NVIDIA version '${running_driver_version:-missing}' does not match installed cmpunlocker version '${installed_driver_version:-missing}'"
for bdf in "${GPU_BDFS[@]}"; do
    [[ "${SMI_DRIVER_BY_BDF[${bdf}]-}" == "${installed_driver_version}" ]] || \
        die "${bdf} nvidia-smi driver snapshot does not match installed driver ${installed_driver_version}"
done
for i in "${!MODULE_NAMES[@]}"; do
    if [[ ! -d "/sys/module/${MODULE_NAMES[$i]}" ]]; then
        info "${MODULE_NAMES[$i]} is not loaded; its on-disk checksum/path/vermagic were verified"
        continue
    fi
    installed_srcversion="$(modinfo -F srcversion \
        "${INSTALL_MOD_DIR}/${MODULE_FILES[$i]}" 2>/dev/null || true)"
    running_srcversion="$(cat "/sys/module/${MODULE_NAMES[$i]}/srcversion" 2>/dev/null || true)"
    [[ -n "${installed_srcversion}" && \
       "${running_srcversion}" == "${installed_srcversion}" ]] || \
        die "Running ${MODULE_NAMES[$i]} is not the currently installed cmpunlocker build; perform the required full power cycle"
done
ok "Running NVIDIA module version/srcversion matches the installed overlay"

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
            grep -F "status=safe build=${BUILD_FINGERPRINT}" || true)"
        unsafe_layout_logs="$(printf '%s\n' "${layout_logs}" | \
            grep -F 'status=safe build=' | \
            grep -Fv "status=safe build=${BUILD_FINGERPRINT}" || true)"
        unsafe_pma_logs="$(grep -Fv "status=safe build=${BUILD_FINGERPRINT}" \
            <<< "${pma_logs}" || true)"

        expected_fb_hex="$(expected_fb_hex_for_mib "${GPU_EXPECTED[$i]}" || true)"
        expected_fb_short_hex="$(expected_fb_short_hex_for_mib "${GPU_EXPECTED[$i]}" || true)"
        if [[ -z "${expected_fb_hex}" ]]; then
            err "${bdf}: unsupported installed expected memory ${GPU_EXPECTED[$i]} MiB"
            failures=$((failures + 1))
        elif [[ -z "${safe_layout_logs}" ]]; then
            err "${bdf}: missing the required safe native framebuffer-layout proof"
            failures=$((failures + 1))
        elif ! grep -Fiq "fbSize=0x${expected_fb_hex}" <<< "${safe_layout_logs}"; then
            err "${bdf}: safe layout proof does not match expected ${GPU_EXPECTED[$i]} MiB geometry"
            failures=$((failures + 1))
        elif grep -Fq 'SEC2_DEBUG_FB_LAYOUT: rejected' <<< "${layout_logs}"; then
            err "${bdf}: the current boot contains a rejected framebuffer layout"
            failures=$((failures + 1))
        elif [[ -n "${unsafe_layout_logs}" ]]; then
            err "${bdf}: framebuffer proof uses a different build/geometry fingerprint"
            failures=$((failures + 1))
        else
            ok "${bdf}: native framebuffer layout is safe"
        fi

        safe_pma_logs="$(printf '%s\n' "${pma_logs}" | \
            grep -F "status=safe build=${BUILD_FINGERPRINT}" || true)"
        if [[ -z "${safe_pma_logs}" ]]; then
            err "${bdf}: missing the required safe physical-memory-allocator proof"
            failures=$((failures + 1))
        elif ! grep -Fiq "fbSize=0x${expected_fb_short_hex}" <<< "${safe_pma_logs}"; then
            err "${bdf}: allocator proof does not match expected ${GPU_EXPECTED[$i]} MiB geometry"
            failures=$((failures + 1))
        elif [[ -n "${unsafe_pma_logs}" ]]; then
            err "${bdf}: the current boot contains an unsafe allocator diagnostic"
            failures=$((failures + 1))
        else
            ok "${bdf}: physical memory allocator matches the validated public range"
        fi
    done
fi

echo ""
if [[ -r "${INSTALL_MOD_DIR}/card_profile" ]]; then
    info "Installed profile: $(cat "${INSTALL_MOD_DIR}/card_profile") / geometry: $(cat "${INSTALL_MOD_DIR}/unlock_geometry" 2>/dev/null || echo '?') / 10GB target: ${TEN_GB_TARGET}"
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
