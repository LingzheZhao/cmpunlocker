#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cmpunlocker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/cmpunlocker"

source "${SCRIPT_DIR}/common/lib.sh"

banner

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
    warn "This removes cmpunlocker patched kernel modules:"
    echo "  - Stops cmpunlocker systemd service"
    echo "  - Removes /lib/modules/*/updates/cmpunlocker/"
    echo "  - Removes ${INSTALL_DIR} (legacy install dir, if present)"
    echo "  - Leaves running NVIDIA modules untouched until a required cold power-off"
    echo "  - Removes cmpretrain service / modprobe Gen2 and P2P helpers"
    echo "  - Restores the pre-install kernel command line (reverts IOMMU changes)"
    echo ""
    echo "Run: sudo ./remove.sh --yes"
    exit 1
fi

step_init 5

step "Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./remove.sh --yes"
ok "Running as root"

LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="/tmp"
fi
LOG_FILE="${LOG_DIR}/remove_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

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
rm -f /etc/systemd/system/cmpretrain.service /usr/local/sbin/retrain.sh
rm -f /etc/systemd/system/cmp-gen2-retrain.service /usr/local/sbin/cmp-gen2-retrain.sh
rm -f /etc/modprobe.d/cmp-pcie-gen2.conf
systemctl disable --now gen2.service 2>/dev/null || true
systemctl reset-failed gen2.service 2>/dev/null || true
rm -f /etc/systemd/system/gen2.service /usr/local/sbin/gen2-hammer
systemctl daemon-reload 2>/dev/null || true
ok "Removed PCIe Gen2 helpers"

info "Restoring IOMMU kernel command line"
iommu_restored=0
for cfg in /etc/default/grub /etc/kernel/cmdline; do
    if [[ -f "${cfg}.cmpunlocker.bak" ]]; then
        mv -f "${cfg}.cmpunlocker.bak" "${cfg}"
        ok "Restored ${cfg} from pre-install backup"
        iommu_restored=1
    fi
done
if (( iommu_restored )); then
    if command -v update-grub &>/dev/null; then
        update-grub || die "update-grub failed after restoring the kernel command line"
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg || \
            die "grub2-mkconfig failed after restoring the kernel command line"
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg || \
            die "grub-mkconfig failed after restoring the kernel command line"
    else
        die "Kernel command line restored, but no supported bootloader regeneration tool was found; regenerate the bootloader configuration manually before rebooting"
    fi
    ok "Reverted IOMMU kernel parameters (effective after reboot)"
else
    warn "No IOMMU config backup found — kernel command line left as-is"
fi

step "Removing patched modules and legacy files"
mod_removed=0
kernels_touched=()
shopt -s nullglob
for mod_dir in /lib/modules/*/updates/cmpunlocker; do
    if [[ -d "${mod_dir}" ]]; then
        kernel="$(basename "$(dirname "$(dirname "${mod_dir}")")")"
        rm -rf "${mod_dir}"
        depmod -a "${kernel}" || \
            die "depmod failed for kernel ${kernel} after patched modules were removed"
        ok "Removed patched modules for kernel ${kernel}"
        mod_removed=$((mod_removed + 1))
        kernels_touched+=("${kernel}")
    fi
done
[[ "${mod_removed}" -gt 0 ]] || warn "No patched kernel modules found"

if [[ ${#kernels_touched[@]} -gt 0 ]]; then
    info "Rebuilding initramfs so stock modules are packed again..."
    initramfs_manual_recovery="Patched modules are already removed for kernel(s): ${kernels_touched[*]}. Manually rebuild each affected initramfs before rebooting."
    if command -v update-initramfs &>/dev/null; then
        for kernel in "${kernels_touched[@]}"; do
            update-initramfs -u -k "${kernel}" || \
                die "update-initramfs failed for ${kernel}. ${initramfs_manual_recovery}"
        done
    elif command -v dracut &>/dev/null; then
        for kernel in "${kernels_touched[@]}"; do
            dracut --force --kver "${kernel}" || \
                die "dracut failed for ${kernel}. ${initramfs_manual_recovery}"
        done
    elif command -v mkinitcpio &>/dev/null; then
        mkinitcpio -P || die "mkinitcpio failed. ${initramfs_manual_recovery}"
    else
        die "No supported initramfs rebuild tool was found. ${initramfs_manual_recovery}"
    fi
    ok "Rebuilt initramfs with the stock module selection"

    for kernel in "${kernels_touched[@]}"; do
        modprobe_plan="$(modprobe --set-version "${kernel}" -n -v nvidia 2>&1)" || {
            printf '%s\n' "${modprobe_plan}" >&2
            die "Could not resolve the stock nvidia module for kernel ${kernel}"
        }
        printf '%s\n' "${modprobe_plan}"
        [[ "${modprobe_plan}" != *"/updates/cmpunlocker/"* ]] || \
            die "Kernel ${kernel} still resolves nvidia through cmpunlocker"

        stock_module_path=""
        while read -r modprobe_action modprobe_path _; do
            if [[ "${modprobe_action##*/}" == "insmod" && \
                  ( "${modprobe_path}" == "/lib/modules/${kernel}/"* || \
                    "${modprobe_path}" == "/usr/lib/modules/${kernel}/"* ) && \
                  "${modprobe_path}" =~ /nvidia\.ko(\.(gz|xz|zst))?$ ]]; then
                stock_module_path="${modprobe_path}"
                break
            fi
        done <<< "${modprobe_plan}"
        [[ -n "${stock_module_path}" ]] || \
            die "Kernel ${kernel} did not resolve nvidia to a stock module"
        stock_module_path="$(readlink -f -- "${stock_module_path}")" || \
            die "Could not canonicalize the stock nvidia module for kernel ${kernel}"
        [[ -f "${stock_module_path}" && \
           "${stock_module_path}" != *"/updates/cmpunlocker/"* ]] || \
            die "Kernel ${kernel} did not resolve nvidia to an existing non-cmpunlocker module"
        ok "Kernel ${kernel} resolves nvidia to ${stock_module_path}"
    done
fi

for gsp in /lib/firmware/nvidia/*/gsp_tu10x.bin; do
    rm -f \
        "${gsp}.cmpunlocker.bak" \
        "${gsp}.cmpunlocker.patched" \
        "${gsp}.cmpunlocker.tmp" \
        "${gsp}.cmpunlocker.cleanup" \
        "${gsp}.cmpunlocker.pat"
done

if [[ -d "${INSTALL_DIR}" ]]; then
    rm -rf "${INSTALL_DIR}"
    ok "Removed ${INSTALL_DIR}"
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
