#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cmpunlocker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/cmpunlocker"
MODPROBE_OPTIONS_FILE="/etc/modprobe.d/cmp-pcie-gen2.conf"

source "${SCRIPT_DIR}/common/lib.sh"

banner

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
    warn "This removes cmpunlocker patched kernel modules:"
    echo "  - Stops cmpunlocker systemd service"
    echo "  - Removes /lib/modules/*/updates/cmpunlocker/"
    echo "  - Preserves ${INSTALL_DIR} for manual review (legacy install dir, if present)"
    echo "  - Leaves running NVIDIA modules untouched until a required cold power-off"
    echo "  - Removes cmpretrain service / modprobe Gen2 helpers"
    echo "  - Restores the pre-install kernel command line only when recovery hashes verify"
    echo ""
    echo "Run: sudo ./remove.sh --yes"
    exit 1
fi

step_init 5

step "Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./remove.sh --yes"
command -v flock &>/dev/null || die "flock is required to serialize install/remove operations"
for required_command in depmod find mktemp modinfo readelf readlink sha256sum; do
    command -v "${required_command}" &>/dev/null || \
        die "${required_command} is required for fail-closed module removal"
done
exec 9>/run/lock/cmpunlocker.lock
flock -n 9 || die "Another cmpunlocker install/remove operation is already running"
ok "Running as root"

LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="/tmp"
fi
LOG_FILE="${LOG_DIR}/remove_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

info "Preflighting stock rollback before changing the installed overlay"
MODULE_NAMES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm nvidia_peermem)
MODULE_FILES=(nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko)
declare -A AFFECTED_KERNELS=()
declare -A STOCK_HASHES=()
declare -A STOCK_VERSIONS=()
declare -A PENDING_VERSIONS=()

shopt -s nullglob
module_dirs=()
for known_dir in /lib/modules/*/updates/cmpunlocker*; do
    [[ -d "${known_dir}" ]] || \
        die "Refusing ambiguous cmpunlocker-prefixed path ${known_dir}"
    known_name="$(basename "${known_dir}")"
    if [[ "${known_name}" != "cmpunlocker" && \
          ! "${known_name}" =~ ^cmpunlocker\.(new|rollback|remove)\.[0-9]+$ ]]; then
        die "Refusing ambiguous module directory ${known_dir}"
    fi
    [[ -f "${known_dir}/nvidia.ko" ]] && \
        grep -aFq 'cmpunlocker-safety-' "${known_dir}/nvidia.ko" || \
        die "Refusing unrecognized or corrupt cmpunlocker module directory ${known_dir}"
    [[ -s "${known_dir}/driver_version" ]] || \
        die "Refusing cmpunlocker module directory without driver-version recovery metadata: ${known_dir}"
    known_version="$(tr -d '[:space:]' < "${known_dir}/driver_version")"
    [[ "${known_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "Invalid driver-version recovery metadata in ${known_dir}"
    module_dirs+=("${known_dir}")
done
pending_quarantine_dirs=()
for pending_dir in /lib/modules/.cmpunlocker-remove-*; do
    [[ -d "${pending_dir}" ]] || continue
    pending_name="$(basename "${pending_dir}")"
    pending_suffix="${pending_name##*-}"
    pending_kernel="${pending_name#.cmpunlocker-remove-}"
    pending_kernel="${pending_kernel%-*}"
    if [[ ! "${pending_suffix}" =~ ^[0-9]+\.[0-9]+$ || \
          ! -d "/lib/modules/${pending_kernel}" || \
          ! -s "${pending_dir}/driver_version" || \
          ! -f "${pending_dir}/nvidia.ko" ]] || \
       ! grep -aFq 'cmpunlocker-safety-' "${pending_dir}/nvidia.ko"; then
        warn "Preserving unrecognized out-of-tree directory ${pending_dir}"
        continue
    fi
    pending_version="$(tr -d '[:space:]' < "${pending_dir}/driver_version")"
    [[ "${pending_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "Interrupted-removal quarantine has invalid version metadata: ${pending_dir}"
    if [[ -n "${PENDING_VERSIONS[${pending_kernel}]-}" && \
          "${PENDING_VERSIONS[${pending_kernel}]}" != "${pending_version}" ]]; then
        die "Conflicting interrupted-removal versions exist for kernel ${pending_kernel}"
    fi
    PENDING_VERSIONS["${pending_kernel}"]="${pending_version}"
    pending_quarantine_dirs+=("${pending_dir}")
    AFFECTED_KERNELS["${pending_kernel}"]=1
    warn "Found interrupted removal for ${pending_kernel}; will safely complete stock initramfs recovery"
done
shopt -u nullglob

for mod_dir in "${module_dirs[@]}"; do
    [[ -d "${mod_dir}" ]] || continue
    kernel="$(basename "$(dirname "$(dirname "${mod_dir}")")")"
    AFFECTED_KERNELS["${kernel}"]=1
done

# An interrupted older removal may have lost the exact overlay directory while
# modules.dep still points at it.  Such kernels must also be refreshed.
for dep_file in /lib/modules/*/modules.dep; do
    [[ -f "${dep_file}" ]] || continue
    if grep -Fq 'updates/cmpunlocker' "${dep_file}"; then
        kernel="$(basename "$(dirname "${dep_file}")")"
        AFFECTED_KERNELS["${kernel}"]=1
    fi
