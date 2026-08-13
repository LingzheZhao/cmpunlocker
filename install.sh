#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/driver/VERSION")
SUPPORTED_VERSIONS_CSV="$(IFS=', '; echo "${SUPPORTED_VERSIONS[*]}")"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

PROFILE_OVERRIDE=""
TEN_GB_TARGET="40gb"
CONFIGURE_IOMMU=1
CONFIGURE_GEN2_SERVICE=1
for arg in "$@"; do
    case "${arg}" in
        --profile=8gb|--profile=8GB) PROFILE_OVERRIDE="8gb" ;;
        --profile=10gb|--profile=10GB) PROFILE_OVERRIDE="10gb" ;;
        --experimental-80g) TEN_GB_TARGET="80gb" ;;
        --no-iommu) CONFIGURE_IOMMU=0 ;;
        --no-gen2-service) CONFIGURE_GEN2_SERVICE=0 ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./install.sh [--experimental-80g] [--profile=8gb|10gb]
                         [--no-iommu] [--no-gen2-service]

  --profile=8gb   Assert that the detected hardware is the 8GB/20c2 variant
  --profile=10gb  Assert that the detected hardware is the 10GB/2082 variant
  --experimental-80g
                  Use the experimental 10GB → 80GB geometry on 10de:2082.
                  This proves only logical layout and allocator accounting;
                  independent physical HBM addressing remains unverified.
                  The stable default remains 40GB.
  --no-iommu      Do not touch the kernel command line (leave IOMMU settings alone)
  --no-gen2-service
                  Do not install the early-boot PCIe Gen2 retrain service

By default the installer appends intel_iommu=on / amd_iommu=on plus iommu=pt to
the kernel command line so the IOMMU runs in passthrough mode. This takes effect
on the next reboot.

Without --profile, each unlockable GPU is classified by PCI device ID:
  10de:20c2 → 8gb / 64GB unlock
  10de:2082 → 10gb / 40GB unlock

--experimental-80g changes one isolated, whitelisted 10de:2082 card to 80GB.
It is rejected when another unlockable GPU is present. A cold power cycle and
verify.sh are mandatory. verify.sh intentionally returns failure for this mode
until an address-dependent low/high physical-alias test has passed.

Multi-GPU and mixed 8GB+10GB systems are supported only for the default target.
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Try: sudo ./install.sh --help" >&2
            exit 1
            ;;
    esac
done

exec > >(tee -a "${LOG_FILE}") 2>&1

source "${SCRIPT_DIR}/common/lib.sh"

banner
step_init 6

step "Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./install.sh"
command -v flock &>/dev/null || die "flock is required to serialize install/remove operations"
command -v timeout &>/dev/null || die "timeout is required for bounded GPU checks"
exec 9>/run/lock/cmpunlocker.lock
flock -n 9 || die "Another cmpunlocker install/remove operation is already running"
ok "Running as root"

