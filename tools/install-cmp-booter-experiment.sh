#!/bin/bash
set -euo pipefail

VERSION=615.78.08
LEGACY_VERSION=610.57.04
KVER="$(uname -r)"
MODULE_DIR="/lib/modules/${KVER}/updates/cmpunlocker"
DEPMOD_CONFIG=/etc/depmod.d/cmpunlocker.conf
INITRAMFS=/boot/initramfs-linux.img
BACKUP_ROOT=/var/lib/cmpunlocker
MODULES=(nvidia nvidia-modeset nvidia-uvm nvidia-drm nvidia-peermem)
FILES=(nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko
       driver_version kernel_version cmp_privilege_booter)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage:
  install-cmp-booter-experiment.sh [--check] BUILD_DIR
  sudo install-cmp-booter-experiment.sh --install BUILD_DIR
  sudo install-cmp-booter-experiment.sh --rollback TRANSACTION_DIR

--check is the default and changes nothing. BUILD_DIR is printed by
build-cmp-booter-experiment.sh. Installation updates modules on disk and the
linux initramfs; it never reloads modules, starts services, or reboots.
EOF
}

mode=--check
case "${1:-}" in
    --check|--install|--rollback) mode="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
esac
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
if [[ "${mode}" != --check ]]; then
    [[ "${EUID}" -eq 0 ]] || die "${mode} requires root"
fi
for command_name in sha256sum modinfo readlink grep cp mv rm mkdir mktemp chmod install flock depmod mkinitcpio; do
    command -v "${command_name}" >/dev/null || die "Missing command: ${command_name}"
done