done

# The Gen2 module options are global, but the installer embeds them only in the
# running kernel's initramfs.  Treat a helper-only residue as an affected kernel
# so removing the file cannot leave those options in the next boot image.
if [[ -e "${MODPROBE_OPTIONS_FILE}" || -L "${MODPROBE_OPTIONS_FILE}" ]]; then
    running_kernel="$(uname -r)"
    [[ -d "/lib/modules/${running_kernel}" ]] || \
        die "Cannot refresh Gen2 module options: missing module tree for ${running_kernel}"
    AFFECTED_KERNELS["${running_kernel}"]=1
fi

mapfile -t kernels_touched < <(printf '%s\n' "${!AFFECTED_KERNELS[@]}" | sed '/^$/d' | sort -V)

select_stock_module_set() {
    local kernel="$1" expected_version="$2"
    local core_candidate candidate_root candidate_path candidate_vermagic
    local candidate_version current_version marker_rc valid i found=0
    local -a matches=() selected_paths=() selected_hashes=()

    while IFS= read -r core_candidate; do
        candidate_root="$(dirname "${core_candidate}")"
        selected_paths=()
        selected_hashes=()
        candidate_version=""
        valid=1

        for i in "${!MODULE_FILES[@]}"; do
            mapfile -t matches < <(find "${candidate_root}" -maxdepth 1 -type f \
                \( -name "${MODULE_FILES[$i]}" \
                   -o -name "${MODULE_FILES[$i]}.gz" \
                   -o -name "${MODULE_FILES[$i]}.xz" \
                   -o -name "${MODULE_FILES[$i]}.zst" \) \
                -print 2>/dev/null | sort)
            if [[ ${#matches[@]} -ne 1 ]]; then
                valid=0
                break
            fi
            candidate_path="$(readlink -e -- "${matches[0]}" 2>/dev/null || true)"
            candidate_vermagic="$(modinfo -F vermagic "${candidate_path}" 2>/dev/null || true)"
            current_version="$(modinfo -F version "${candidate_path}" 2>/dev/null || true)"
            if [[ -z "${candidate_path}" || "${candidate_vermagic%% *}" != "${kernel}" || \
                  -z "${current_version}" ]]; then
                valid=0
                break
            fi
            if [[ -z "${candidate_version}" ]]; then
                candidate_version="${current_version}"
            elif [[ "${current_version}" != "${candidate_version}" ]]; then
                valid=0
                break
            fi
            marker_rc=0
            module_contains_cmp_marker "${candidate_path}" || marker_rc=$?
            if (( marker_rc != 1 )); then
                # rc=0 means patched; rc=2 means the compressed module could
                # not be inspected.  Both are unsafe rollback candidates.
                valid=0
                break
            fi
            selected_paths+=("${candidate_path}")
            selected_hashes+=("$(sha256sum "${candidate_path}" | awk '{print $1}')")
        done

        (( valid == 1 )) || continue
        [[ -z "${expected_version}" || "${candidate_version}" == "${expected_version}" ]] || continue
        if (( found == 1 )) && [[ "${candidate_version}" != "${STOCK_VERSIONS[${kernel}]}" ]]; then
            continue
        fi
        for i in "${!MODULE_NAMES[@]}"; do
            STOCK_HASHES["${kernel}:${selected_paths[$i]}"]="${selected_hashes[$i]}"
        done
        STOCK_VERSIONS["${kernel}"]="${candidate_version}"
        found=1
    done < <(find "/lib/modules/${kernel}" -type f \
        \( -name 'nvidia.ko' -o -name 'nvidia.ko.gz' \
           -o -name 'nvidia.ko.xz' -o -name 'nvidia.ko.zst' \) \
        ! -path '*/updates/cmpunlocker*/*' -print 2>/dev/null | sort)
    (( found == 1 ))
}

for kernel in "${kernels_touched[@]}"; do
    expected_version=""
    overlay_dir="/lib/modules/${kernel}/updates/cmpunlocker"
    if [[ -s "${overlay_dir}/driver_version" ]]; then
        expected_version="$(tr -d '[:space:]' < "${overlay_dir}/driver_version")"
    elif [[ -f "${overlay_dir}/nvidia.ko" ]]; then
        expected_version="$(modinfo -F version "${overlay_dir}/nvidia.ko" 2>/dev/null || true)"
    elif [[ -n "${PENDING_VERSIONS[${kernel}]-}" ]]; then
        expected_version="${PENDING_VERSIONS[${kernel}]}"
    fi
    select_stock_module_set "${kernel}" "${expected_version}" || \
        die "Cannot remove cmpunlocker for ${kernel}: no coherent, unpatched NVIDIA open-module set is available"
    info "Kernel ${kernel} rollback set: NVIDIA ${STOCK_VERSIONS[${kernel}]}"

    firmware_path="/lib/firmware/nvidia/${STOCK_VERSIONS[${kernel}]}/gsp_tu10x.bin"
    [[ -f "${firmware_path}" && ! -L "${firmware_path}" ]] || \
        die "Cannot remove cmpunlocker for ${kernel}: matching stock GSP firmware is missing"
    firmware_version="$(readelf -p .fwversion "${firmware_path}" 2>/dev/null | \
        awk '/\[[[:space:]]*0\]/{print $NF; exit}')"
    firmware_signature_size="$(readelf -SW "${firmware_path}" 2>/dev/null | \
        awk '$3 == ".fwsignature_ga100" {print tolower($7)}')"
    firmware_signature_count="$(readelf -SW "${firmware_path}" 2>/dev/null | \
        awk '$3 == ".fwsignature_ga100" {count++} END {print count + 0}')"
    [[ "${firmware_version}" == "${STOCK_VERSIONS[${kernel}]}" && \
       "${firmware_signature_count}" -eq 1 && \
       "${firmware_signature_size}" == "001000" ]] || \
        die "Live ${firmware_path} is not provably stock; preserve any .cmpunlocker.bak and restore firmware offline before removing the overlay"
done

if [[ ${#kernels_touched[@]} -gt 0 ]] && \
   ! command -v update-initramfs &>/dev/null && \
   ! command -v dracut &>/dev/null && \
   ! command -v mkinitcpio &>/dev/null; then
    die "Cannot remove cmpunlocker: no supported initramfs rebuild tool is installed"
fi
ok "Stock module set and initramfs rollback path are available"

step "Removing patched modules and legacy files"
mod_removed=0
original_module_dirs=()
quarantine_module_dirs=()
REMOVE_STATE="$(mktemp -d /var/tmp/cmpunlocker-remove.XXXXXX)" || \
    die "Could not create removal transaction state"
had_depmod_override=0
had_modprobe_options=0
remove_transaction_active=0

rebuild_touched_initramfs() {
    if command -v update-initramfs &>/dev/null; then
        for kernel in "${kernels_touched[@]}"; do
            update-initramfs -u -k "${kernel}" || return 1
        done
    elif command -v dracut &>/dev/null; then
        for kernel in "${kernels_touched[@]}"; do
            dracut --force --kver "${kernel}" || return 1
        done
    elif command -v mkinitcpio &>/dev/null; then
        mkinitcpio -P || return 1
    else
        return 1
    fi
}

rollback_remove_transaction() {
    local rollback_rc=0 i
    set +e
    warn "Removal did not complete; restoring the cmpunlocker overlay"
    for i in "${!original_module_dirs[@]}"; do
        if [[ -d "${quarantine_module_dirs[$i]}" ]]; then
            if [[ -e "${original_module_dirs[$i]}" ]]; then
                rollback_rc=1
            else
                mv -- "${quarantine_module_dirs[$i]}" \
                    "${original_module_dirs[$i]}" || rollback_rc=1
            fi
        fi
    done
    if (( had_depmod_override == 1 )); then
        install -m 0644 "${REMOVE_STATE}/depmod.conf" \
            /etc/depmod.d/cmpunlocker.conf || rollback_rc=1
    else
        rm -f /etc/depmod.d/cmpunlocker.conf || rollback_rc=1
    fi
    if (( had_modprobe_options == 1 )); then
        install -m 0644 "${REMOVE_STATE}/modprobe.conf" \
            "${MODPROBE_OPTIONS_FILE}" || rollback_rc=1
    else
        rm -f -- "${MODPROBE_OPTIONS_FILE}" || rollback_rc=1
    fi
    for kernel in "${kernels_touched[@]}"; do
        depmod -a "${kernel}" || rollback_rc=1
    done
    rebuild_touched_initramfs || rollback_rc=1
    if (( rollback_rc == 0 )); then
        warn "cmpunlocker on-disk module selection was restored"
    else
        warn "Automatic removal rollback was incomplete"
    fi
    set -e
    return "${rollback_rc}"
}

finish_remove_transaction() {
    local rc=$?
    local rollback_succeeded=1
    trap - EXIT INT TERM
    if (( remove_transaction_active == 1 )); then
        if ! rollback_remove_transaction; then
            rollback_succeeded=0
        fi
    fi
    if (( remove_transaction_active == 0 || rollback_succeeded == 1 )); then
        rm -rf -- "${REMOVE_STATE}"
    else
        warn "Preserved removal recovery state: ${REMOVE_STATE}"
    fi
    exit "${rc}"
}
trap finish_remove_transaction EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e /etc/depmod.d/cmpunlocker.conf ]]; then
    cp -a /etc/depmod.d/cmpunlocker.conf "${REMOVE_STATE}/depmod.conf"
    had_depmod_override=1
fi
if [[ -e "${MODPROBE_OPTIONS_FILE}" || -L "${MODPROBE_OPTIONS_FILE}" ]]; then
    [[ -f "${MODPROBE_OPTIONS_FILE}" && ! -L "${MODPROBE_OPTIONS_FILE}" ]] || \
        die "Refusing unsafe Gen2 modprobe configuration path ${MODPROBE_OPTIONS_FILE}"
    cp -a -- "${MODPROBE_OPTIONS_FILE}" "${REMOVE_STATE}/modprobe.conf"
    had_modprobe_options=1
fi
remove_transaction_active=1
rm -f /etc/depmod.d/cmpunlocker.conf
ok "Removed cmpunlocker depmod override inside the rollback transaction"
rm -f -- "${MODPROBE_OPTIONS_FILE}"
ok "Removed cmpunlocker Gen2 module options before rebuilding initramfs"

module_dir_index=0
for mod_dir in "${module_dirs[@]}"; do
    [[ -d "${mod_dir}" ]] || continue
    kernel="$(basename "$(dirname "$(dirname "${mod_dir}")")")"
    quarantine="/lib/modules/.cmpunlocker-remove-${kernel}-${module_dir_index}.$$"
    [[ ! -e "${quarantine}" ]] || die "Removal quarantine already exists: ${quarantine}"
    original_module_dirs+=("${mod_dir}")
    quarantine_module_dirs+=("${quarantine}")
    mv -- "${mod_dir}" "${quarantine}"
    ok "Quarantined patched modules for kernel ${kernel}"
    mod_removed=$((mod_removed + 1))
    module_dir_index=$((module_dir_index + 1))
done
[[ "${mod_removed}" -gt 0 ]] || warn "No patched kernel modules found"

if [[ ${#kernels_touched[@]} -gt 0 ]]; then
    for kernel in "${kernels_touched[@]}"; do
        depmod -a "${kernel}" || \
            die "depmod failed for kernel ${kernel} after quarantining patched modules"
    done
    for kernel in "${kernels_touched[@]}"; do
        resolved_root=""
        for module_name in "${MODULE_NAMES[@]}"; do
            stock_module_path="$(modinfo -k "${kernel}" -n "${module_name}" 2>/dev/null || true)"
            stock_module_path="$(readlink -e -- "${stock_module_path}" 2>/dev/null || true)"
            expected_stock_hash="${STOCK_HASHES[${kernel}:${stock_module_path}]-}"
            [[ -f "${stock_module_path}" && -n "${expected_stock_hash}" ]] || \
                die "Kernel ${kernel} did not resolve ${module_name} to any preflighted stock set"
            [[ "$(sha256sum "${stock_module_path}" | awk '{print $1}')" == "${expected_stock_hash}" ]] || \
                die "Stock ${module_name} changed during the removal transaction"
            resolved_vermagic="$(modinfo -F vermagic "${stock_module_path}" 2>/dev/null || true)"
            resolved_version="$(modinfo -F version "${stock_module_path}" 2>/dev/null || true)"
            [[ "${resolved_vermagic%% *}" == "${kernel}" && \
               "${resolved_version}" == "${STOCK_VERSIONS[${kernel}]}" ]] || \
                die "Resolved ${module_name} failed the stock version/vermagic proof"
            marker_rc=0
            module_contains_cmp_marker "${stock_module_path}" || marker_rc=$?
            (( marker_rc == 1 )) || \
                die "Resolved ${module_name} is patched or could not be inspected"
            if [[ -z "${resolved_root}" ]]; then
                resolved_root="$(dirname "${stock_module_path}")"
            elif [[ "$(dirname "${stock_module_path}")" != "${resolved_root}" ]]; then
                die "Resolved stock modules for ${kernel} do not come from one coherent directory"
            fi
        done
        ok "Kernel ${kernel} resolves all five NVIDIA modules to stock paths"
    done
    info "Rebuilding initramfs only after the stock module selection has been proven..."
    rebuild_touched_initramfs || \
        die "Initramfs rebuild failed; restoring the cmpunlocker overlay"
    ok "Rebuilt initramfs with the verified stock module selection"
fi

remove_transaction_active=0
for quarantine in "${quarantine_module_dirs[@]}"; do
    if ! rm -rf -- "${quarantine}"; then
        warn "Could not remove safe out-of-tree quarantine ${quarantine}; it will not be scanned by depmod"
    fi
done
for quarantine in "${pending_quarantine_dirs[@]}"; do
    if ! rm -rf -- "${quarantine}"; then
        warn "Could not remove completed recovery quarantine ${quarantine}; it remains outside depmod's kernel tree"
    fi
done
rm -rf -- "${REMOVE_STATE}"
trap - EXIT INT TERM
ok "Committed patched-module removal after stock depmod/initramfs verification"

step "Stopping cmpunlocker service and PCIe/IOMMU helpers"
service_was_active=0
service_state_rc=0
systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null || service_state_rc=$?
case "${service_state_rc}" in
    0)
        service_was_active=1
        systemctl stop "${SERVICE_NAME}" || die "Could not stop ${SERVICE_NAME} service"
        ;;
    3|4)
        ;;
    *)
        die "Could not determine whether ${SERVICE_NAME} service is active"
        ;;
esac
service_state_rc=0
systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null || service_state_rc=$?
if (( service_state_rc == 0 )); then
    die "${SERVICE_NAME} service is still active after the stop request"
elif (( service_state_rc != 3 && service_state_rc != 4 )); then
    die "Could not verify that ${SERVICE_NAME} service stopped"
elif (( service_was_active == 1 )); then
    ok "Service stopped"
else
    warn "Service not running"
fi
if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}" || true
    ok "Service disabled"
fi
if [[ -f "${SERVICE_FILE}" ]]; then
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    ok "Removed ${SERVICE_FILE}"
fi
watchdog_stop_rc=0
pkill -f -- "${INSTALL_DIR}/daemon/watchdog.py" 2>/dev/null || watchdog_stop_rc=$?
(( watchdog_stop_rc == 0 || watchdog_stop_rc == 1 )) || \
    die "Could not stop the legacy cmpunlocker watchdog"
watchdog_check_rc=0
pgrep -f -- "${INSTALL_DIR}/daemon/watchdog.py" >/dev/null 2>&1 || watchdog_check_rc=$?
if (( watchdog_check_rc == 0 )); then
    die "Legacy cmpunlocker watchdog is still running"
elif (( watchdog_check_rc != 1 )); then
    die "Could not verify that the legacy cmpunlocker watchdog stopped"
fi
ok "Legacy watchdog is not running"

info "Removing PCIe Gen2 helpers"
for legacy_unit in cmpretrain.service cmp-gen2-retrain.service; do
    systemctl disable --now "${legacy_unit}" 2>/dev/null || true
    systemctl reset-failed "${legacy_unit}" 2>/dev/null || true
done
rm -f /etc/systemd/system/cmpretrain.service
if [[ -f /usr/local/sbin/retrain.sh ]] && \
   grep -Fq 'GPU, UP = "0a:00.0", "09:01.0"' /usr/local/sbin/retrain.sh; then
    rm -f /usr/local/sbin/retrain.sh
fi
rm -f /etc/systemd/system/cmp-gen2-retrain.service /usr/local/sbin/cmp-gen2-retrain.sh
systemctl disable --now cmpunlocker-gen2.service 2>/dev/null || true
systemctl reset-failed cmpunlocker-gen2.service 2>/dev/null || true
rm -f /etc/systemd/system/cmpunlocker-gen2.service \
      /usr/local/sbin/cmpunlocker-gen2-hammer
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
systemctl daemon-reload 2>/dev/null || true
ok "Removed PCIe Gen2 helpers"

info "Restoring IOMMU kernel command line"
iommu_restored=0
grub_restored=0
kernel_cmdline_restored=0
grub_generator_spec=""
for cfg in /etc/default/grub /etc/kernel/cmdline; do
    backup="${cfg}.cmpunlocker.bak"
    receipt="${cfg}.cmpunlocker.installed.sha256"
    backup_receipt="${cfg}.cmpunlocker.backup.sha256"
    [[ -f "${backup}" ]] || continue
    if [[ ! -s "${receipt}" || ! -s "${backup_receipt}" ]]; then
        warn "Preserving legacy IOMMU backup ${backup}: complete install/backup receipts are missing"
        continue
    fi
    installed_hash="$(tr -d '[:space:]' < "${receipt}")"
    recorded_backup_hash="$(tr -d '[:space:]' < "${backup_receipt}")"
    if [[ ! -f "${cfg}" || ! -r "${cfg}" ]]; then
        warn "Preserving ${backup}: live boot config ${cfg} is missing or unreadable"
        continue
    fi
    if ! current_hash="$(sha256sum -- "${cfg}" 2>/dev/null | awk '{print $1}')"; then
        warn "Preserving ${backup}: live boot config ${cfg} could not be hashed"
        continue
    fi
    if ! backup_hash="$(sha256sum -- "${backup}" 2>/dev/null | awk '{print $1}')"; then
        warn "Preserving ${backup}: recovery backup could not be hashed"
        continue
    fi
    if [[ ! "${installed_hash}" =~ ^[0-9a-f]{64}$ || \
          ! "${recorded_backup_hash}" =~ ^[0-9a-f]{64}$ || \
          "${backup_hash}" != "${recorded_backup_hash}" ]]; then
        warn "Preserving ${backup}: its recovery hash receipt is invalid or no longer matches"
        continue
    fi
    if [[ "${current_hash}" != "${installed_hash}" && "${current_hash}" != "${backup_hash}" ]]; then
        warn "Preserving ${backup}: ${cfg} was modified after cmpunlocker installation"
        continue
    fi
    if [[ "${cfg}" == "/etc/default/grub" ]]; then
        generator_receipt="${cfg}.cmpunlocker.generator"
        [[ -s "${generator_receipt}" ]] || {
            warn "Preserving ${backup}: the original GRUB generator target is unknown"
            continue
        }
        grub_generator_spec="$(tr -d '\n' < "${generator_receipt}")"
        case "${grub_generator_spec}" in
            update-grub)
                command -v update-grub &>/dev/null || {
                    warn "Preserving ${backup}: update-grub is unavailable"
                    continue
                }
                ;;
            grub2-mkconfig:/boot/grub2/grub.cfg)
                command -v grub2-mkconfig &>/dev/null || {
                    warn "Preserving ${backup}: grub2-mkconfig is unavailable"
                    continue
                }
                ;;
            grub-mkconfig:/boot/grub/grub.cfg)
                command -v grub-mkconfig &>/dev/null || {
                    warn "Preserving ${backup}: grub-mkconfig is unavailable"
                    continue
                }
                ;;
            *)
                warn "Preserving ${backup}: unsafe or manual GRUB generator receipt '${grub_generator_spec}'"
                continue
                ;;
        esac
        grub_restored=1
    else
        if ! command -v kernel-install &>/dev/null || [[ ! -d /boot/loader/entries ]]; then
            warn "Preserving ${backup}: systemd-boot entries cannot be refreshed automatically"
            continue
        fi
        kernel_cmdline_restored=1
    fi
    if [[ "${current_hash}" != "${backup_hash}" ]]; then
        restore_tmp="${cfg}.cmpunlocker.restore.$$"
        rm -f -- "${restore_tmp}"
        cp -a -- "${backup}" "${restore_tmp}"
        mv -f -- "${restore_tmp}" "${cfg}"
    fi
    ok "Restored ${cfg} from its verified pre-install backup"
    iommu_restored=1