step "Detecting CMP 170HX GPU(s)"
mapfile -t PCI_LINES < <(lspci -nn 2>/dev/null | grep -iE '10de:20b0|10de:20c2|10de:2082' || true)
[[ ${#PCI_LINES[@]} -gt 0 ]] || die "No CMP 170HX GPU found (10de:20b0 / 10de:20c2 / 10de:2082)"

SMI_MEM_CACHE=""
trim_csv_field() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "${value}"
}
if command -v nvidia-smi &>/dev/null; then
    SMI_MEM_CACHE="$(timeout --signal=TERM --kill-after=2s 10s \
        nvidia-smi --query-gpu=pci.bus_id,memory.total \
        --format=csv,noheader,nounits 2>/dev/null || true)"
fi

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()
COUNT_8GB=0
COUNT_10GB=0
COUNT_UNSUPPORTED=0

for PCI_LINE in "${PCI_LINES[@]}"; do
    PCI="$(echo "${PCI_LINE}" | awk '{print $1}')"
    PCI_FULL="$(normalize_bus_id "${PCI}")"
    DEVID="$(echo "${PCI_LINE}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
    PROF="$(profile_from_devid "${DEVID}")"
    CUR_MEM="$(smi_memory_for_bus "${PCI_FULL}" || true)"
    [[ -n "${CUR_MEM}" ]] || CUR_MEM="?"

    if [[ "${PROF}" == "unsupported" ]]; then
        COUNT_UNSUPPORTED=$((COUNT_UNSUPPORTED + 1))
        warn "GPU ${PCI_FULL} (10de:${DEVID}) — unlock path not gated for this ID; skipping"
        continue
    fi
    if [[ "${PROF}" == "10gb" ]]; then
        sub_vendor="$(cat "/sys/bus/pci/devices/${PCI_FULL}/subsystem_vendor" 2>/dev/null || true)"
        sub_device="$(cat "/sys/bus/pci/devices/${PCI_FULL}/subsystem_device" 2>/dev/null || true)"
        [[ "${sub_vendor,,}:${sub_device,,}" == "0x10de:0x1557" ]] || \
            die "GPU ${PCI_FULL} has unsupported subsystem ${sub_vendor:-?}:${sub_device:-?}; 2082 unlock is gated to 10de:1557"
    fi

    EXP="$(expected_mib_for_profile "${PROF}" "${TEN_GB_TARGET}")"
    GPU_BDFS+=("${PCI_FULL}")
    GPU_DEVIDS+=("${DEVID}")
    GPU_PROFILES+=("${PROF}")
    GPU_EXPECTED+=("${EXP}")

    if [[ "${PROF}" == "8gb" ]]; then
        COUNT_8GB=$((COUNT_8GB + 1))
    else
        COUNT_10GB=$((COUNT_10GB + 1))
    fi

    if [[ "${CUR_MEM}" != "?" ]]; then
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (current ${CUR_MEM} MiB, expect ~${EXP} MiB unlocked)"
    else
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (expect ~${EXP} MiB unlocked)"
    fi
done

[[ ${#GPU_BDFS[@]} -gt 0 ]] || die "No unlockable CMP 170HX GPUs found (need 10de:20c2 and/or 10de:2082)"
if [[ "${TEN_GB_TARGET}" == "80gb" && "${COUNT_10GB}" -eq 0 ]]; then
    die "--experimental-80g requires at least one 10de:2082 (10GB) card"
fi
if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
    (( COUNT_10GB == 1 && ${#GPU_BDFS[@]} == 1 )) || \
        die "Experimental 80GB mode currently supports one isolated 10de:2082 card and no other unlockable GPU"
    for i in "${!GPU_BDFS[@]}"; do
        [[ "${GPU_DEVIDS[$i]}" == "2082" ]] || continue
        info "${GPU_BDFS[$i]} is eligible for the 10GB→80GB profile by PCI ID 10de:2082; current driver-reported VRAM does not determine the physical variant"
        revision="$(cat "/sys/bus/pci/devices/${GPU_BDFS[$i]}/revision" 2>/dev/null || true)"
        [[ "${revision,,}" == "0xa1" ]] || \
            die "${GPU_BDFS[$i]} revision ${revision:-unknown} is outside the experimental 80GB whitelist (requires a1)"
        gpu_modes="$(timeout --signal=TERM --kill-after=2s 10s \
            nvidia-smi -i "${GPU_BDFS[$i]}" \
            --query-gpu=mig.mode.current,compute_mode,vbios_version \
            --format=csv,noheader,nounits 2>/dev/null || true)"
        IFS=',' read -r gpu_mig gpu_compute gpu_vbios gpu_extra <<< "${gpu_modes}"
        gpu_mig="$(trim_csv_field "${gpu_mig:-}")"
        gpu_compute="$(trim_csv_field "${gpu_compute:-}")"
        gpu_vbios="$(trim_csv_field "${gpu_vbios:-}")"
        gpu_extra="$(trim_csv_field "${gpu_extra:-}")"
        [[ "${gpu_mig}" == "Disabled" && "${gpu_compute}" == "Default" && \
           "${gpu_vbios}" == "92.00.66.00.02" && -z "${gpu_extra}" ]] || \
            die "${GPU_BDFS[$i]} is outside the experimental 80GB runtime whitelist (need MIG Disabled, compute Default, VBIOS 92.00.66.00.02; got '${gpu_modes:-unknown}')"
    done
    warn "Experimental 80GB mode selected for the single 10de:2082 card"
    warn "This path has source/build tests only; use 40GB for production stability"
fi
if (( COUNT_UNSUPPORTED > 0 )); then
    info "Inventory: ${#GPU_BDFS[@]} unlockable (${COUNT_8GB}× 8gb, ${COUNT_10GB}× 10gb), ${COUNT_UNSUPPORTED} unsupported"
else
    info "Inventory: ${#GPU_BDFS[@]} unlockable (${COUNT_8GB}× 8gb, ${COUNT_10GB}× 10gb)"
fi

step "Selecting card memory profile"
CARD_PROFILE=""
if (( COUNT_8GB > 0 && COUNT_10GB > 0 )); then
    CARD_PROFILE="mixed"
    ok "Mixed variants detected → profile mixed (runtime geometry by PCI ID)"
    if [[ -n "${PROFILE_OVERRIDE}" ]]; then
        warn "--profile=${PROFILE_OVERRIDE} ignored for mixed inventory; card_profile stays mixed (each card unlocks by PCI ID)"
    fi
elif (( COUNT_8GB > 0 )); then
    CARD_PROFILE="8gb"
elif (( COUNT_10GB > 0 )); then
    CARD_PROFILE="10gb"
else
    die "Internal error: no unlockable profiles counted"
fi

if [[ -n "${PROFILE_OVERRIDE}" && "${CARD_PROFILE}" != "mixed" ]]; then
    if [[ "${PROFILE_OVERRIDE}" != "${CARD_PROFILE}" ]]; then
        die "--profile=${PROFILE_OVERRIDE} conflicts with detected ${CARD_PROFILE} hardware"
    else
        ok "Profile forced via --profile=${CARD_PROFILE}"
    fi
fi

case "${CARD_PROFILE}" in
    8gb)
        info "Unlock geometry: 64GB per card (CFG1=0x02779000 LMR=0x0000020B)"
        ;;
    10gb)
        if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
            info "Unlock geometry: 80GB experimental (CFG1=0x02779000 LMR=0x0000028B)"
        else
            info "Unlock geometry: 40GB per card (CFG1=0x02669000 LMR=0x0000028A)"
        fi
        ;;
    mixed)
        if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
            info "Unlock geometry: 64GB for 20c2 / 80GB experimental for 2082"
        else
            info "Unlock geometry: 64GB for 20c2 / 40GB for 2082"
        fi
        ;;
    *)
        die "Internal error: bad profile ${CARD_PROFILE}"
        ;;
esac

GPU_INVENTORY_LINES=()
for i in "${!GPU_BDFS[@]}"; do
    GPU_INVENTORY_LINES+=("${GPU_BDFS[$i]} ${GPU_DEVIDS[$i]} ${GPU_PROFILES[$i]} ${GPU_EXPECTED[$i]}")
done
export CMPUNLOCKER_CARD_PROFILE="${CARD_PROFILE}"
export CMPUNLOCKER_10GB_TARGET="${TEN_GB_TARGET}"
export CMPUNLOCKER_GPU_INVENTORY="$(printf '%s\n' "${GPU_INVENTORY_LINES[@]}")"

step "Verifying nvidia-open (${SUPPORTED_VERSIONS_CSV})"
[[ ${#SUPPORTED_VERSIONS[@]} -gt 0 ]] || die "No supported versions listed in driver/VERSION"
for required_command in find mktemp modinfo od readelf readlink sha256sum; do
    command -v "${required_command}" &>/dev/null || \
        die "${required_command} is required for driver and firmware verification"
done
if [[ -d /sys/firmware/efi ]]; then
    secure_boot_known=0
    if command -v mokutil &>/dev/null; then
        mok_state="$(mokutil --sb-state 2>/dev/null || true)"
        if grep -qi 'SecureBoot enabled' <<< "${mok_state}"; then
            die "Secure Boot is enabled. Disable it before installing unsigned patched modules."
        elif grep -qi 'SecureBoot disabled' <<< "${mok_state}"; then
            secure_boot_known=1
        fi
    fi
    secure_boot_var="$(find /sys/firmware/efi/efivars -maxdepth 1 \
        -name 'SecureBoot-*' -print -quit 2>/dev/null || true)"
    if [[ -n "${secure_boot_var}" && -r "${secure_boot_var}" ]]; then
        secure_boot_value="$(od -An -t u1 -j 4 -N 1 "${secure_boot_var}" 2>/dev/null | tr -d '[:space:]')"
        case "${secure_boot_value}" in
            0) secure_boot_known=1 ;;
            1) die "EFI SecureBoot variable is enabled; unsigned patched modules cannot be used" ;;
            *) die "Cannot interpret EFI SecureBoot variable ${secure_boot_var}" ;;
        esac
    fi
    (( secure_boot_known == 1 )) || \
        die "Cannot prove that Secure Boot is disabled"
fi
lockdown_state="$(cat /sys/kernel/security/lockdown 2>/dev/null || true)"
if grep -Eq '\[(integrity|confidentiality)\]' <<< "${lockdown_state}"; then
    die "Kernel lockdown is active (${lockdown_state}); unsigned patched modules cannot be used"
fi
if grep -Eq '^CONFIG_MODULE_SIG_FORCE=y$' \
    "/boot/config-$(uname -r)" "/lib/modules/$(uname -r)/build/.config" 2>/dev/null; then
    die "The running kernel enforces module signatures (CONFIG_MODULE_SIG_FORCE=y)"
fi

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

detected=""
if [[ -r /proc/driver/nvidia/version ]]; then
    detected="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1 || true)"
fi
if [[ -z "${detected}" ]] && command -v nvidia-smi &>/dev/null; then
    smi_version="$(timeout --signal=TERM --kill-after=2s 10s \
        nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | \
        head -1 | tr -d '[:space:]' || true)"
    [[ "${smi_version}" =~ ^[0-9]+(\.[0-9]+)+$ ]] && detected="${smi_version}"
fi
if [[ -z "${detected}" ]]; then
    detected="$(modinfo -k "$(uname -r)" -F version nvidia 2>/dev/null | \
        head -1 | tr -d '[:space:]' || true)"
fi

[[ -n "${detected}" ]] || die "Could not detect an installed NVIDIA driver. Install nvidia-open ${SUPPORTED_VERSIONS_CSV} first."
version_supported "${detected}" || die "Installed driver is ${detected}, but cmpunlocker requires one of: ${SUPPORTED_VERSIONS_CSV}."
ok "NVIDIA driver ${detected} is supported"
if [[ "${TEN_GB_TARGET}" == "80gb" && "${detected}" != "610.43.02" ]]; then
    die "Experimental 80GB is currently release-gated to nvidia-open 610.43.02; use the 40GB default with ${detected}"
fi

STOCK_MODULE_FILES=(nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko)
stock_module_root=""
while IFS= read -r candidate; do
    candidate_version="$(modinfo -F version "${candidate}" 2>/dev/null | head -1 || true)"
    candidate_vermagic="$(modinfo -F vermagic "${candidate}" 2>/dev/null | head -1 || true)"
    marker_rc=0
    module_contains_cmp_marker "${candidate}" || marker_rc=$?
    [[ "${candidate_version}" == "${detected}" && \
       "${candidate_vermagic%% *}" == "$(uname -r)" && \
       "${marker_rc}" -eq 1 ]] || continue

    candidate_root="$(dirname "$(readlink -e -- "${candidate}")")"
    complete_stock_set=1
    for stock_file in "${STOCK_MODULE_FILES[@]}"; do
        mapfile -t stock_matches < <(find "${candidate_root}" -maxdepth 1 -type f \
            \( -name "${stock_file}" -o -name "${stock_file}.gz" \
               -o -name "${stock_file}.xz" -o -name "${stock_file}.zst" \) \
            -print 2>/dev/null | sort)
        if [[ ${#stock_matches[@]} -ne 1 ]]; then
            complete_stock_set=0
            break
        fi
        stock_path="$(readlink -e -- "${stock_matches[0]}" 2>/dev/null || true)"
        stock_version="$(modinfo -F version "${stock_path}" 2>/dev/null || true)"
        stock_vermagic="$(modinfo -F vermagic "${stock_path}" 2>/dev/null || true)"
        marker_rc=0
        module_contains_cmp_marker "${stock_path}" || marker_rc=$?
        if [[ "${stock_version}" != "${detected}" || \
              "${stock_vermagic%% *}" != "$(uname -r)" || \
              "${marker_rc}" -ne 1 ]]; then
            complete_stock_set=0
            break
        fi
    done
    if (( complete_stock_set == 1 )); then
        stock_module_root="${candidate_root}"
        break
    fi
done < <(find "/lib/modules/$(uname -r)" -type f \
    \( -name 'nvidia.ko' -o -name 'nvidia.ko.gz' -o -name 'nvidia.ko.xz' -o -name 'nvidia.ko.zst' \) \
    ! -path '*/updates/cmpunlocker*/*' -print 2>/dev/null | sort)
if [[ -n "${stock_module_root}" ]]; then
    ok "Complete five-module stock rollback set verified: ${stock_module_root}"
else
    warn "No coherent five-module nvidia-open ${detected} stock rollback set remains for kernel $(uname -r)"
    warn "Continuing without an automatic stock-module rollback path; reinstall or reconfigure nvidia-dkms-610-open before removal/recovery"
fi

GSP_FIRMWARE="/lib/firmware/nvidia/${detected}/gsp_tu10x.bin"
[[ -f "${GSP_FIRMWARE}" ]] || \
    die "Missing matching stock GSP firmware: ${GSP_FIRMWARE}"
firmware_version="$(readelf -p .fwversion "${GSP_FIRMWARE}" 2>/dev/null | \
    awk '/\[[[:space:]]*0\]/{print $NF; exit}')"
signature_size="$(readelf -SW "${GSP_FIRMWARE}" 2>/dev/null | \
    awk '$3 == ".fwsignature_ga100" {print tolower($7)}')"
signature_count="$(readelf -SW "${GSP_FIRMWARE}" 2>/dev/null | \
    awk '$3 == ".fwsignature_ga100" {count++} END {print count + 0}')"
[[ "${firmware_version}" == "${detected}" ]] || \
    die "GSP firmware version '${firmware_version:-unknown}' does not match driver ${detected}"
[[ "${signature_count}" -eq 1 && "${signature_size}" == "001000" ]] || \
    die "GA100 firmware signature must be the single stock 0x1000-byte section; refusing patched/easyunlock firmware"
if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
    firmware_sha256="$(sha256sum "${GSP_FIRMWARE}" | awk '{print $1}')"
    [[ "${firmware_sha256}" == "c8fc1a92c90b034bbbe4d56ca94b0dc95afb52d3409a7880186ae03c7dde17f3" ]] || \
        die "Experimental 80GB requires the verified stock 610.43.02 GSP firmware (got SHA256 ${firmware_sha256})"
fi
ok "Stock ${detected} GSP firmware has a single 0x1000-byte GA100 signature"

[[ -d "/lib/modules/$(uname -r)/build" ]] || die "Kernel headers missing for $(uname -r). Install linux-headers-$(uname -r) or kernel-devel."
ok "Kernel headers present for $(uname -r)"

if [[ -n "${stock_module_root}" ]]; then
    info "Keeping stock NVIDIA/DKMS modules installed as the rollback path"
else
    warn "No stock NVIDIA/DKMS rollback modules are currently available on disk"
fi

step "Building and installing patched modules"
chmod +x "${SCRIPT_DIR}/driver/build.sh"
CMPUNLOCKER_DRIVER_VERSION="${detected}" \
CMPUNLOCKER_CARD_PROFILE="${CARD_PROFILE}" \
CMPUNLOCKER_10GB_TARGET="${TEN_GB_TARGET}" \
CMPUNLOCKER_GPU_INVENTORY="${CMPUNLOCKER_GPU_INVENTORY}" \
CMPUNLOCKER_INSTALL_GATES_OK=1 \
CMPUNLOCKER_LOCK_HELD=1 \
    "${SCRIPT_DIR}/driver/build.sh"
ok "Patched modules and PCIe Gen2 options installed (profile ${CARD_PROFILE})"

for legacy_unit in cmpretrain.service cmp-gen2-retrain.service; do
    systemctl disable --now "${legacy_unit}" 2>/dev/null || true
    systemctl reset-failed "${legacy_unit}" 2>/dev/null || true
done
if [[ -f /etc/systemd/system/gen2.service ]] && \
   grep -Fq 'CMP 170HX early-boot PCIe Gen2 retrain' /etc/systemd/system/gen2.service; then
    systemctl disable --now gen2.service 2>/dev/null || true
    systemctl reset-failed gen2.service 2>/dev/null || true
    rm -f /etc/systemd/system/gen2.service
fi
if [[ -f /usr/local/sbin/gen2-hammer ]] && \
   grep -Fq 'readonly VENDOR_ID="10de"' /usr/local/sbin/gen2-hammer; then
    rm -f /usr/local/sbin/gen2-hammer
fi
rm -f /etc/systemd/system/cmpretrain.service \
      /etc/systemd/system/cmp-gen2-retrain.service \
      /usr/local/sbin/cmp-gen2-retrain.sh
if [[ -f /usr/local/sbin/retrain.sh ]] && \
   grep -Fq 'GPU, UP = "0a:00.0", "09:01.0"' /usr/local/sbin/retrain.sh; then
    rm -f /usr/local/sbin/retrain.sh
fi
systemctl daemon-reload
ok "Removed legacy cmpunlocker PCIe retrain helpers"

if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    chmod +x "${SCRIPT_DIR}/tools/hammer.sh" \
             "${SCRIPT_DIR}/tools/service.sh"
    "${SCRIPT_DIR}/tools/service.sh" install
    ok "Early-boot Gen2 retrain service armed (not started in this session)"
else
    if [[ -e /etc/systemd/system/cmpunlocker-gen2.service || \
          -e /usr/local/sbin/cmpunlocker-gen2-hammer ]]; then
        bash "${SCRIPT_DIR}/tools/service.sh" remove
        ok "Removed the previously installed early-boot Gen2 retrain service"
    fi
    warn "--no-gen2-service given; early-boot PCIe retraining is not installed"
fi

info "Configuring IOMMU (passthrough)"
IOMMU_STATUS="skipped"
IOMMU_PARAMS=""

iommu_params_for_cpu() {
    local vendor=""
    vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    case "${vendor}" in
        GenuineIntel) echo "intel_iommu=on iommu=pt" ;;
        AuthenticAMD) echo "amd_iommu=on iommu=pt" ;;
        *) echo "" ;;
    esac
}

cmdline_merge() {
    local current="$1"
    local token
    local -a out=() current_tokens=() iommu_tokens=()
    read -r -a current_tokens <<< "${current}"
    for token in "${current_tokens[@]}"; do
        case "${token}" in
            intel_iommu=*|amd_iommu=*|iommu=*) continue ;;
            *) out+=("${token}") ;;
        esac
    done
    read -r -a iommu_tokens <<< "${IOMMU_PARAMS}"
    for token in "${iommu_tokens[@]}"; do
        out+=("${token}")
    done
    echo "${out[*]}"
}

configure_iommu_grub() {
    local grub_file="/etc/default/grub"
    local key="GRUB_CMDLINE_LINUX_DEFAULT"
    local current merged current_line quote_char rewrite_tmp line replaced

    grep -q "^${key}=" "${grub_file}" || key="GRUB_CMDLINE_LINUX"
    if grep -q "^${key}=" "${grub_file}"; then
        [[ "$(grep -c "^${key}=" "${grub_file}")" -eq 1 ]] || \
            die "Multiple ${key} assignments exist in ${grub_file}; refusing an ambiguous rewrite"
        current_line="$(grep -m1 "^${key}=" "${grub_file}")"
        if [[ "${current_line}" =~ ^${key}=\"([^\"]*)\"$ ]]; then
            current="${BASH_REMATCH[1]}"
            quote_char='"'
        elif [[ "${current_line}" =~ ^${key}=\'([^\']*)\'$ ]]; then
            current="${BASH_REMATCH[1]}"
            quote_char="'"
        else
            die "Unsupported ${key} quoting in ${grub_file}; refusing to rewrite the kernel command line"
        fi
    else
        current=""
        quote_char='"'
    fi
    merged="$(cmdline_merge "${current}")"

    if [[ "${current}" == "${merged}" ]]; then
        ok "GRUB already has ${IOMMU_PARAMS} (${key})"
        IOMMU_STATUS="already-set"
        return 0
    fi

    if [[ -e "${grub_file}.cmpunlocker.bak" ]]; then
        die "Refusing to overwrite existing recovery file ${grub_file}.cmpunlocker.bak"
    fi
    cp -a "${grub_file}" "${grub_file}.cmpunlocker.bak"
    sha256sum "${grub_file}.cmpunlocker.bak" | awk '{print $1}' > \
        "${grub_file}.cmpunlocker.backup.sha256"
    if grep -q "^${key}=" "${grub_file}"; then
        rewrite_tmp="${grub_file}.cmpunlocker.new.$$"
        [[ ! -e "${rewrite_tmp}" ]] || die "Temporary GRUB rewrite path already exists: ${rewrite_tmp}"
        cp -a -- "${grub_file}" "${rewrite_tmp}"
        replaced=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" == "${key}="* && "${replaced}" -eq 0 ]]; then
                printf '%s=%s%s%s\n' "${key}" "${quote_char}" "${merged}" "${quote_char}"
                replaced=1
            else
                printf '%s\n' "${line}"
            fi
        done < "${grub_file}" > "${rewrite_tmp}"
        (( replaced == 1 )) || die "Could not rewrite ${key} in ${grub_file}"
        mv -f -- "${rewrite_tmp}" "${grub_file}"
    else
        printf '%s="%s"\n' "${key}" "${merged}" >> "${grub_file}"
    fi
    sha256sum "${grub_file}" | awk '{print $1}' > \
        "${grub_file}.cmpunlocker.installed.sha256"
    ok "Set ${key}=\"${merged}\" (backup: ${grub_file}.cmpunlocker.bak)"

    if command -v update-grub &>/dev/null; then
        printf '%s\n' 'update-grub' > "${grub_file}.cmpunlocker.generator"
        update-grub
    elif command -v grub2-mkconfig &>/dev/null; then
        local cfg="/boot/grub2/grub.cfg"
        [[ -d "$(dirname "${cfg}")" ]] || \
            die "Refusing to guess a GRUB2 output path; expected directory $(dirname "${cfg}") is missing"
        printf 'grub2-mkconfig:%s\n' "${cfg}" > "${grub_file}.cmpunlocker.generator"
        grub2-mkconfig -o "${cfg}"
    elif command -v grub-mkconfig &>/dev/null; then
        printf '%s\n' 'grub-mkconfig:/boot/grub/grub.cfg' > \
            "${grub_file}.cmpunlocker.generator"
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        printf '%s\n' 'manual' > "${grub_file}.cmpunlocker.generator"
        warn "No grub config generator found — regenerate grub.cfg manually"
        IOMMU_STATUS="needs-grub-regen"
        return 0
    fi
    ok "Regenerated GRUB config"
    IOMMU_STATUS="configured"
}

configure_iommu_kernel_cmdline() {
    local file="/etc/kernel/cmdline"
    local current merged refreshed_entries
    current="$(tr -d '\n' < "${file}")"
    merged="$(cmdline_merge "${current}")"

    if [[ "${current}" == "${merged}" ]]; then
        ok "${file} already has ${IOMMU_PARAMS}"
        IOMMU_STATUS="already-set"
        return 0
    fi

    if [[ -e "${file}.cmpunlocker.bak" ]]; then
        die "Refusing to overwrite existing recovery file ${file}.cmpunlocker.bak"
    fi
    cp -a "${file}" "${file}.cmpunlocker.bak"
    sha256sum "${file}.cmpunlocker.bak" | awk '{print $1}' > \
        "${file}.cmpunlocker.backup.sha256"
    printf '%s\n' "${merged}" > "${file}"
    sha256sum "${file}" | awk '{print $1}' > \
        "${file}.cmpunlocker.installed.sha256"
    ok "Set ${file} to \"${merged}\" (backup: ${file}.cmpunlocker.bak)"

    if command -v kernel-install &>/dev/null && [[ -d /boot/loader/entries ]]; then
        refreshed_entries=0
        for kdir in /lib/modules/*/; do
            kver="$(basename "${kdir}")"
            [[ -f "${kdir}/vmlinuz" ]] || continue
            kernel-install add "${kver}" "${kdir}/vmlinuz" || \
                die "kernel-install failed while refreshing ${kver}"
            refreshed_entries=$((refreshed_entries + 1))
        done
        (( refreshed_entries > 0 )) || \
            die "No kernel image was available for a systemd-boot entry refresh"
        ok "Refreshed systemd-boot entries"
        IOMMU_STATUS="configured"
    else
        warn "Update your boot entries so ${file} takes effect"
        IOMMU_STATUS="needs-boot-refresh"
    fi
}

if (( CONFIGURE_IOMMU == 0 )); then
    warn "--no-iommu given; leaving kernel command line untouched"
else
    IOMMU_PARAMS="$(iommu_params_for_cpu)"
    if [[ -z "${IOMMU_PARAMS}" ]]; then
        warn "Unrecognized CPU vendor — cannot pick IOMMU kernel parameters; skipping"
    elif [[ -f /etc/default/grub ]]; then
        info "Target: ${IOMMU_PARAMS} (GRUB)"
        configure_iommu_grub
    elif [[ -f /etc/kernel/cmdline ]]; then
        info "Target: ${IOMMU_PARAMS} (systemd-boot)"
        configure_iommu_kernel_cmdline
    else
        warn "No /etc/default/grub or /etc/kernel/cmdline found"
        warn "Add these to your kernel command line manually: ${IOMMU_PARAMS}"
        IOMMU_STATUS="manual"
    fi

    if grep -qw iommu=pt /proc/cmdline 2>/dev/null && [[ -d /sys/class/iommu ]] && [[ -n "$(ls -A /sys/class/iommu 2>/dev/null)" ]]; then
        ok "IOMMU is already active in passthrough mode on the running kernel"
    elif [[ "${IOMMU_STATUS}" != "skipped" ]]; then
        info "IOMMU passthrough takes effect after the next reboot"
        warn "IOMMU must also be enabled in BIOS/UEFI (VT-d / AMD-Vi / SVM)"
    fi
fi

step "Done"
banner
echo "cmpunlocker install finished!"
echo "Profile: ${CARD_PROFILE}  |  ${#GPU_BDFS[@]} GPU(s): ${COUNT_8GB}× 8gb, ${COUNT_10GB}× 10gb"
echo "10GB target: ${TEN_GB_TARGET}"
if [[ -n "${IOMMU_PARAMS}" && "${IOMMU_STATUS}" != "skipped" ]]; then
    echo "IOMMU:   ${IOMMU_PARAMS} (${IOMMU_STATUS})"
else
    echo "IOMMU:   not configured"
fi
echo ""
echo "Per-GPU expectations after unlock:"
printf "  %-16s %-8s %-8s %s\n" "BDF" "PCI ID" "Variant" "Expect MiB"
for i in "${!GPU_BDFS[@]}"; do
    printf "  %-16s %-8s %-8s ~%s\n" "${GPU_BDFS[$i]}" "${GPU_DEVIDS[$i]}" "${GPU_PROFILES[$i]}" "${GPU_EXPECTED[$i]}"
done
echo ""
echo "Next:"
echo -e "  1. Required full power-off: ${CYAN}sudo shutdown -h now${NC}  (remove standby power, then power on)"
echo -e "  2. Verify all GPUs: ${CYAN}sudo ./verify.sh${NC}"
echo -e "  3. Verify PCIe Gen2: ${CYAN}nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max --format=csv${NC}  (expect 2,2)"
echo -e "  4. Or check manually: ${CYAN}nvidia-smi${NC}"
echo -e "  5. Unlock logs: ${CYAN}sudo dmesg | grep SEC2_DEBUG${NC}"
echo -e "  6. Verify IOMMU after reboot: ${CYAN}cat /proc/cmdline${NC} and ${CYAN}ls /sys/class/iommu${NC}"
if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    echo -e "  7. Verify negotiated Gen2: ${CYAN}sudo ./tools/service.sh verify${NC}"
    echo -e "     Recovery boot option: ${CYAN}systemd.mask=cmpunlocker-gen2.service${NC}"
fi
echo ""
echo "Stock NVIDIA/DKMS modules were preserved. Re-run this installer after each kernel upgrade."
echo "Log saved to: ${LOG_FILE}"
echo ""