verify_bundle() {
    local bundle="$1" digest name extra actual file
    local -A expected=() known=()
    for file in "${FILES[@]}"; do
        known["${file}"]=1
        [[ -f "${bundle}/${file}" && ! -L "${bundle}/${file}" ]] || die "Missing regular file: ${bundle}/${file}"
    done
    [[ -f "${bundle}/SHA256SUMS" && ! -L "${bundle}/SHA256SUMS" ]] || die "Missing checksum manifest"
    while read -r digest name extra; do
        name="${name#./}"
        [[ "${digest}" =~ ^[0-9a-f]{64}$ && -z "${extra}" ]] || die "Malformed checksum manifest"
        case "${name}" in
            nvidia.ko|nvidia-modeset.ko|nvidia-uvm.ko|nvidia-drm.ko|nvidia-peermem.ko|driver_version|kernel_version|cmp_privilege_booter) ;;
            *) die "Unexpected checksum entry: ${name}" ;;
        esac
        [[ -n "${known[${name}]:-}" && -z "${expected[${name}]:-}" ]] || die "Unexpected or duplicate checksum entry: ${name}"
        expected["${name}"]="${digest}"
    done < "${bundle}/SHA256SUMS"
    [[ ${#expected[@]} -eq ${#FILES[@]} ]] || die "Incomplete checksum manifest"
    for file in "${FILES[@]}"; do
        actual="$(sha256sum -- "${bundle}/${file}")"
        [[ "${actual%% *}" == "${expected[${file}]}" ]] || die "Checksum mismatch: ${file}"
    done
    [[ "$(<"${bundle}/driver_version")" == "${VERSION}" ]] || die "Bundle must use NVIDIA ${VERSION}"
    [[ "$(<"${bundle}/kernel_version")" == "${KVER}" ]] || die "Bundle kernel does not match ${KVER}"
    [[ "$(<"${bundle}/cmp_privilege_booter")" == "${LEGACY_VERSION}" ]] || die "Unexpected privilege Booter version"
    for file in "${MODULES[@]}"; do
        [[ "$(modinfo -F version "${bundle}/${file}.ko")" == "${VERSION}" ]] || die "Wrong module version: ${file}"
        [[ "$(modinfo -F vermagic "${bundle}/${file}.ko")" == "${KVER} "* ]] || die "Wrong module kernel: ${file}"
    done
    grep -aFq 'CMP_BOOTER_COMPAT' "${bundle}/nvidia.ko" || die "nvidia.ko does not contain the Booter experiment"
}

verify_host() {
    local nvml device vendor pci count=0
    nvml="$(readlink -e /usr/lib/libnvidia-ml.so.1)" || die "Installed NVML is missing"
    [[ "${nvml##*/}" == "libnvidia-ml.so.${VERSION}" ]] || die "Installed NVML must match ${VERSION}"
    [[ "$(cat "/lib/modules/${KVER}/pkgbase" 2>/dev/null)" == linux ]] || die "This installer only supports the running Arch linux package"
    [[ -f /etc/mkinitcpio.d/linux.preset && -f "${INITRAMFS}" ]] || die "Expected linux initramfs/preset is missing"
    for pci in /sys/bus/pci/devices/*; do
        vendor="$(<"${pci}/vendor")"
        [[ "${vendor}" == 0x10de ]] || continue
        device="$(<"${pci}/device")"
        [[ "${device}" != 0x2082 ]] || die "The experiment has not been qualified for 10GB/2082 cards"
        if [[ "${device}" == 0x20c2 ]]; then count=$((count + 1)); fi
    done
    [[ "${count}" -eq 1 ]] || die "Expected exactly one NVIDIA 20c2 CMP card, found ${count}"
}

verify_resolution() {
    local name resolved expected
    for name in "${MODULES[@]}"; do
        resolved="$(modinfo -k "${KVER}" -n "${name}")" || return 1
        resolved="$(readlink -e -- "${resolved}")" || return 1
        expected="$(readlink -e -- "${MODULE_DIR}/${name}.ko")" || return 1
        [[ "${resolved}" == "${expected}" ]] || { printf '%s resolves to %s\n' "${name}" "${resolved}" >&2; return 1; }
    done
}

restore_snapshot() {
    local transaction="$1" restore_stage result=0
    printf 'Restoring snapshot: %s\n' "${transaction}"
    if [[ "$(<"${transaction}/previous_modules")" == present ]]; then
        restore_stage="$(mktemp -d /lib/modules/.cmp-booter-restore.XXXXXX)" || return 1
        if ! cp -a "${transaction}/previous-modules/." "${restore_stage}/"; then
            rm -rf -- "${restore_stage}"
            return 1
        fi
        rm -rf -- "${MODULE_DIR}" || { rm -rf -- "${restore_stage}"; return 1; }
        mv -- "${restore_stage}" "${MODULE_DIR}" || return 1
    else
        rm -rf -- "${MODULE_DIR}" || return 1
    fi
    if [[ "$(<"${transaction}/previous_depmod")" == present ]]; then
        install -m 0644 "${transaction}/previous-depmod.conf" "${DEPMOD_CONFIG}" || result=1
    else
        rm -f -- "${DEPMOD_CONFIG}" || result=1
    fi
    depmod -a "${KVER}" || result=1
    if ! mkinitcpio -p linux; then
        printf 'Initramfs regeneration failed; restoring the saved image.\n' >&2
        cp -a -- "${transaction}/previous-initramfs-linux.img" "${INITRAMFS}" || result=1
    fi
    return "${result}"
}

if [[ "${mode}" == --rollback ]]; then
    transaction="$(readlink -e -- "$1")" || die "Transaction not found"
    [[ "${transaction}" == "${BACKUP_ROOT}/booter-experiment."* && -d "${transaction}" ]] || die "Unexpected transaction directory"
    [[ -O "${transaction}" && ! -L "$1" ]] || die "Rollback requires a root-owned transaction directory"
    [[ -f "${transaction}/ready" && "$(<"${transaction}/kernel_version")" == "${KVER}" ]] || die "Incomplete transaction or different kernel"
    verify_host
    exec 9>/run/lock/cmpunlocker.lock
    flock -n 9 || die "Another cmpunlocker operation is running"
    restore_snapshot "${transaction}" || die "Rollback incomplete; keep ${transaction} for recovery"
    printf 'Rollback complete on disk. A full power-off/power-on transition is required.\n'
    exit 0
fi

build="$(readlink -e -- "$1")" || die "Build directory not found"
bundle="${build}/modules"
verify_bundle "${bundle}"
verify_host
printf 'Verified experiment: NVIDIA %s; kernel %s; CMP privilege Booter %s\n' "${VERSION}" "${KVER}" "${LEGACY_VERSION}"
printf 'Module destination: %s\nDepmod configuration: %s\nInitramfs: %s\n' "${MODULE_DIR}" "${DEPMOD_CONFIG}" "${INITRAMFS}"
if [[ "${mode}" == --check ]]; then
    printf 'Check passed. No files or live GPU state changed.\n'
    exit 0
fi

umask 077
exec 9>/run/lock/cmpunlocker.lock
flock -n 9 || die "Another cmpunlocker operation is running"
mkdir -p "${BACKUP_ROOT}" "$(dirname "${MODULE_DIR}")" /etc/depmod.d
transaction="$(mktemp -d "${BACKUP_ROOT}/booter-experiment.XXXXXX")"
printf '%s\n' "${KVER}" > "${transaction}/kernel_version"
if [[ -d "${MODULE_DIR}" && ! -L "${MODULE_DIR}" ]]; then
    cp -a "${MODULE_DIR}" "${transaction}/previous-modules"
    printf 'present\n' > "${transaction}/previous_modules"
elif [[ -e "${MODULE_DIR}" || -L "${MODULE_DIR}" ]]; then
    die "Module destination is not a regular directory"
else
    printf 'absent\n' > "${transaction}/previous_modules"
fi
if [[ -e "${DEPMOD_CONFIG}" ]]; then
    cp -aL "${DEPMOD_CONFIG}" "${transaction}/previous-depmod.conf"
    printf 'present\n' > "${transaction}/previous_depmod"
else
    printf 'absent\n' > "${transaction}/previous_depmod"
fi
cp -a "${INITRAMFS}" "${transaction}/previous-initramfs-linux.img"
touch "${transaction}/ready"

stage="$(mktemp -d /lib/modules/.cmp-booter-stage.XXXXXX)"
old_move="${stage}.old"
changed=0
complete=0
finish() {
    local rc=$?
    trap - EXIT INT TERM
    if (( changed == 1 && complete == 0 )); then
        if ! restore_snapshot "${transaction}"; then
            printf 'Automatic rollback incomplete; recovery snapshot: %s\n' "${transaction}" >&2
        fi
    fi
    rm -rf -- "${stage}" "${old_move}"
    exit "${rc}"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -d "${MODULE_DIR}" ]]; then cp -a "${MODULE_DIR}/." "${stage}/"; fi
chmod 0755 "${stage}"
for file in "${FILES[@]}" SHA256SUMS; do
    install -m 0644 "${bundle}/${file}" "${stage}/${file}"
done
verify_bundle "${stage}"
printf '%s\n' \
    'override nvidia * updates/cmpunlocker' \
    'override nvidia-modeset * updates/cmpunlocker' \
    'override nvidia-uvm * updates/cmpunlocker' \
    'override nvidia-drm * updates/cmpunlocker' \
    'override nvidia-peermem * updates/cmpunlocker' > "${transaction}/experiment-depmod.conf"

changed=1
if [[ -d "${MODULE_DIR}" ]]; then mv -- "${MODULE_DIR}" "${old_move}"; fi
mv -- "${stage}" "${MODULE_DIR}"
install -m 0644 "${transaction}/experiment-depmod.conf" "${DEPMOD_CONFIG}"
depmod -a "${KVER}"
verify_resolution || die "Experimental module selection failed"
mkinitcpio -p linux
verify_resolution || die "Experimental module selection changed during initramfs generation"
complete=1
printf 'Installed on disk. Running GPU modules were not reloaded.\n'
printf 'Recovery snapshot: %s\n' "${transaction}"
printf 'Rollback command: sudo bash %q --rollback %q\n' "$0" "${transaction}"
printf 'Activate only with a full power-off/power-on transition.\n'