done
if (( grub_restored )); then
    case "${grub_generator_spec}" in
        update-grub)
            update-grub || die "update-grub failed after restoring the kernel command line"
            ;;
        grub2-mkconfig:*)
            grub_target="${grub_generator_spec#grub2-mkconfig:}"
            grub2-mkconfig -o "${grub_target}" || \
                die "grub2-mkconfig failed after restoring the kernel command line"
            ;;
        grub-mkconfig:*)
            grub_target="${grub_generator_spec#grub-mkconfig:}"
            grub-mkconfig -o "${grub_target}" || \
                die "grub-mkconfig failed after restoring the kernel command line"
            ;;
    esac
    rm -f /etc/default/grub.cmpunlocker.bak \
          /etc/default/grub.cmpunlocker.installed.sha256 \
          /etc/default/grub.cmpunlocker.backup.sha256 \
          /etc/default/grub.cmpunlocker.generator
fi
if (( kernel_cmdline_restored )); then
    for kdir in /lib/modules/*/; do
        kver="$(basename "${kdir}")"
        [[ -f "${kdir}/vmlinuz" ]] || continue
        kernel-install add "${kver}" "${kdir}/vmlinuz" || \
            die "kernel-install failed while refreshing ${kver}"
    done
    rm -f /etc/kernel/cmdline.cmpunlocker.bak \
          /etc/kernel/cmdline.cmpunlocker.installed.sha256 \
          /etc/kernel/cmdline.cmpunlocker.backup.sha256
fi
if (( iommu_restored )); then
    ok "Reverted verified cmpunlocker IOMMU changes (effective after power-on)"
else
    warn "No safely restorable IOMMU configuration was found; kernel command line left unchanged"
fi

# Current releases never replace GSP firmware.  Historical backup artifacts
# may be the only stock copy after an interrupted legacy install, so preserve
# them for explicit inspection/recovery rather than deleting them blindly.
if compgen -G '/lib/firmware/nvidia/*/gsp_tu10x.bin.cmpunlocker*' >/dev/null; then
    warn "Preserved historical GSP firmware backup artifacts under /lib/firmware/nvidia"
fi

if [[ -d "${INSTALL_DIR}" ]]; then
    warn "Preserved legacy ${INSTALL_DIR}; remove it manually after confirming it contains only cmpunlocker files"
else
    warn "${INSTALL_DIR} not found (ok for module-only installs)"
fi

step "Preserving the running driver until power-off"
if lsmod | grep -q '^nvidia'; then
    warn "NVIDIA modules remain loaded; hot replacement is unsafe after changing FB/WPR geometry"
else
    info "No running NVIDIA modules need to be preserved"
fi

step "Done"
banner
echo "cmpunlocker has been removed from system."
echo "Log saved to: ${LOG_FILE}"
echo ""
echo "A complete power-off/power-on transition is required before stock modules may load:"
echo -e "  ${CYAN}sudo shutdown -h now${NC}"
echo "After shutdown, remove standby power long enough for the GPU to lose state, then power on."
echo ""
