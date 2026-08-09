#!/bin/bash
set -euo pipefail

PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH
while IFS= read -r inherited_function; do
    unset -f -- "${inherited_function}" 2>/dev/null || :
done < <(compgen -A function)
unset inherited_function
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH PYTHONSTARTUP \
      PYTHONUSERBASE SYSTEMD_UNIT_PATH SYSTEMD_OFFLINE SYSTEMD_IN_CHROOT \
      KERNEL_INSTALL_CONF_ROOT KERNEL_INSTALL_PLUGINS BOOT_ROOT \
      MKINITCPIO_CONFIG MKINITCPIO_PRESET MKINITCPIO_LIBRARY \
      MKINITCPIO_CONF MKINITCPIO_HOOKS MKINITCPIO_INSTALL \
      MKINITCPIO_POST_HOOKS MKINITCPIO_PRESETS \
      GRUB_CONFIG GRUB_DEFAULT GRUB_DISTRIBUTOR GRUB_DEVICE \
      GRUB_DEVICE_BOOT GRUB_DEVICE_UUID GRUB_DISABLE_OS_PROBER \
      ADDON_MODULES_DIR source_tree dkms_tree install_tree tmp_location \
      symlink_modules post_transaction sign_file mok_signing_key mok_certificate \
      TMPDIR MODULES_SIGN_KEY MODULES_SIGN_CERT

PYTHON_EXECUTABLE="$(/usr/bin/readlink -f -- /usr/bin/python3 2>/dev/null || :)"
[[ -n "${PYTHON_EXECUTABLE}" && -f "${PYTHON_EXECUTABLE}" && \
   ! -L "${PYTHON_EXECUTABLE}" && -x "${PYTHON_EXECUTABLE}" && \
   "$(/usr/bin/stat -c '%u:%g:%h' -- "${PYTHON_EXECUTABLE}" 2>/dev/null)" == "0:0:1" && \
   "$(( 8#$(/usr/bin/stat -c '%a' -- "${PYTHON_EXECUTABLE}" 2>/dev/null) & 8#22 ))" == "0" ]] || {
    echo "Unsafe or missing system Python interpreter" >&2
    exit 1
}
python3() {
    /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C PYTHONNOUSERSITE=1 \
        "${PYTHON_EXECUTABLE}" -I "$@"
}

validate_trusted_executable() {
    local path="$1"
    python3 - "${path}" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_absolute() or path.resolve(strict=True) != path:
    raise SystemExit("trusted executable is not a canonical absolute path")
current = pathlib.Path(path.root)
for component in path.parts[1:-1]:
    current /= component
    st = os.lstat(current)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022):
        raise SystemExit(f"unsafe executable ancestor: {current}")
st = os.lstat(path)
if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
        or stat.S_IMODE(st.st_mode) & 0o022 or not os.access(path, os.X_OK)):
    raise SystemExit(f"unsafe executable: {path}")
PY
}

SYSTEMCTL_EXECUTABLE="/usr/bin/systemctl"
systemctl_sanitized() {
    /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C "${SYSTEMCTL_EXECUTABLE}" "$@"
}

gen2_manager_identity_is_exact() {
    local fragment dropins
    fragment="$(systemctl_sanitized show gen2.service --property=FragmentPath --value 2>/dev/null)" || return 1
    dropins="$(systemctl_sanitized show gen2.service --property=DropInPaths --value 2>/dev/null)" || return 1
    [[ "${fragment}" == "/etc/systemd/system/gen2.service" && -z "${dropins}" ]]
}

# Normalize a deliberately non-root effective group (for example sudo -g)
# before the first log/state/temp creation.  Re-exec preserves argv exactly and
# makes every subsequently created fixed path root:root from its first inode.
INSTALL_EGID="$(id -g 2>/dev/null || true)"
[[ "${INSTALL_EGID}" =~ ^[0-9]+$ ]] || {
    echo "Could not determine the effective group id" >&2
    exit 1
}
if [[ "${EUID}" -eq 0 && "${INSTALL_EGID}" -ne 0 ]]; then
    exec /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C PYTHONNOUSERSITE=1 \
        "${PYTHON_EXECUTABLE}" -I - "$0" "$@" <<'PY'
import os
import sys

script = os.path.abspath(sys.argv[1])
os.setgid(0)
os.execv("/bin/bash", ["bash", script, *sys.argv[2:]])
PY
fi
unset INSTALL_EGID
# Make every fresh private directory, lock, log, and atomic temporary safe at
# inode creation time even when the caller supplied a hostile inherited umask.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/driver/VERSION")
SUPPORTED_VERSIONS_CSV="$(IFS=', '; echo "${SUPPORTED_VERSIONS[*]}")"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

PROFILE_OVERRIDE=""
CONFIGURE_IOMMU=1
CONFIGURE_GEN2_SERVICE=1
for arg in "$@"; do
    case "${arg}" in
        --profile=8gb|--profile=8GB) PROFILE_OVERRIDE="8gb" ;;
        --profile=10gb|--profile=10GB) PROFILE_OVERRIDE="10gb" ;;
        --no-iommu) CONFIGURE_IOMMU=0 ;;
        --no-gen2-service) CONFIGURE_GEN2_SERVICE=0 ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./install.sh [--profile=8gb|10gb] [--no-iommu] [--no-gen2-service]

  --profile=8gb   Force 8GB metadata label (geometry is still chosen per PCI ID)
  --profile=10gb  Force 10GB metadata label (geometry is still chosen per PCI ID)
  --no-iommu      Do not touch the kernel command line (leave IOMMU settings alone)
  --no-gen2-service
                  Do not install the early-boot PCIe Gen2 retrain service

The installer verifies an existing intel_iommu=on / amd_iommu=on plus iommu=pt
configuration, but it does not rewrite bootloader inputs or live boot artifacts.
If the parameters are absent, add them with your distribution's boot tooling
before the final cold power cycle.

Without --profile, each unlockable GPU is classified by PCI device ID:
  10de:20c2 → 8gb / 64GB unlock
  10de:2082 → 10gb / 40GB unlock

Multi-GPU and mixed 8GB+10GB systems are supported in one install.
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
ok "Running as root"

step "Detecting CMP 170HX GPU(s)"
mapfile -t PCI_LINES < <(lspci -nn 2>/dev/null | grep -iE '10de:20b0|10de:20c2|10de:2082' || true)
[[ ${#PCI_LINES[@]} -gt 0 ]] || die "No CMP 170HX GPU found (10de:20b0 / 10de:20c2 / 10de:2082)"

SMI_MEM_CACHE=""
if command -v nvidia-smi &>/dev/null && command -v timeout &>/dev/null; then
    if ! SMI_MEM_CACHE="$(timeout --signal=TERM --kill-after=2s 10s \
        nvidia-smi --query-gpu=pci.bus_id,memory.total \
        --format=csv,noheader,nounits 2>/dev/null)"; then
        SMI_MEM_CACHE=""
        warn "nvidia-smi capacity query failed or timed out; continuing without informational capacity data"
    fi
fi

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()
GPU_CURRENT=()
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

    EXP="$(expected_mib_for_profile "${PROF}")"
    GPU_BDFS+=("${PCI_FULL}")
    GPU_DEVIDS+=("${DEVID}")
    GPU_PROFILES+=("${PROF}")
    GPU_EXPECTED+=("${EXP}")
    GPU_CURRENT+=("${CUR_MEM}")

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
        warn "Inventory is ${CARD_PROFILE} but --profile=${PROFILE_OVERRIDE} was forced (metadata only; geometry follows PCI ID)"
    else
        ok "Profile forced via --profile=${CARD_PROFILE}"
    fi
    CARD_PROFILE="${PROFILE_OVERRIDE}"
fi

case "${CARD_PROFILE}" in
    8gb)
        info "Unlock geometry: 64GB per card (CFG1=0x02779000 LMR=0x0000020B)"
        ;;
    10gb)
        info "Unlock geometry: 40GB per card (CFG1=0x02669000 LMR=0x0000028A)"
        ;;
    mixed)
        info "Unlock geometry: 64GB for 20c2 / 40GB for 2082"
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
export CMPUNLOCKER_GPU_INVENTORY="$(printf '%s\n' "${GPU_INVENTORY_LINES[@]}")"

step "Verifying nvidia-open (${SUPPORTED_VERSIONS_CSV})"
[[ ${#SUPPORTED_VERSIONS[@]} -gt 0 ]] || die "No supported versions listed in driver/VERSION"
if [[ -d /sys/firmware/efi ]] && command -v mokutil &>/dev/null; then
    if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
        die "Secure Boot is enabled. Disable it before installing unsigned patched modules."
    fi
fi

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

KVER="$(uname -r)"
DKMS_ARCH="$(uname -m)"
[[ "${KVER}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unsafe kernel release string: ${KVER}"
[[ "${DKMS_ARCH}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unsafe architecture string: ${DKMS_ARCH}"

STATE_DIR="/var/lib/cmpunlocker"
LIFECYCLE_LOCK="${STATE_DIR}/lifecycle.lock"
DKMS_RECEIPT="${STATE_DIR}/dkms-removed.${KVER}.receipt"
DKMS_TREE="/var/lib/dkms"
IOMMU_STATE="${STATE_DIR}/iommu.state"
IOMMU_BASE="${STATE_DIR}/iommu.base"
IOMMU_EXPECTED="${STATE_DIR}/iommu.expected"
IOMMU_PENDING="${STATE_DIR}/iommu.pending"
GEN2_STATE="${STATE_DIR}/gen2.state"
GEN2_PENDING="${STATE_DIR}/gen2.pending"
GEN2_UNIT_PATH="/etc/systemd/system/gen2.service"
GEN2_HAMMER_PATH="/usr/local/sbin/gen2-hammer"
GEN2_MODPROBE_PATH="/etc/modprobe.d/cmp-pcie-gen2.conf"
GEN2_UNIT_SOURCE="${SCRIPT_DIR}/systemd/gen2.service"
GEN2_HAMMER_SOURCE="${SCRIPT_DIR}/tools/hammer.sh"
GEN2_MODPROBE_CONTENT=$'# Managed by cmpunlocker; ownership receipt: /var/lib/cmpunlocker/gen2.state\noptions nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"\n'
MODULE_NAMES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm nvidia_peermem)
MODULE_FILES=(nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko)
MODULE_DIR=""

for required in timeout nvidia-smi modinfo readlink find python3 sha256sum sync stat depmod id flock; do
    command -v "${required}" &>/dev/null || die "Required command not found: ${required}"
done

atomic_write_text() {
    local target="$1"
    local mode="$2"
    local content="$3"
    python3 - "${target}" "${mode}" "${content}" <<'PY'
import os
import pathlib
import stat
import sys
import tempfile

target = pathlib.Path(sys.argv[1])
mode = int(sys.argv[2], 8)
content = sys.argv[3].encode("utf-8")
parent = target.parent
pst = os.lstat(parent)
if not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode):
    raise SystemExit(f"unsafe parent directory: {parent}")
try:
    tst = os.lstat(target)
except FileNotFoundError:
    pass
else:
    if not stat.S_ISREG(tst.st_mode) or stat.S_ISLNK(tst.st_mode):
        raise SystemExit(f"refusing non-regular target: {target}")
fd, tmp = tempfile.mkstemp(prefix=f".cmpunlocker-install.{target.name}.tmp.", dir=parent)
try:
    os.fchmod(fd, mode)
    os.fchown(fd, 0, 0)
    with os.fdopen(fd, "wb", closefd=True) as stream:
        fd = -1
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, target)
    dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
except BaseException:
    if fd >= 0:
        os.close(fd)
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

atomic_copy_mode() {
    local source="$1"
    local target="$2"
    local mode="$3"
    python3 - "${source}" "${target}" "${mode}" <<'PY'
import os
import pathlib
import stat
import sys
import tempfile

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
mode = int(sys.argv[3], 8)
sst = os.lstat(source)
if not stat.S_ISREG(sst.st_mode) or stat.S_ISLNK(sst.st_mode):
    raise SystemExit(f"unsafe source: {source}")
parent = target.parent
pst = os.lstat(parent)
if not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode):
    raise SystemExit(f"unsafe parent directory: {parent}")
try:
    tst = os.lstat(target)
except FileNotFoundError:
    pass
else:
    if not stat.S_ISREG(tst.st_mode) or stat.S_ISLNK(tst.st_mode):
        raise SystemExit(f"refusing non-regular target: {target}")
fd, tmp = tempfile.mkstemp(prefix=f".cmpunlocker-install.{target.name}.tmp.", dir=parent)
try:
    os.fchmod(fd, mode)
    os.fchown(fd, 0, 0)
    with open(source, "rb") as src, os.fdopen(fd, "wb", closefd=True) as dst:
        fd = -1
        while True:
            block = src.read(1024 * 1024)
            if not block:
                break
            dst.write(block)
        dst.flush()
        os.fsync(dst.fileno())
    os.replace(tmp, target)
    dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
except BaseException:
    if fd >= 0:
        os.close(fd)
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

# Publish one managed Gen2 file only if its bytes are still one of the values
# proven during preflight.  The source/content hash and target precondition are
# checked in the same helper immediately before the atomic rename.
atomic_publish_cas() {
    local kind="$1"
    local payload="$2"
    local target="$3"
    local mode="$4"
    local expected_new="$5"
    shift 5
    python3 - "${kind}" "${payload}" "${target}" "${mode}" "${expected_new}" "$@" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys
import tempfile

kind, payload_arg, target_arg, mode_arg, expected_new, *allowed = sys.argv[1:]
target = pathlib.Path(target_arg)
mode = int(mode_arg, 8)
if not allowed or any(x != "absent" and not __import__("re").fullmatch(r"[0-9a-f]{64}", x) for x in allowed):
    raise SystemExit("invalid compare-and-swap precondition")
if kind == "text":
    payload = payload_arg.encode("utf-8")
elif kind == "file":
    source = pathlib.Path(payload_arg)
    sst = os.lstat(source)
    if not stat.S_ISREG(sst.st_mode) or stat.S_ISLNK(sst.st_mode):
        raise SystemExit(f"unsafe source: {source}")
    with open(source, "rb") as stream:
        payload = stream.read()
else:
    raise SystemExit("invalid CAS payload kind")
if hashlib.sha256(payload).hexdigest() != expected_new:
    raise SystemExit("managed source/content changed after preflight")

parent = target.parent
pst = os.lstat(parent)
if not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode):
    raise SystemExit(f"unsafe parent directory: {parent}")
fd, tmp = tempfile.mkstemp(prefix=f".cmpunlocker-install.{target.name}.tmp.", dir=parent)
try:
    os.fchmod(fd, mode)
    os.fchown(fd, 0, 0)
    with os.fdopen(fd, "wb", closefd=True) as stream:
        fd = -1
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())

    try:
        before = os.lstat(target)
    except FileNotFoundError:
        current = "absent"
    else:
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
            raise SystemExit(f"refusing non-regular target: {target}")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        current_fd = os.open(target, flags)
        try:
            opened = os.fstat(current_fd)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise SystemExit("managed target changed during CAS open")
            digest = hashlib.sha256()
            while True:
                block = os.read(current_fd, 1024 * 1024)
                if not block:
                    break
                digest.update(block)
        finally:
            os.close(current_fd)
        after = os.lstat(target)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns
        ):
            raise SystemExit("managed target changed during CAS validation")
        current = digest.hexdigest()
    if current not in allowed:
        raise SystemExit(f"managed target compare-and-swap conflict: {target}")
    os.replace(tmp, target)
    dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
except BaseException:
    if fd >= 0:
        os.close(fd)
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

atomic_write_text_cas() {
    local target="$1" mode="$2" content="$3" expected_new="$4"
    shift 4
    atomic_publish_cas text "${content}" "${target}" "${mode}" "${expected_new}" "$@"
}

atomic_copy_mode_cas() {
    local source="$1" target="$2" mode="$3" expected_new="$4"
    shift 4
    atomic_publish_cas file "${source}" "${target}" "${mode}" "${expected_new}" "$@"
}

atomic_replace_from_snapshot() {
    local snapshot="$1"
    local target="$2"
    python3 - "${snapshot}" "${target}" <<'PY'
import os
import pathlib
import stat
import sys
import tempfile

snapshot = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
sst = os.lstat(snapshot)
tst = os.lstat(target)
if not stat.S_ISREG(sst.st_mode) or stat.S_ISLNK(sst.st_mode):
    raise SystemExit(f"unsafe snapshot: {snapshot}")
if not stat.S_ISREG(tst.st_mode) or stat.S_ISLNK(tst.st_mode):
    raise SystemExit(f"unsafe target: {target}")
if sst.st_uid != 0 or sst.st_gid != 0 or tst.st_uid != 0 or tst.st_gid != 0:
    raise SystemExit("snapshot and managed target must be owned by root:root")
parent = target.parent
pst = os.lstat(parent)
if not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode):
    raise SystemExit(f"unsafe parent directory: {parent}")
fd, tmp = tempfile.mkstemp(prefix=f".cmpunlocker-install.{target.name}.tmp.", dir=parent)
try:
    os.fchmod(fd, stat.S_IMODE(tst.st_mode))
    os.fchown(fd, 0, 0)
    with open(snapshot, "rb") as src, os.fdopen(fd, "wb", closefd=True) as dst:
        fd = -1
        while True:
            block = src.read(1024 * 1024)
            if not block:
                break
            dst.write(block)
        dst.flush()
        os.fsync(dst.fileno())
    os.replace(tmp, target)
    dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
except BaseException:
    if fd >= 0:
        os.close(fd)
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

durable_remove() {
    local target="$1"
    python3 - "${target}" <<'PY'
import os
import pathlib
import stat
import sys

target = pathlib.Path(sys.argv[1])
try:
    st = os.lstat(target)
except FileNotFoundError:
    dfd = os.open(target.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    raise SystemExit(0)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
    raise SystemExit(f"refusing to unlink non-regular file: {target}")
os.unlink(target)
dfd = os.open(target.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
PY
}

cleanup_known_atomic_temps() {
    local target parent base candidate owner_links
    local nullglob_was_set=0
    local -a managed_targets=(
        "${DKMS_RECEIPT}"
        "${IOMMU_STATE}"
        "${IOMMU_BASE}"
        "${IOMMU_EXPECTED}"
        "${IOMMU_PENDING}"
        "${STATE_DIR}/iommu.candidate"
        "${GEN2_STATE}"
        "${GEN2_PENDING}"
        "${GEN2_UNIT_PATH}"
        "${GEN2_HAMMER_PATH}"
        "${GEN2_MODPROBE_PATH}"
        "/etc/default/grub"
        "/etc/kernel/cmdline"
    )
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for target in "${managed_targets[@]}"; do
        parent="$(dirname -- "${target}")"
        base="$(basename -- "${target}")"
        [[ -d "${parent}" && ! -L "${parent}" ]] || continue
        for candidate in "${parent}/.cmpunlocker-install.${base}.tmp."*; do
            [[ -f "${candidate}" && ! -L "${candidate}" ]] || \
                die "Unsafe interrupted atomic-write artifact: ${candidate}"
            owner_links="$(stat -c '%u:%h' -- "${candidate}" 2>/dev/null || true)"
            [[ "${owner_links}" == "0:1" ]] || \
                die "Untrusted interrupted atomic-write artifact: ${candidate}"
            durable_remove "${candidate}" || \
                die "Could not reclaim interrupted atomic-write artifact: ${candidate}"
        done
    done
    # STATE_DIR is a private root:root 0700 namespace.  Include receipts from
    # older kernels so a hard cut before a kernel upgrade cannot leave an
    # install-owned hidden temp outside the current target list.
    for candidate in "${STATE_DIR}/.cmpunlocker-install."*.tmp.*; do
        [[ -f "${candidate}" && ! -L "${candidate}" ]] || \
            die "Unsafe interrupted state-write artifact: ${candidate}"
        owner_links="$(stat -c '%u:%h' -- "${candidate}" 2>/dev/null || true)"
        [[ "${owner_links}" == "0:1" ]] || \
            die "Untrusted interrupted state-write artifact: ${candidate}"
        durable_remove "${candidate}" || \
            die "Could not reclaim interrupted state-write artifact: ${candidate}"
    done
    (( nullglob_was_set == 1 )) || shopt -u nullglob
}

file_hash() {
    local source="$1"
    python3 - "${source}" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
st = os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
    raise SystemExit(f"unsafe hash target: {path}")
h = hashlib.sha256()
with open(path, "rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        h.update(block)
print(h.hexdigest())
PY
}

text_hash() {
    python3 - "$1" <<'PY'
import hashlib
import sys
print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
}

prepare_state_dir() {
    python3 - "${STATE_DIR}" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
parent = path.parent
pst = os.lstat(parent)
if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != 0 or pst.st_gid != 0
        or stat.S_IMODE(pst.st_mode) & 0o022):
    raise SystemExit(f"unsafe state parent: {parent}")
created = False
try:
    st = os.lstat(path)
except FileNotFoundError:
    os.mkdir(path, 0o700)
    created = True
    os.chown(path, 0, 0)
    st = os.lstat(path)
if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
    raise SystemExit(f"unsafe state directory: {path}")
if st.st_uid != 0 or st.st_gid != 0:
    raise SystemExit(f"wrong state-directory owner: {path}")
if stat.S_IMODE(st.st_mode) != 0o700:
    raise SystemExit(f"wrong state-directory mode: {path}")
dfd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
pfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(pfd)
finally:
    os.close(pfd)
PY
}

prepare_lifecycle_lock() {
    python3 - "${LIFECYCLE_LOCK}" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
base_flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
created = False
try:
    fd = os.open(path, base_flags | os.O_CREAT | os.O_EXCL, 0o600)
    created = True
except FileExistsError:
    fd = os.open(path, base_flags)
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise SystemExit(f"lifecycle lock is not regular: {path}")
    if st.st_nlink != 1:
        raise SystemExit(f"lifecycle lock has an unsafe link count: {path}")
    if created:
        os.fchown(fd, 0, 0)
        os.fchmod(fd, 0o600)
        st = os.fstat(fd)
    if st.st_uid != 0 or st.st_gid != 0:
        raise SystemExit(f"lifecycle lock has wrong owner: {path}")
    if stat.S_IMODE(st.st_mode) != 0o600:
        raise SystemExit(f"lifecycle lock has wrong mode: {path}")
    os.fsync(fd)
finally:
    os.close(fd)
dfd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
PY
}

secure_state_file() {
    local file="$1"
    local expected
    [[ -f "${file}" && ! -L "${file}" ]] || return 1
    expected="600:0:0:1"
    [[ "$(stat -c '%a:%u:%g:%h' -- "${file}" 2>/dev/null)" == "${expected}" ]]
}

# Read a private state file through one O_NOFOLLOW descriptor.  Bash silently
# drops NUL bytes from variables/mapfile fields, so validating with shell
# reads alone can make a malformed receipt compare equal to a trusted one.
read_secure_state_lines() {
    local file="$1"
    local output_name="$2"
    local last_index
    local -n output_ref="${output_name}"
    output_ref=()
    mapfile -d '' -t output_ref < <(python3 - "${file}" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, flags)
try:
    before = os.fstat(fd)
    if (not stat.S_ISREG(before.st_mode) or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_uid != 0 or before.st_gid != 0 or before.st_nlink != 1):
        raise SystemExit(f"unsafe state file metadata: {path}")
    chunks = []
    total = 0
    while True:
        block = os.read(fd, 8192)
        if not block:
            break
        total += len(block)
        if total > 65536:
            raise SystemExit(f"oversized state file: {path}")
        chunks.append(block)
    after = os.fstat(fd)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
            before.st_ctime_ns, before.st_nlink) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
            after.st_ctime_ns, after.st_nlink):
        raise SystemExit(f"state file changed while reading: {path}")
finally:
    os.close(fd)
raw = b"".join(chunks)
if not raw or not raw.endswith(b"\n") or b"\x00" in raw or b"\r" in raw:
    raise SystemExit(f"state file is not canonical newline-delimited text: {path}")
if any(byte != 0x0A and not 0x20 <= byte <= 0x7E for byte in raw):
    raise SystemExit(f"state file contains non-ASCII or control bytes: {path}")
try:
    text = raw.decode("utf-8", errors="strict")
except UnicodeDecodeError as error:
    raise SystemExit(f"state file is not UTF-8: {path}: {error}")
lines = text[:-1].split("\n")
if any(not line for line in lines):
    raise SystemExit(f"state file contains an empty record: {path}")
for line in lines:
    os.write(1, line.encode("utf-8") + b"\x00")
os.write(1, b"__CMPUNLOCKER_STATE_READ_OK__\x00")
PY
    )
    (( ${#output_ref[@]} >= 1 )) || return 1
    last_index=$(( ${#output_ref[@]} - 1 ))
    [[ "${output_ref[$last_index]}" == '__CMPUNLOCKER_STATE_READ_OK__' ]] || return 1
    unset 'output_ref[last_index]'
}

if ! smi_output="$(timeout --signal=TERM --kill-after=2s 10s nvidia-smi --version 2>/dev/null)"; then
    die "nvidia-smi --version failed or timed out; cannot identify the installed userspace safely"
fi
if ! detected="$(sed -nE 's/^[[:space:]]*NVIDIA-SMI version[[:space:]]*:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' <<< "${smi_output}")"; then
    die "Could not parse the installed NVIDIA-SMI userspace version"
fi
[[ "${detected}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${detected}" != *$'\n'* ]] || \
    die "nvidia-smi --version did not report exactly one three-component NVIDIA-SMI version"
version_supported "${detected}" || \
    die "Installed NVIDIA userspace is ${detected}, but cmpunlocker requires one of: ${SUPPORTED_VERSIONS_CSV}."

if [[ -r /proc/driver/nvidia/version ]]; then
    running_version="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | sed -n '1p' || true)"
    if [[ -n "${running_version}" && "${running_version}" != "${detected}" ]]; then
        warn "Loaded NVIDIA kernel module ${running_version} differs from installed userspace ${detected}; on-disk userspace remains authoritative"
    fi
fi
FIRMWARE_PATH="/lib/firmware/nvidia/${detected}/gsp_tu10x.bin"
[[ -f "${FIRMWARE_PATH}" && -s "${FIRMWARE_PATH}" && ! -L "${FIRMWARE_PATH}" ]] || \
    die "Missing, empty, or symlinked matching firmware: ${FIRMWARE_PATH}"
ok "Verified installed NVIDIA userspace ${detected} and matching non-empty firmware"

[[ -d "/lib/modules/${KVER}/build" ]] || \
    die "Kernel headers missing for ${KVER}. Install linux-headers-${KVER} or kernel-devel."
MODULE_ROOT="$(readlink -f -- "/lib/modules/${KVER}")" || die "Cannot canonicalize /lib/modules/${KVER}"
[[ -d "${MODULE_ROOT}" ]] || die "Invalid module root for ${KVER}"
[[ "$(basename -- "${MODULE_ROOT}")" == "${KVER}" ]] || \
    die "Canonical module root does not end in the exact kernel release: ${MODULE_ROOT}"
MODULE_INSTALL_TREE="$(dirname -- "${MODULE_ROOT}")"
[[ -d "${MODULE_INSTALL_TREE}" && ! -L "${MODULE_INSTALL_TREE}" &&
   "$(readlink -f -- "${MODULE_INSTALL_TREE}" 2>/dev/null || true)" == "${MODULE_INSTALL_TREE}" ]] || \
    die "Unsafe canonical module install tree: ${MODULE_INSTALL_TREE}"
MODULE_DIR="${MODULE_ROOT}/updates/cmpunlocker"

validate_module_file() {
    local path="$1"
    local expected_name="$2"
    local version name vermagic vermagic_kernel srcversion
    if ! name="$(modinfo -F name -- "${path}" 2>/dev/null)" || [[ "${name}" != "${expected_name}" ]]; then
        return 1
    fi
    if ! version="$(modinfo -F version -- "${path}" 2>/dev/null)" || [[ "${version}" != "${detected}" ]]; then
        return 1
    fi
    if ! vermagic="$(modinfo -F vermagic -- "${path}" 2>/dev/null)" || [[ -z "${vermagic}" ]]; then
        return 1
    fi
    read -r vermagic_kernel _ <<< "${vermagic}"
    [[ "${vermagic_kernel}" == "${KVER}" ]] || return 1
    if ! srcversion="$(modinfo -F srcversion -- "${path}" 2>/dev/null)" || [[ ! "${srcversion}" =~ ^[0-9A-Fa-f]+$ ]]; then
        return 1
    fi
}

inspect_module_provenance() {
    local path="$1"
    local result
    local detector='import sys; d=sys.stdin.buffer.read(); m=(b"cmpunlocker-safety-v3", b"CMP Gen2:"); print("patched" if any(x in d for x in m) else "clean")'
    case "${path}" in
        *.zst)
            command -v zstdcat &>/dev/null || return 2
            result="$(zstdcat -- "${path}" | python3 -c "${detector}")" || return 2
            ;;
        *.xz)
            command -v xzcat &>/dev/null || return 2
            result="$(xzcat -- "${path}" | python3 -c "${detector}")" || return 2
            ;;
        *.gz)
            command -v gzip &>/dev/null || return 2
            result="$(gzip -cd -- "${path}" | python3 -c "${detector}")" || return 2
            ;;
        *)
            result="$(python3 -c "${detector}" < "${path}")" || return 2
            ;;
    esac
    [[ "${result}" == "clean" || "${result}" == "patched" ]] || return 2
    printf '%s\n' "${result}"
}

directory_tree_is_regular_only() {
    local directory="$1"
    local canonical unexpected
    [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
    canonical="$(readlink -f -- "${directory}" 2>/dev/null || true)"
    [[ "${canonical}" == "${directory}" ]] || return 1
    if ! unexpected="$(find -P "${directory}" -mindepth 1 ! -type f -print -quit)"; then
        return 1
    fi
    [[ -z "${unexpected}" ]] || {
        err "Module directory contains a subdirectory, symlink, or non-regular object: ${unexpected}"
        return 1
    }
}

EXISTING_CMP_CORE_SRCVERSION=""
if [[ -f "${MODULE_DIR}/nvidia.ko" && ! -L "${MODULE_DIR}/nvidia.ko" ]]; then
    EXISTING_CMP_CORE_SRCVERSION="$(modinfo -F srcversion -- "${MODULE_DIR}/nvidia.ko" 2>/dev/null || true)"
fi

find_stock_module() {
    local filename="$1"
    local expected_name="$2"
    local candidate canonical srcversion provenance find_ok=0
    local -a matches=()
    local -A seen=()
    while IFS= read -r -d '' candidate; do
        if [[ "${candidate}" == '__CMPUNLOCKER_FIND_OK__' ]]; then
            find_ok=1
            continue
        fi
        canonical="$(readlink -f -- "${candidate}" 2>/dev/null || true)"
        [[ -n "${canonical}" && -f "${canonical}" ]] || continue
        [[ "${canonical}" == "${MODULE_ROOT}/"* ]] || continue
        [[ "${canonical}" != "${MODULE_DIR}/"* ]] || continue
        [[ "${canonical}" != "${MODULE_ROOT}/updates/dkms/"* ]] || continue
        [[ "${canonical}" != "${MODULE_ROOT}/weak-updates/"* ]] || continue
        [[ "${canonical}" != *"/.cmpunlocker"* ]] || continue
        [[ -z "${seen[${canonical}]:-}" ]] || continue
        seen["${canonical}"]=1
        validate_module_file "${canonical}" "${expected_name}" || continue
        if [[ "${expected_name}" == "nvidia" && -n "${EXISTING_CMP_CORE_SRCVERSION}" ]]; then
            srcversion="$(modinfo -F srcversion -- "${canonical}" 2>/dev/null || true)"
            [[ "${srcversion}" != "${EXISTING_CMP_CORE_SRCVERSION}" ]] || continue
        fi
        if [[ "${expected_name}" == "nvidia" ]]; then
            if ! provenance="$(inspect_module_provenance "${canonical}")"; then
                err "Cannot inspect compressed stock provenance safely: ${canonical}"
                return 1
            fi
            [[ "${provenance}" == "clean" ]] || continue
        fi
        matches+=("${canonical}")
    done < <(find -P "${MODULE_ROOT}" -type f \
        \( -name "${filename}" -o -name "${filename}.gz" -o \
           -name "${filename}.xz" -o -name "${filename}.zst" \) -print0 &&
        printf '%s\0' '__CMPUNLOCKER_FIND_OK__')
    (( find_ok == 1 )) || return 1
    if (( ${#matches[@]} != 1 )); then
        err "Expected exactly one verified stock ${filename} for ${KVER}; found ${#matches[@]}"
        if (( ${#matches[@]} > 0 )); then
            printf '  candidate: %s\n' "${matches[@]}" >&2
        fi
        return 1
    fi
    FOUND_STOCK_MODULE="${matches[0]}"
}

select_mkinitcpio_target() {
    local preset="/etc/mkinitcpio.d/${INITRAMFS_PRESET}.preset"
    local values=()
    mapfile -t values < <(python3 - "${preset}" "${KVER}" "/lib/modules/${KVER}/vmlinuz" <<'PY'
import hashlib
import os
import pathlib
import re
import shlex
import stat
import sys

preset = pathlib.Path(sys.argv[1])
kver = sys.argv[2]
module_kernel = pathlib.Path(sys.argv[3])
pst = os.lstat(preset)
if not stat.S_ISREG(pst.st_mode) or stat.S_ISLNK(pst.st_mode):
    raise SystemExit("unsafe mkinitcpio preset")
assignments = {}
presets = None
for number, raw in enumerate(preset.read_text(encoding="utf-8").splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    array = re.fullmatch(r"PRESETS=\((.*)\)", line)
    if array:
        presets = shlex.split(array.group(1), posix=True)
        if not presets or any(not re.fullmatch(r"[A-Za-z0-9._+-]+", x) for x in presets):
            raise SystemExit("unsafe PRESETS assignment")
        continue
    scalar = re.fullmatch(r"([A-Za-z0-9_]+)=(.*)", line)
    if not scalar:
        raise SystemExit(f"unsupported executable preset syntax on line {number}")
    key, encoded = scalar.groups()
    if not (key.startswith("ALL_") or key.startswith("default_")):
        # Ignore unused fallback/other preset scalars after PRESETS selected the
        # single auditable default entry.
        continue
    if any(token in encoded for token in ("$", "`", ";", "(", ")")):
        raise SystemExit(f"dynamic preset value on line {number}")
    values = [""] if encoded == "" else shlex.split(encoded, posix=True)
    if len(values) != 1:
        raise SystemExit(f"ambiguous preset value on line {number}")
    assignments[key] = values[0]
if presets != ["default"]:
    raise SystemExit("mkinitcpio preset must select exactly one default image")
if assignments.get("default_uki") or assignments.get("default_efi_image"):
    raise SystemExit("UKI-only mkinitcpio presets are unsupported")
if assignments.get("default_options") or assignments.get("ALL_options", ""):
    raise SystemExit("preset options could override the exact kernel")
for key in ("cmdline", "splash", "kerneldest"):
    effective = assignments.get(f"default_{key}") or assignments.get(f"ALL_{key}", "")
    if effective:
        raise SystemExit(f"effective default {key} is unsupported for exact direct invocation")
kernel_spec = assignments.get("default_kver") or assignments.get("ALL_kver", "")
if kernel_spec and kernel_spec != kver:
    kernel_path = pathlib.Path(kernel_spec)
    if not kernel_path.is_absolute():
        raise SystemExit("preset kver is neither exact release nor absolute image")
    for candidate in (kernel_path, module_kernel):
        cst = os.lstat(candidate)
        if not stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode):
            raise SystemExit(f"unsafe kernel image {candidate}")
    def digest(path):
        h = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                h.update(block)
        return h.digest()
    if digest(kernel_path) != digest(module_kernel):
        raise SystemExit("preset kernel image does not match target KVER")
image = assignments.get("default_image", "")
config = assignments.get("default_config") or assignments.get("ALL_config", "")
image_path = pathlib.Path(image)
if not image or not image_path.is_absolute():
    raise SystemExit("mkinitcpio image is not absolute")
if config:
    config_path = pathlib.Path(config)
    if not config_path.is_absolute():
        raise SystemExit("mkinitcpio config is not absolute")
    cst = os.lstat(config_path)
    if not stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode):
        raise SystemExit("unsafe mkinitcpio config")
dst = os.lstat(image_path.parent)
if not stat.S_ISDIR(dst.st_mode) or stat.S_ISLNK(dst.st_mode):
    raise SystemExit("unsafe mkinitcpio output parent")
try:
    ist = os.lstat(image_path)
except FileNotFoundError:
    pass
else:
    if not stat.S_ISREG(ist.st_mode) or stat.S_ISLNK(ist.st_mode):
        raise SystemExit("unsafe existing mkinitcpio image")
print(config if config else "absent")
print(image)
PY
    ) || return 1
    [[ ${#values[@]} -eq 2 ]] || return 1
    INITRAMFS_CONFIG="${values[0]}"
    INITRAMFS_IMAGE="${values[1]}"
}

select_initramfs_tool() {
    if command -v update-initramfs &>/dev/null; then
        INITRAMFS_TOOL="update-initramfs"
    elif command -v dracut &>/dev/null; then
        INITRAMFS_TOOL="dracut"
    elif command -v mkinitcpio &>/dev/null; then
        INITRAMFS_TOOL="mkinitcpio"
        INITRAMFS_PRESET="$(tr -d '[:space:]' < "/lib/modules/${KVER}/pkgbase" 2>/dev/null || true)"
        [[ "${INITRAMFS_PRESET}" =~ ^[A-Za-z0-9._+-]+$ &&
           -f "/etc/mkinitcpio.d/${INITRAMFS_PRESET}.preset" ]] || return 1
        select_mkinitcpio_target || return 1
    else
        return 1
    fi
}

rebuild_current_initramfs() {
    local kernel="$1"
    local -a mkinitcpio_args=()
    case "${INITRAMFS_TOOL}" in
        update-initramfs)
            info "Rebuilding final initramfs for ${kernel} (update-initramfs)..."
            update-initramfs -u -k "${kernel}"
            ;;
        dracut)
            info "Rebuilding final initramfs for ${kernel} (dracut)..."
            dracut --force --kver "${kernel}"
            ;;
        mkinitcpio)
            [[ "${kernel}" == "${KVER}" ]] || return 1
            info "Rebuilding ${INITRAMFS_IMAGE} explicitly for ${KVER} (mkinitcpio)..."
            mkinitcpio_args=(-k "${KVER}" -g "${INITRAMFS_IMAGE}")
            if [[ "${INITRAMFS_CONFIG}" != "absent" ]]; then
                mkinitcpio_args+=(-c "${INITRAMFS_CONFIG}")
            fi
            mkinitcpio "${mkinitcpio_args[@]}"
            ;;
        *) return 2 ;;
    esac
}
select_initramfs_tool || \
    die "No supported initramfs tool found (need update-initramfs, dracut, or mkinitcpio)"

prepare_state_dir || die "Could not prepare secure state directory ${STATE_DIR}"
prepare_lifecycle_lock || die "Could not prepare secure lifecycle lock ${LIFECYCLE_LOCK}"
exec {LIFECYCLE_LOCK_FD}<> "${LIFECYCLE_LOCK}" || die "Could not open lifecycle lock"
[[ -f "${LIFECYCLE_LOCK}" && ! -L "${LIFECYCLE_LOCK}" &&
   "$(stat -c '%a:%u:%g' -- "${LIFECYCLE_LOCK}")" == "600:0:0" &&
   "$(stat -c '%d:%i' -- "${LIFECYCLE_LOCK}")" == "$(stat -Lc '%d:%i' -- "/proc/self/fd/${LIFECYCLE_LOCK_FD}")" ]] || \
    die "Lifecycle lock changed during acquisition"
flock -n "${LIFECYCLE_LOCK_FD}" || die "Another cmpunlocker install/remove lifecycle is already active"
cleanup_known_atomic_temps

load_dkms_receipt() {
    local file="$1"
    local -a lines=()
    read_secure_state_lines "${file}" lines || return 1
    (( ${#lines[@]} == 5 )) || return 1
    [[ "${lines[0]}" == "format=1" &&
       "${lines[1]}" == "module=nvidia" &&
       "${lines[2]}" == "version=${detected}" &&
       "${lines[3]}" == "kernel=${KVER}" &&
       "${lines[4]}" == "arch=${DKMS_ARCH}" ]] || return 1
}

verify_no_exact_dkms_originals() {
    python3 - "${DKMS_TREE}" nvidia "${KVER}" "${DKMS_ARCH}" <<'PY'
import errno
import os
import pathlib
import stat
import sys

tree = pathlib.Path(sys.argv[1])
module, kver, arch = sys.argv[2:5]
flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
         | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))

def validate_dir(fd, label, device=None):
    st = os.fstat(fd)
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022
            or (device is not None and st.st_dev != device)):
        raise SystemExit(f"unsafe DKMS directory: {label}")
    return st

try:
    current = os.open(tree, flags)
except FileNotFoundError:
    raise SystemExit(0)
try:
    root_st = validate_dir(current, tree)
    if tree.resolve(strict=True) != tree:
        raise SystemExit(f"DKMS tree has a symlinked path component: {tree}")
    label = tree
    for component in (module, "original_module", kver):
        try:
            child = os.open(component, flags, dir_fd=current)
        except FileNotFoundError:
            os.fsync(current)
            raise SystemExit(0)
        validate_dir(child, label / component, root_st.st_dev)
        os.close(current)
        current = child
        label = label / component
    try:
        os.stat(arch, dir_fd=current, follow_symlinks=False)
    except FileNotFoundError:
        os.fsync(current)
        raise SystemExit(0)
    raise SystemExit(
        f"unsupported DKMS original-module state exists for {kver}/{arch}: {label / arch}"
    )
finally:
    try:
        os.close(current)
    except OSError as error:
        if error.errno != errno.EBADF:
            raise
PY
}

DKMS_RECEIPT_CONTENT="$(printf 'format=1\nmodule=nvidia\nversion=%s\nkernel=%s\narch=%s\n' \
    "${detected}" "${KVER}" "${DKMS_ARCH}")"$'\n'
DKMS_RECEIPT_PREEXISTED=0
if [[ -e "${DKMS_RECEIPT}" || -L "${DKMS_RECEIPT}" ]]; then
    load_dkms_receipt "${DKMS_RECEIPT}" || die "Invalid or mismatched DKMS receipt: ${DKMS_RECEIPT}"
    verify_no_exact_dkms_originals || \
        die "DKMS receipt cannot be used while original-module backups exist; no cleanup was attempted"
    DKMS_RECEIPT_PREEXISTED=1
fi

classify_exact_dkms_tuple() {
    local output
    DKMS_TUPLE_STATE="unknown"
    DKMS_SOURCE_REGISTERED=0
    output="$(python3 - "${DKMS_TREE}" nvidia "${detected}" "${KVER}" "${DKMS_ARCH}" <<'PY'
import os
import pathlib
import re
import stat
import sys

tree = pathlib.Path(sys.argv[1])
module, version, kver, arch = sys.argv[2:6]
if (tree != pathlib.Path("/var/lib/dkms") or module != "nvidia"
        or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
        or not re.fullmatch(r"[A-Za-z0-9._+-]+", kver)
        or not re.fullmatch(r"[A-Za-z0-9._+-]+", arch)):
    raise SystemExit("unsafe exact DKMS tuple identity")

def secure_dir(path):
    st = os.lstat(path)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022):
        raise SystemExit(f"unsafe DKMS directory: {path}")
    if path.resolve(strict=True) != path:
        raise SystemExit(f"symlinked DKMS directory path: {path}")
    return st

def secure_tree(path, device):
    for parent, dirs, files in os.walk(path, topdown=True, followlinks=False):
        parent_path = pathlib.Path(parent)
        pst = os.lstat(parent_path)
        if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
                or pst.st_dev != device or pst.st_uid != 0 or pst.st_gid != 0
                or stat.S_IMODE(pst.st_mode) & 0o022):
            raise SystemExit(f"unsafe DKMS tuple directory: {parent_path}")
        for name in dirs + files:
            child = parent_path / name
            st = os.lstat(child)
            if (st.st_dev != device or st.st_uid != 0 or st.st_gid != 0
                    or stat.S_IMODE(st.st_mode) & 0o022):
                raise SystemExit(f"unsafe DKMS tuple object: {child}")
            if stat.S_ISLNK(st.st_mode) or not (
                    stat.S_ISDIR(st.st_mode) or
                    (stat.S_ISREG(st.st_mode) and st.st_nlink == 1)):
                raise SystemExit(f"symlink, special, or hardlinked DKMS tuple object: {child}")

try:
    tree_st = secure_dir(tree)
except FileNotFoundError:
    print("state=absent")
    print("source=0")
    raise SystemExit(0)
device = tree_st.st_dev
module_path = tree / module
version_path = module_path / version
for path in (module_path, version_path):
    try:
        st = secure_dir(path)
    except FileNotFoundError:
        print("state=absent")
        print("source=0")
        raise SystemExit(0)
    if st.st_dev != device:
        raise SystemExit(f"cross-device DKMS tuple directory: {path}")

source_link = version_path / "source"
source_st = os.lstat(source_link)
if (not stat.S_ISLNK(source_st.st_mode) or source_st.st_uid != 0
        or source_st.st_gid != 0 or source_st.st_nlink != 1):
    raise SystemExit(f"broken or unsafe DKMS source registration: {source_link}")
expected_source = pathlib.Path("/usr/src") / f"{module}-{version}"
if source_link.resolve(strict=True) != expected_source:
    raise SystemExit(f"unexpected DKMS source target: {source_link}")
source_dir_st = secure_dir(expected_source)
conf = expected_source / "dkms.conf"
conf_st = os.lstat(conf)
if (not stat.S_ISREG(conf_st.st_mode) or stat.S_ISLNK(conf_st.st_mode)
        or conf_st.st_uid != 0 or conf_st.st_gid != 0 or conf_st.st_nlink != 1
        or stat.S_IMODE(conf_st.st_mode) & 0o022
        or conf_st.st_dev != source_dir_st.st_dev):
    raise SystemExit(f"unsafe DKMS source configuration: {conf}")

original_arch = tree / module / "original_module" / kver / arch
try:
    os.lstat(original_arch)
except FileNotFoundError:
    pass
else:
    print("state=originals")
    print("source=1")
    raise SystemExit(0)

kver_path = version_path / kver
base_path = kver_path / arch
active = module_path / f"kernel-{kver}-{arch}"
try:
    active_st = os.lstat(active)
except FileNotFoundError:
    active_st = None
if active_st is not None:
    if (not stat.S_ISLNK(active_st.st_mode) or active_st.st_uid != 0
            or active_st.st_gid != 0 or active_st.st_nlink != 1
            or active.resolve(strict=False) != base_path):
        raise SystemExit(f"unsafe exact DKMS active link: {active}")

try:
    kver_st = secure_dir(kver_path)
except FileNotFoundError:
    kver_st = None
try:
    base_st = secure_dir(base_path)
except FileNotFoundError:
    base_st = None
if base_st is None:
    if active_st is not None:
        raise SystemExit("exact DKMS active link exists without its tuple base")
    print("state=absent")
    print("source=1")
    raise SystemExit(0)
if kver_st is None or kver_st.st_dev != device or base_st.st_dev != device:
    raise SystemExit("unsafe exact DKMS tuple filesystem")
secure_tree(base_path, device)
print("state=installed" if active_st is not None else "state=present")
print("source=1")
PY
)" || return 1
    case "${output}" in
        $'state=absent\nsource=0') DKMS_TUPLE_STATE="absent" ;;
        $'state=absent\nsource=1') DKMS_TUPLE_STATE="absent"; DKMS_SOURCE_REGISTERED=1 ;;
        $'state=present\nsource=1') DKMS_TUPLE_STATE="present"; DKMS_SOURCE_REGISTERED=1 ;;
        $'state=installed\nsource=1') DKMS_TUPLE_STATE="installed"; DKMS_SOURCE_REGISTERED=1 ;;
        $'state=originals\nsource=1') DKMS_TUPLE_STATE="originals"; DKMS_SOURCE_REGISTERED=1 ;;
        *) return 1 ;;
    esac
}

load_exact_dkms_module_set() {
    local i suffix candidate canonical provenance entry last_index
    local directory="${MODULE_ROOT}/updates/dkms"
    local -a matches=() discovered=()
    local -A selected=()
    DKMS_MODULE_PATHS=()
    [[ -d "${directory}" && ! -L "${directory}" &&
       "$(readlink -f -- "${directory}" 2>/dev/null || true)" == "${directory}" ]] || return 1
    for i in "${!MODULE_FILES[@]}"; do
        matches=()
        for suffix in '' .gz .xz .zst; do
            candidate="${directory}/${MODULE_FILES[$i]}${suffix}"
            if [[ -e "${candidate}" || -L "${candidate}" ]]; then
                matches+=("${candidate}")
            fi
        done
        (( ${#matches[@]} == 1 )) || return 1
        candidate="${matches[0]}"
        [[ -f "${candidate}" && ! -L "${candidate}" ]] || return 1
        canonical="$(readlink -f -- "${candidate}" 2>/dev/null || true)"
        [[ "${canonical}" == "${candidate}" ]] || return 1
        validate_module_file "${candidate}" "${MODULE_NAMES[$i]}" || return 1
        if (( i == 0 )); then
            provenance="$(inspect_module_provenance "${candidate}")" || return 1
            [[ "${provenance}" == "clean" ]] || return 1
        fi
        DKMS_MODULE_PATHS+=("${candidate}")
        selected["${candidate}"]=1
    done

    # Other DKMS packages may legitimately share this flat directory, but the
    # five NVIDIA basenames must have exactly one regular object each and may
    # not be duplicated in a nested path or alternate compression form.
    mapfile -d '' -t discovered < <(
        find -P "${directory}" -mindepth 1 \
            \( -name 'nvidia.ko*' -o -name 'nvidia-modeset.ko*' -o \
               -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' -o \
               -name 'nvidia-peermem.ko*' \) \
            -print0 && printf '%s\0' '__CMPUNLOCKER_FIND_OK__'
    )
    (( ${#discovered[@]} == ${#MODULE_FILES[@]} + 1 )) || return 1
    last_index=$(( ${#discovered[@]} - 1 ))
    [[ "${discovered[$last_index]}" == '__CMPUNLOCKER_FIND_OK__' ]] || return 1
    unset 'discovered[last_index]'
    for entry in "${discovered[@]}"; do
        [[ -n "${selected[${entry}]:-}" ]] || return 1
    done
}

resolved_is_exact_dkms_set() {
    local i
    (( ${#RESOLVED_MODULE_PATHS[@]} == ${#DKMS_MODULE_PATHS[@]} )) || return 1
    for i in "${!MODULE_NAMES[@]}"; do
        [[ "${RESOLVED_MODULE_PATHS[$i]}" == "${DKMS_MODULE_PATHS[$i]}" ]] || return 1
    done
}

module_payload_sha256() {
    local module="$1" hash
    case "${module}" in
        *.ko)
            hash="$(/usr/bin/sha256sum -- "${module}")" || return 1
            ;;
        *.ko.gz)
            hash="$(/usr/bin/gzip -cd -- "${module}" | /usr/bin/sha256sum)" || return 1
            ;;
        *.ko.xz)
            hash="$(/usr/bin/xz -cd -- "${module}" | /usr/bin/sha256sum)" || return 1
            ;;
        *.ko.zst)
            hash="$(/usr/bin/zstdcat -- "${module}" | /usr/bin/sha256sum)" || return 1
            ;;
        *) return 1 ;;
    esac
    hash="${hash%% *}"
    [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${hash}"
}

dkms_module_artifacts_present() {
    local directory="${MODULE_ROOT}/updates/dkms"
    local unexpected
    [[ ! -e "${directory}" && ! -L "${directory}" ]] && return 1
    [[ -d "${directory}" && ! -L "${directory}" &&
       "$(readlink -f -- "${directory}" 2>/dev/null || true)" == "${directory}" ]] || return 0
    if ! unexpected="$(find -P "${directory}" -mindepth 1 \
        \( -name 'nvidia.ko*' -o -name 'nvidia-modeset.ko*' -o \
           -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' -o \
           -name 'nvidia-peermem.ko*' \) \
        -print -quit)"; then
        return 0
    fi
    [[ -n "${unexpected}" ]]
}

validate_remaining_dkms_target_bindings() {
    local completeness="${1:-remaining}"
    local i field target build provenance last_index
    local target_payload build_payload target_raw build_raw
    local any_target
    local target_dir="${MODULE_ROOT}/updates/dkms"
    local build_dir="${DKMS_TREE}/nvidia/${detected}/${KVER}/${DKMS_ARCH}/module"
    local -a target_matches=() build_matches=()
    DKMS_TARGET_CLEANUP_RECORDS=()
    [[ "${completeness}" == "remaining" || "${completeness}" == "complete" ]] || return 1
    if [[ ! -e "${target_dir}" && ! -L "${target_dir}" ]]; then
        [[ "${completeness}" == "remaining" ]] || return 1
        return 0
    else
        [[ -d "${target_dir}" && ! -L "${target_dir}" ]] || return 1
    fi
    if [[ "${completeness}" == "remaining" ]]; then
        any_target="$(find -P "${target_dir}" -mindepth 1 \
            \( -name 'nvidia.ko*' -o -name 'nvidia-modeset.ko*' -o \
               -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' -o \
               -name 'nvidia-peermem.ko*' \) -print -quit)" || return 1
        # With no target leaf left, no byte authority is needed for deletion.
        # A partially removed B tree can therefore resume into exact tree
        # cleanup after a hard cut without granting authority over new bytes.
        [[ -n "${any_target}" ]] || return 0
    fi
    [[ -d "${build_dir}" && ! -L "${build_dir}" ]] || return 1
    for i in "${!MODULE_FILES[@]}"; do
        # B/module is the byte-identity authority for every remaining target.
        # Require the complete five-module B set even after one or more target
        # leaves were already removed by an interrupted forward cleanup.
        mapfile -d '' -t build_matches < <(
            find -P "${build_dir}" -mindepth 1 \
                -name "${MODULE_FILES[$i]}*" -print0 &&
            printf '%s\0' '__CMPUNLOCKER_FIND_OK__'
        )
        (( ${#build_matches[@]} >= 1 )) || return 1
        last_index=$(( ${#build_matches[@]} - 1 ))
        [[ "${build_matches[$last_index]}" == '__CMPUNLOCKER_FIND_OK__' ]] || return 1
        unset 'build_matches[last_index]'
        (( ${#build_matches[@]} == 1 )) || return 1
        build="${build_matches[0]}"
        [[ "$(dirname -- "${build}")" == "${build_dir}" ]] || return 1
        case "$(basename -- "${build}")" in
            "${MODULE_FILES[$i]}"|"${MODULE_FILES[$i]}.gz"|\
            "${MODULE_FILES[$i]}.xz"|"${MODULE_FILES[$i]}.zst") ;;
            *) return 1 ;;
        esac
        [[ -f "${build}" && ! -L "${build}" ]] || return 1
        validate_module_file "${build}" "${MODULE_NAMES[$i]}" || return 1
        if (( i == 0 )); then
            provenance="$(inspect_module_provenance "${build}")" || return 1
            [[ "${provenance}" == "clean" ]] || return 1
        fi

        target_matches=()
        if [[ -d "${target_dir}" ]]; then
            mapfile -d '' -t target_matches < <(
                find -P "${target_dir}" -mindepth 1 -name "${MODULE_FILES[$i]}*" -print0 &&
                printf '%s\0' '__CMPUNLOCKER_FIND_OK__'
            )
            (( ${#target_matches[@]} >= 1 )) || return 1
            last_index=$(( ${#target_matches[@]} - 1 ))
            [[ "${target_matches[$last_index]}" == '__CMPUNLOCKER_FIND_OK__' ]] || return 1
            unset 'target_matches[last_index]'
        fi
        (( ${#target_matches[@]} <= 1 )) || return 1
        if (( ${#target_matches[@]} == 0 )); then
            [[ "${completeness}" == "remaining" ]] || return 1
            continue
        fi
        target="${target_matches[0]}"
        [[ "$(dirname -- "${target}")" == "${target_dir}" ]] || return 1
        case "$(basename -- "${target}")" in
            "${MODULE_FILES[$i]}"|"${MODULE_FILES[$i]}.gz"|\
            "${MODULE_FILES[$i]}.xz"|"${MODULE_FILES[$i]}.zst") ;;
            *) return 1 ;;
        esac
        [[ -f "${target}" && ! -L "${target}" ]] || return 1
        validate_module_file "${target}" "${MODULE_NAMES[$i]}" || return 1
        for field in name version vermagic srcversion; do
            [[ "$(modinfo -F "${field}" -- "${target}" 2>/dev/null)" == \
               "$(modinfo -F "${field}" -- "${build}" 2>/dev/null)" ]] || return 1
        done
        if (( i == 0 )); then
            provenance="$(inspect_module_provenance "${target}")" || return 1
            [[ "${provenance}" == "clean" ]] || return 1
        fi
        target_payload="$(module_payload_sha256 "${target}")" || return 1
        build_payload="$(module_payload_sha256 "${build}")" || return 1
        [[ "${target_payload}" == "${build_payload}" ]] || return 1
        target_raw="$(/usr/bin/sha256sum -- "${target}")" || return 1
        target_raw="${target_raw%% *}"
        build_raw="$(/usr/bin/sha256sum -- "${build}")" || return 1
        build_raw="${build_raw%% *}"
        [[ "${target_raw}" =~ ^[0-9a-f]{64}$ && "${build_raw}" =~ ^[0-9a-f]{64}$ ]] || return 1
        DKMS_TARGET_CLEANUP_RECORDS+=(
            "$(basename -- "${target}"):${target_raw}:$(basename -- "${build}"):${build_raw}"
        )
    done
}

cleanup_exact_dkms_target_artifacts() {
    validate_remaining_dkms_target_bindings remaining || return 1
    python3 - "${MODULE_ROOT}" \
        "${DKMS_TREE}/nvidia/${detected}/${KVER}/${DKMS_ARCH}/module" \
        "${#MODULE_FILES[@]}" "${MODULE_FILES[@]}" \
        "${DKMS_TARGET_CLEANUP_RECORDS[@]}" <<'PY'
import gzip
import hashlib
import lzma
import os
import pathlib
import stat
import subprocess
import sys

module_root = pathlib.Path(sys.argv[1])
build_dir = pathlib.Path(sys.argv[2])
module_count = int(sys.argv[3])
module_files = tuple(sys.argv[4:4 + module_count])
raw_records = sys.argv[4 + module_count:]
suffixes = ("", ".gz", ".xz", ".zst")
allowed = {name + suffix for name in module_files for suffix in suffixes}
records = {}
for raw in raw_records:
    fields = raw.split(":")
    if len(fields) != 4:
        raise SystemExit("malformed exact DKMS cleanup record")
    target_name, target_hash, build_name, build_hash = fields
    if (target_name in records or target_name not in allowed or build_name not in allowed
            or len(target_hash) != 64 or len(build_hash) != 64
            or any(c not in "0123456789abcdef" for c in target_hash + build_hash)):
        raise SystemExit("invalid exact DKMS cleanup record")
    target_base = next((base for base in module_files if target_name in {
        base + suffix for suffix in suffixes
    }), None)
    build_base = next((base for base in module_files if build_name in {
        base + suffix for suffix in suffixes
    }), None)
    if target_base is None or target_base != build_base:
        raise SystemExit("mismatched exact DKMS cleanup record")
    records[target_name] = (target_hash, build_name, build_hash)
dir_flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
             | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)

def validate_dir(fd, label, device=None):
    st = os.fstat(fd)
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022
            or (device is not None and st.st_dev != device)):
        raise SystemExit(f"unsafe module directory before exact DKMS cleanup: {label}")
    return st

def open_dir(parent_fd, name, label, device):
    try:
        fd = os.open(name, dir_flags, dir_fd=parent_fd)
    except FileNotFoundError:
        return None
    validate_dir(fd, label, device)
    return fd

def decode_mount_path(field, number):
    decoded = bytearray()
    index = 0
    while index < len(field):
        if field[index] != 0x5c:
            decoded.append(field[index])
            index += 1
            continue
        escaped = field[index + 1:index + 4]
        if len(escaped) != 3 or any(byte not in b"01234567" for byte in escaped):
            raise SystemExit(f"malformed mountinfo escape on line {number}")
        decoded.append(int(escaped, 8))
        index += 4
    return bytes(decoded)

def reject_cleanup_mounts(paths, roots):
    exact = {os.path.normpath(os.fsencode(path)) for path in paths}
    prefixes = tuple(
        os.path.normpath(os.fsencode(root)).rstrip(b"/") + b"/" for root in roots
    )
    with open("/proc/self/mountinfo", "rb") as stream:
        lines = stream.read().splitlines()
    if not lines:
        raise SystemExit("empty mountinfo before exact DKMS target cleanup")
    for number, line in enumerate(lines, 1):
        if line.count(b" - ") != 1:
            raise SystemExit(f"malformed mountinfo separator on line {number}")
        fields = line.split(b" - ", 1)[0].split()
        if len(fields) < 6:
            raise SystemExit(f"malformed mountinfo record on line {number}")
        mountpoint = os.path.normpath(decode_mount_path(fields[4], number))
        if not os.path.isabs(mountpoint):
            raise SystemExit(f"non-absolute mountinfo path on line {number}")
        if mountpoint in exact or any(mountpoint.startswith(prefix) for prefix in prefixes):
            raise SystemExit(
                f"mountpoint intersects exact DKMS cleanup: {os.fsdecode(mountpoint)}"
            )

def hash_stream(stream, limit=512 * 1024 * 1024):
    digest = hashlib.sha256()
    total = 0
    while True:
        block = stream.read(1024 * 1024)
        if not block:
            break
        total += len(block)
        if total > limit:
            raise SystemExit("decompressed DKMS module exceeds the safety bound")
        digest.update(block)
    return digest.hexdigest()

def payload_hash(fd, name, raw_hash):
    if name.endswith(".ko"):
        return raw_hash
    os.lseek(fd, 0, os.SEEK_SET)
    raw = os.fdopen(os.dup(fd), "rb", closefd=True)
    try:
        if name.endswith(".ko.gz"):
            with gzip.GzipFile(fileobj=raw, mode="rb") as stream:
                return hash_stream(stream)
        if name.endswith(".ko.xz"):
            with lzma.LZMAFile(raw, mode="rb") as stream:
                return hash_stream(stream)
        if name.endswith(".ko.zst"):
            zstd = pathlib.Path("/usr/bin/zstdcat").resolve(strict=True)
            zst = os.lstat(zstd)
            if (not stat.S_ISREG(zst.st_mode) or stat.S_ISLNK(zst.st_mode)
                    or zst.st_uid != 0 or zst.st_gid != 0
                    or stat.S_IMODE(zst.st_mode) & 0o022 or not os.access(zstd, os.X_OK)):
                raise SystemExit("unsafe zstd decompressor")
            process = subprocess.Popen(
                [str(zstd), "-d", "-c", "--"], stdin=raw, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, close_fds=True,
                env={"PATH": "/usr/bin:/usr/sbin:/bin:/sbin", "HOME": "/root",
                     "LC_ALL": "C", "LANG": "C"},
            )
            raw.close()
            raw = None
            assert process.stdout is not None
            try:
                digest = hash_stream(process.stdout)
            finally:
                process.stdout.close()
            if process.wait() != 0:
                raise SystemExit("could not decompress exact DKMS zstd module")
            return digest
        raise SystemExit("unsupported exact DKMS module suffix")
    finally:
        if raw is not None:
            raw.close()

def open_hashed_leaf(parent_fd, name, expected_hash, label, device):
    before_name = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    fd = os.open(name, file_flags, dir_fd=parent_fd)
    try:
        before = os.fstat(fd)
        if ((before.st_dev, before.st_ino) != (before_name.st_dev, before_name.st_ino)
                or not stat.S_ISREG(before.st_mode) or before.st_uid != 0
                or before.st_gid != 0 or before.st_nlink != 1
                or stat.S_IMODE(before.st_mode) & 0o022
                or (device is not None and before.st_dev != device)):
            raise SystemExit(f"unsafe exact DKMS module leaf: {label}")
        digest = hashlib.sha256()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            digest.update(block)
        after = os.fstat(fd)
        stable = (
            after.st_dev, after.st_ino, after.st_mode, after.st_uid,
            after.st_gid, after.st_nlink, after.st_size,
            after.st_mtime_ns, after.st_ctime_ns
        ) == (
            before.st_dev, before.st_ino, before.st_mode, before.st_uid,
            before.st_gid, before.st_nlink, before.st_size,
            before.st_mtime_ns, before.st_ctime_ns
        )
        raw_hash = digest.hexdigest()
        if not stable or raw_hash != expected_hash:
            raise SystemExit(f"exact DKMS module bytes changed before cleanup: {label}")
        payload = payload_hash(fd, name, raw_hash)
        final = os.fstat(fd)
        final_identity = (
            final.st_dev, final.st_ino, final.st_mode, final.st_uid,
            final.st_gid, final.st_nlink, final.st_size,
            final.st_mtime_ns, final.st_ctime_ns
        )
        before_identity = (
            before.st_dev, before.st_ino, before.st_mode, before.st_uid,
            before.st_gid, before.st_nlink, before.st_size,
            before.st_mtime_ns, before.st_ctime_ns
        )
        if final_identity != before_identity:
            raise SystemExit(f"exact DKMS module changed during payload hashing: {label}")
        return fd, before, payload
    except BaseException:
        os.close(fd)
        raise

root_fd = os.open(module_root, dir_flags)
root_st = validate_dir(root_fd, module_root)
if module_root.resolve(strict=True) != module_root:
    raise SystemExit(f"module root has a symlinked path component: {module_root}")
device = root_st.st_dev
updates = module_root / "updates"
target = updates / "dkms"
updates_fd = open_dir(root_fd, "updates", updates, device)
if updates_fd is None:
    os.fsync(root_fd)
    raise SystemExit(0)
target_fd = open_dir(updates_fd, "dkms", target, device)
if target_fd is None:
    if records:
        raise SystemExit("recorded exact DKMS targets disappeared before cleanup")
    os.fsync(updates_fd)
    os.fsync(root_fd)
    raise SystemExit(0)

build_fd = None
if records:
    build_fd = os.open(build_dir, dir_flags)
    validate_dir(build_fd, build_dir)
    if build_dir.resolve(strict=True) != build_dir:
        raise SystemExit(f"DKMS build directory has a symlinked path component: {build_dir}")

cleanup_paths = (module_root, updates, target, build_dir) if records else (module_root, updates, target)
cleanup_roots = (target, build_dir) if records else (target,)
reject_cleanup_mounts(cleanup_paths, cleanup_roots)
inventory = {}
counts = {name: 0 for name in module_files}
for parent, dirs, files in os.walk(target, topdown=True, followlinks=False):
    parent_path = pathlib.Path(parent)
    for name in dirs + files:
        matched = [base for base in module_files if name.startswith(base)]
        if not matched:
            continue
        path = parent_path / name
        if parent_path != target or name not in allowed or len(matched) != 1:
            raise SystemExit(f"ambiguous NVIDIA .ko* artifact before cleanup: {path}")
        base = matched[0]
        counts[base] += 1
        if counts[base] != 1:
            raise SystemExit(f"multiple exact DKMS target variants for {base}")
        st = os.stat(name, dir_fd=target_fd, follow_symlinks=False)
        if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
                or st.st_dev != device or st.st_uid != 0 or st.st_gid != 0
                or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) & 0o022):
            raise SystemExit(f"unsafe exact DKMS target artifact: {path}")
        inventory[name] = st

if set(inventory) != set(records):
    raise SystemExit("exact DKMS target inventory changed after byte binding")
reject_cleanup_mounts(cleanup_paths, cleanup_roots)
for name in sorted(records):
    target_hash, build_name, build_hash = records[name]
    build_leaf, build_opened, build_payload = open_hashed_leaf(
        build_fd, build_name, build_hash, build_dir / build_name, None
    )
    try:
        target_leaf, target_opened, target_payload = open_hashed_leaf(
            target_fd, name, target_hash, target / name, device
        )
        try:
            if target_payload != build_payload:
                raise SystemExit(f"DKMS target payload is not bound to B/module: {target / name}")
            for parent_fd, leaf_name, opened, label in (
                (build_fd, build_name, build_opened, build_dir / build_name),
                (target_fd, name, target_opened, target / name),
            ):
                current = os.stat(leaf_name, dir_fd=parent_fd, follow_symlinks=False)
                now = os.fstat(build_leaf if parent_fd == build_fd else target_leaf)
                if ((current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
                        or (now.st_dev, now.st_ino, now.st_mode, now.st_uid,
                            now.st_gid, now.st_nlink, now.st_size,
                            now.st_mtime_ns, now.st_ctime_ns) !=
                           (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid,
                            opened.st_gid, opened.st_nlink, opened.st_size,
                            opened.st_mtime_ns, opened.st_ctime_ns)):
                    raise SystemExit(f"exact DKMS module changed immediately before cleanup: {label}")
            os.unlink(name, dir_fd=target_fd)
            os.fsync(target_fd)
        finally:
            os.close(target_leaf)
    finally:
        os.close(build_leaf)
os.fsync(updates_fd)
os.fsync(root_fd)
PY
}

seal_no_dkms_module_artifacts() {
    python3 - "${MODULE_ROOT}" "${MODULE_FILES[@]}" <<'PY'
import os
import pathlib
import stat
import sys

module_root = pathlib.Path(sys.argv[1])
module_files = sys.argv[2:]
dir_flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
             | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))

def validate_dir(fd, label, device):
    st = os.fstat(fd)
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022 or st.st_dev != device):
        raise SystemExit(f"unsafe module directory while sealing DKMS absence: {label}")
    return st

def open_dir(parent_fd, name, label, device):
    try:
        fd = os.open(name, dir_flags, dir_fd=parent_fd)
    except FileNotFoundError:
        return None
    validate_dir(fd, label, device)
    return fd

def scan_and_fsync(fd, label, device):
    for name in os.listdir(fd):
        path = label / name
        st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if any(name.startswith(prefix) for prefix in module_files):
            raise SystemExit(f"ambiguous NVIDIA module artifact remains: {path}")
        if stat.S_ISDIR(st.st_mode):
            child = os.open(name, dir_flags, dir_fd=fd)
            try:
                opened = validate_dir(child, path, device)
                if (opened.st_dev, opened.st_ino) != (st.st_dev, st.st_ino):
                    raise SystemExit(f"module directory changed while sealing absence: {path}")
                scan_and_fsync(child, path, device)
            finally:
                os.close(child)
    os.fsync(fd)
    if any(any(name.startswith(prefix) for prefix in module_files)
           for name in os.listdir(fd)):
        raise SystemExit(f"NVIDIA module artifact appeared while sealing absence: {label}")

root_fd = os.open(module_root, dir_flags)
root_st = os.fstat(root_fd)
if (not stat.S_ISDIR(root_st.st_mode) or root_st.st_uid != 0 or root_st.st_gid != 0
        or stat.S_IMODE(root_st.st_mode) & 0o022):
    raise SystemExit(f"unsafe canonical module root: {module_root}")
if module_root.resolve(strict=True) != module_root:
    raise SystemExit(f"module root has a symlinked path component: {module_root}")
device = root_st.st_dev
updates_path = module_root / "updates"
updates_fd = open_dir(root_fd, "updates", updates_path, device)
if updates_fd is None:
    os.fsync(root_fd)
    raise SystemExit(0)
dkms_path = updates_path / "dkms"
dkms_fd = open_dir(updates_fd, "dkms", dkms_path, device)
if dkms_fd is None:
    os.fsync(updates_fd)
    os.fsync(root_fd)
    raise SystemExit(0)
scan_and_fsync(dkms_fd, dkms_path, device)
os.fsync(updates_fd)
os.fsync(root_fd)
PY
}

cleanup_exact_dkms_tuple_tree() {
    python3 - "${DKMS_TREE}" nvidia "${detected}" "${KVER}" "${DKMS_ARCH}" <<'PY'
import errno
import os
import pathlib
import re
import stat
import sys

tree = pathlib.Path(sys.argv[1])
module, version, kver, arch = sys.argv[2:6]
if (module != "nvidia" or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
        or not re.fullmatch(r"[A-Za-z0-9._+-]+", kver)
        or not re.fullmatch(r"[A-Za-z0-9._+-]+", arch)):
    raise SystemExit("unsafe exact DKMS tuple identity")

dir_flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
             | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))

def decode_mountinfo_path(field, number):
    decoded = bytearray()
    index = 0
    while index < len(field):
        if field[index] != 0x5C:
            decoded.append(field[index])
            index += 1
            continue
        escaped = field[index + 1:index + 4]
        if len(escaped) != 3 or any(byte not in b"01234567" for byte in escaped):
            raise SystemExit(f"malformed mountinfo escape on line {number}")
        decoded.append(int(escaped, 8))
        index += 4
    return bytes(decoded)

def reject_cleanup_mounts(ancestor_paths, cleanup_root):
    ancestors = {os.path.normpath(os.fsencode(path)) for path in ancestor_paths}
    root = os.path.normpath(os.fsencode(cleanup_root))
    if not os.path.isabs(root) or any(not os.path.isabs(path) for path in ancestors):
        raise SystemExit("DKMS cleanup authority contains a non-absolute path")
    prefix = root.rstrip(b"/") + b"/"
    try:
        with open("/proc/self/mountinfo", "rb") as stream:
            lines = stream.read().splitlines()
    except OSError as error:
        raise SystemExit(f"cannot inspect mount topology before DKMS cleanup: {error}")
    if not lines:
        raise SystemExit("empty mountinfo before DKMS cleanup")
    for number, line in enumerate(lines, 1):
        if line.count(b" - ") != 1:
            raise SystemExit(f"malformed mountinfo separator on line {number}")
        fields = line.split(b" - ", 1)[0].split()
        if len(fields) < 6:
            raise SystemExit(f"malformed mountinfo record on line {number}")
        mountpoint = os.path.normpath(decode_mountinfo_path(fields[4], number))
        if not os.path.isabs(mountpoint):
            raise SystemExit(f"non-absolute mountinfo path on line {number}")
        if (mountpoint in ancestors or mountpoint == root
                or mountpoint.startswith(prefix)):
            label = os.fsdecode(mountpoint)
            raise SystemExit(f"mountpoint inside exact DKMS cleanup root: {label}")

def validate_dir(fd, label, device):
    st = os.fstat(fd)
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022 or st.st_dev != device):
        raise SystemExit(f"unsafe DKMS directory: {label}")
    return st

def open_dir(parent_fd, name, label, device, required=False):
    try:
        fd = os.open(name, dir_flags, dir_fd=parent_fd)
    except FileNotFoundError:
        if required:
            raise SystemExit(f"required DKMS directory is missing: {label}")
        return None
    validate_dir(fd, label, device)
    return fd

def lstat_at(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None

def revalidate_open_dir(fd, label, device):
    opened = validate_dir(fd, label, device)
    try:
        current = os.stat(label, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(f"opened DKMS directory disappeared before cleanup: {label}")
    if (not stat.S_ISDIR(current.st_mode)
            or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)):
        raise SystemExit(f"opened DKMS directory changed before cleanup: {label}")

def validate_entry(st, label, device):
    if st.st_dev != device or st.st_uid != 0 or st.st_gid != 0:
        raise SystemExit(f"unsafe DKMS tuple ownership or filesystem: {label}")
    if stat.S_IMODE(st.st_mode) & 0o022:
        raise SystemExit(f"writable DKMS tuple object: {label}")
    if stat.S_ISREG(st.st_mode):
        if st.st_nlink != 1:
            raise SystemExit(f"hardlinked DKMS tuple object: {label}")
    elif not stat.S_ISDIR(st.st_mode):
        raise SystemExit(f"symlink or special object inside DKMS tuple: {label}")

def validate_subtree(fd, label, device):
    for name in os.listdir(fd):
        child_label = label / name
        before = os.stat(name, dir_fd=fd, follow_symlinks=False)
        validate_entry(before, child_label, device)
        if stat.S_ISDIR(before.st_mode):
            child = os.open(name, dir_flags, dir_fd=fd)
            try:
                opened = validate_dir(child, child_label, device)
                if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                    raise SystemExit(f"DKMS directory changed during validation: {child_label}")
                validate_subtree(child, child_label, device)
            finally:
                os.close(child)

def delete_subtree(fd, label, device):
    for name in os.listdir(fd):
        child_label = label / name
        before = os.stat(name, dir_fd=fd, follow_symlinks=False)
        validate_entry(before, child_label, device)
        if stat.S_ISDIR(before.st_mode):
            child = os.open(name, dir_flags, dir_fd=fd)
            try:
                opened = validate_dir(child, child_label, device)
                if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                    raise SystemExit(f"DKMS directory changed before cleanup: {child_label}")
                delete_subtree(child, child_label, device)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=fd)
        else:
            current = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if (current.st_dev, current.st_ino, current.st_size,
                    current.st_mtime_ns, current.st_ctime_ns) != (
                    before.st_dev, before.st_ino, before.st_size,
                    before.st_mtime_ns, before.st_ctime_ns):
                raise SystemExit(f"DKMS tuple file changed before cleanup: {child_label}")
            os.unlink(name, dir_fd=fd)
        os.fsync(fd)

try:
    tree_fd = os.open(tree, dir_flags)
except FileNotFoundError:
    raise SystemExit(f"DKMS tree disappeared while a cleanup receipt exists: {tree}")
tree_st = os.fstat(tree_fd)
if (not stat.S_ISDIR(tree_st.st_mode) or tree_st.st_uid != 0 or tree_st.st_gid != 0
        or stat.S_IMODE(tree_st.st_mode) & 0o022):
    raise SystemExit(f"unsafe DKMS tree: {tree}")
if tree.resolve(strict=True) != tree:
    raise SystemExit(f"DKMS tree has a symlinked path component: {tree}")
device = tree_st.st_dev
module_path = tree / module
version_path = module_path / version
kver_path = version_path / kver
base_path = kver_path / arch
mount_ancestors = (tree, module_path, version_path, kver_path)
reject_cleanup_mounts(mount_ancestors, base_path)
module_fd = open_dir(tree_fd, module, module_path, device, required=True)
version_fd = open_dir(module_fd, version, version_path, device, required=True)

# A format=1 receipt is issued only when DKMS has no current-kernel original
# backups.  If that invariant is violated, do not guess whether a payload was
# restored: preserve everything and fail before touching the tuple tree.
original_fd = open_dir(module_fd, "original_module", module_path / "original_module", device)
original_kver_fd = None
if original_fd is None:
    os.fsync(module_fd)
else:
    original_kver_fd = open_dir(
        original_fd, kver, module_path / "original_module" / kver, device
    )
    if original_kver_fd is None:
        os.fsync(original_fd)
    elif lstat_at(original_kver_fd, arch) is not None:
        raise SystemExit(
            f"unsupported DKMS original-module state remains for {kver}/{arch}"
        )
    else:
        os.fsync(original_kver_fd)

active_name = f"kernel-{kver}-{arch}"
active_st = lstat_at(module_fd, active_name)
active_target = None
if active_st is None:
    os.fsync(module_fd)
else:
    if (not stat.S_ISLNK(active_st.st_mode) or active_st.st_uid != 0
            or active_st.st_gid != 0 or active_st.st_nlink != 1):
        raise SystemExit(f"unsafe exact DKMS active link: {module_path / active_name}")
    active_target = os.readlink(active_name, dir_fd=module_fd)
    if active_target not in (f"{version}/{kver}/{arch}", str(base_path)):
        raise SystemExit(f"DKMS active link targets another tuple: {module_path / active_name}")

kver_fd = open_dir(version_fd, kver, kver_path, device)
base_fd = None
if kver_fd is None:
    os.fsync(version_fd)
else:
    base_fd = open_dir(kver_fd, arch, base_path, device)
    if base_fd is None:
        os.fsync(kver_fd)
    else:
        validate_subtree(base_fd, base_path, device)

# All exact parents, active/original absence, and every object below B were
# proven before the first unlink.  Recheck the decoded mount topology after
# subtree validation, then revalidate L and delete only exact L/B.
reject_cleanup_mounts(mount_ancestors, base_path)
for directory_fd, directory_path in (
        (tree_fd, tree), (module_fd, module_path), (version_fd, version_path),
        (original_fd, module_path / "original_module"),
        (original_kver_fd, module_path / "original_module" / kver),
        (kver_fd, kver_path), (base_fd, base_path)):
    if directory_fd is not None:
        revalidate_open_dir(directory_fd, directory_path, device)
if active_st is not None:
    current_active = lstat_at(module_fd, active_name)
    if (current_active is None or not stat.S_ISLNK(current_active.st_mode)
            or (current_active.st_dev, current_active.st_ino,
                current_active.st_uid, current_active.st_gid,
                current_active.st_nlink) != (
                active_st.st_dev, active_st.st_ino, active_st.st_uid,
                active_st.st_gid, active_st.st_nlink)
            or os.readlink(active_name, dir_fd=module_fd) != active_target):
        raise SystemExit("exact DKMS active link changed before cleanup")
    os.unlink(active_name, dir_fd=module_fd)
    os.fsync(module_fd)
if base_fd is not None:
    delete_subtree(base_fd, base_path, device)
    os.close(base_fd)
    base_fd = None
    os.rmdir(arch, dir_fd=kver_fd)
    os.fsync(kver_fd)
if kver_fd is not None:
    if not os.listdir(kver_fd):
        os.close(kver_fd)
        kver_fd = None
        os.rmdir(kver, dir_fd=version_fd)
        os.fsync(version_fd)
    else:
        os.fsync(kver_fd)

# A successful retry seals any unlink completed just before an earlier hard
# cut, including the case where sibling arches keep the parent nonempty.
os.fsync(version_fd)
os.fsync(module_fd)
os.fsync(tree_fd)
if lstat_at(module_fd, active_name) is not None:
    raise SystemExit("exact DKMS active link reappeared during cleanup")
if original_kver_fd is not None and lstat_at(original_kver_fd, arch) is not None:
    raise SystemExit("exact DKMS original-module state reappeared during cleanup")
if kver_fd is not None and lstat_at(kver_fd, arch) is not None:
    raise SystemExit("exact DKMS tuple base remains after cleanup")
PY
}

load_stock_module_set() {
    local i candidate candidate_dir entry canonical basename last_index
    local -a discovered=()
    local -A selected=() seen=()
    STOCK_MODULE_PATHS=()
    for i in "${!MODULE_NAMES[@]}"; do
        find_stock_module "${MODULE_FILES[$i]}" "${MODULE_NAMES[$i]}" || return 1
        STOCK_MODULE_PATHS+=("${FOUND_STOCK_MODULE}")
    done

    # A fallback is only coherent when all five modules are the complete
    # contents of one physical package directory.  Mixing individually valid
    # files from different packages would make rollback non-deterministic.
    STOCK_MODULE_SET_DIR="$(readlink -f -- "$(dirname -- "${STOCK_MODULE_PATHS[0]}")" 2>/dev/null || true)"
    [[ -n "${STOCK_MODULE_SET_DIR}" && -d "${STOCK_MODULE_SET_DIR}" &&
       ! -L "${STOCK_MODULE_SET_DIR}" ]] || return 1
    for candidate in "${STOCK_MODULE_PATHS[@]}"; do
        candidate_dir="$(readlink -f -- "$(dirname -- "${candidate}")" 2>/dev/null || true)"
        [[ "${candidate_dir}" == "${STOCK_MODULE_SET_DIR}" ]] || {
            err "Stock NVIDIA fallback spans multiple physical directories"
            return 1
        }
        selected["${candidate}"]=1
    done

    directory_tree_is_regular_only "${STOCK_MODULE_SET_DIR}" || return 1
    mapfile -d '' -t discovered < <(
        find -P "${STOCK_MODULE_SET_DIR}" -type f \
            \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
            -print0 && printf '%s\0' '__CMPUNLOCKER_FIND_OK__'
    )
    (( ${#discovered[@]} >= 1 )) || return 1
    last_index=$(( ${#discovered[@]} - 1 ))
    [[ "${discovered[$last_index]}" == '__CMPUNLOCKER_FIND_OK__' ]] || return 1
    unset 'discovered[last_index]'
    (( ${#discovered[@]} == ${#MODULE_FILES[@]} )) || {
        err "Stock fallback directory must contain exactly five kernel modules: ${STOCK_MODULE_SET_DIR}"
        return 1
    }
    for entry in "${discovered[@]}"; do
        [[ -f "${entry}" && ! -L "${entry}" ]] || {
            err "Stock fallback contains a symlink or non-regular module: ${entry}"
            return 1
        }
        canonical="$(readlink -f -- "${entry}" 2>/dev/null || true)"
        [[ "${canonical}" == "${entry}" ]] || return 1
        basename="$(basename -- "${entry}")"
        case "${basename}" in
            nvidia.ko|nvidia.ko.gz|nvidia.ko.xz|nvidia.ko.zst|\
            nvidia-modeset.ko|nvidia-modeset.ko.gz|nvidia-modeset.ko.xz|nvidia-modeset.ko.zst|\
            nvidia-uvm.ko|nvidia-uvm.ko.gz|nvidia-uvm.ko.xz|nvidia-uvm.ko.zst|\
            nvidia-drm.ko|nvidia-drm.ko.gz|nvidia-drm.ko.xz|nvidia-drm.ko.zst|\
            nvidia-peermem.ko|nvidia-peermem.ko.gz|nvidia-peermem.ko.xz|nvidia-peermem.ko.zst) ;;
            *) return 1 ;;
        esac
        [[ -n "${selected[${canonical}]:-}" && -z "${seen[${canonical}]:-}" ]] || return 1
        seen["${canonical}"]=1
    done
    (( ${#seen[@]} == ${#STOCK_MODULE_PATHS[@]} ))
}

resolve_module_set() {
    local i resolved canonical
    RESOLVED_MODULE_PATHS=()
    CMP_RESOLUTION_EXACT=1
    for i in "${!MODULE_NAMES[@]}"; do
        if ! resolved="$(modinfo -k "${KVER}" -n "${MODULE_NAMES[$i]}" 2>/dev/null)"; then
            return 1
        fi
        [[ -n "${resolved}" ]] || return 1
        canonical="$(readlink -f -- "${resolved}" 2>/dev/null || true)"
        [[ -n "${canonical}" && -f "${canonical}" ]] || return 1
        RESOLVED_MODULE_PATHS+=("${canonical}")
        if [[ "${canonical}" != "${MODULE_DIR}/${MODULE_FILES[$i]}" ]]; then
            CMP_RESOLUTION_EXACT=0
        fi
    done
}

verify_cmp_physical_set() {
    local phase="${1:-legacy}"
    local i expected canonical entry last_index
    local -a discovered=()
    local -A expected_paths=()
    directory_tree_is_regular_only "${MODULE_DIR}" || return 1
    # build.sh uses this marker only inside a private staged directory.  Its
    # presence in the live directory means publication did not reach a clean
    # commit, even though the marker itself is a regular file.
    [[ ! -e "${MODULE_DIR}/.cmpunlocker-transaction" &&
       ! -L "${MODULE_DIR}/.cmpunlocker-transaction" ]] || return 1
    mapfile -d '' -t discovered < <(
        find -P "${MODULE_DIR}" -type f \
            \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
            -print0 && printf '%s\0' '__CMPUNLOCKER_FIND_OK__'
    )
    (( ${#discovered[@]} >= 1 )) || return 1
    last_index=$(( ${#discovered[@]} - 1 ))
    [[ "${discovered[$last_index]}" == '__CMPUNLOCKER_FIND_OK__' ]] || return 1
    unset 'discovered[last_index]'
    (( ${#discovered[@]} == ${#MODULE_FILES[@]} )) || return 1
    for i in "${!MODULE_FILES[@]}"; do
        expected_paths["${MODULE_DIR}/${MODULE_FILES[$i]}"]=1
    done
    for entry in "${discovered[@]}"; do
        [[ -n "${expected_paths[${entry}]:-}" ]] || return 1
    done
    for i in "${!MODULE_NAMES[@]}"; do
        expected="${MODULE_DIR}/${MODULE_FILES[$i]}"
        [[ -f "${expected}" && ! -L "${expected}" ]] || return 1
        canonical="$(readlink -f -- "${expected}" 2>/dev/null || true)"
        [[ "${canonical}" == "${expected}" ]] || return 1
        validate_module_file "${expected}" "${MODULE_NAMES[$i]}" || return 1
        if (( i == 0 )); then
            grep -aFq 'CMP Gen2:' "${expected}" || return 1
            if [[ "${phase}" == "safe" ]]; then
                grep -aFq 'cmpunlocker-safety-v3' "${expected}" || return 1
            fi
        fi
    done
}

load_gen2_receipt() {
    local file="$1"
    local prefix="$2"
    local -a lines=()
    local unit_hash hammer_hash modprobe_hash
    read_secure_state_lines "${file}" lines || return 1
    (( ${#lines[@]} == 7 )) || return 1
    [[ "${lines[0]}" == "format=1" &&
       "${lines[1]}" == "unit_path=${GEN2_UNIT_PATH}" &&
       "${lines[3]}" == "hammer_path=${GEN2_HAMMER_PATH}" &&
       "${lines[5]}" == "modprobe_path=${GEN2_MODPROBE_PATH}" ]] || return 1
    unit_hash="${lines[2]#unit_sha256=}"
    hammer_hash="${lines[4]#hammer_sha256=}"
    modprobe_hash="${lines[6]#modprobe_sha256=}"
    [[ "${lines[2]}" == unit_sha256=* && "${lines[4]}" == hammer_sha256=* &&
       "${lines[6]}" == modprobe_sha256=* ]] || return 1
    [[ "${unit_hash}" =~ ^([0-9a-f]{64}|absent)$ &&
       "${hammer_hash}" =~ ^([0-9a-f]{64}|absent)$ &&
       "${modprobe_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf -v "${prefix}_UNIT_HASH" '%s' "${unit_hash}"
    printf -v "${prefix}_HAMMER_HASH" '%s' "${hammer_hash}"
    printf -v "${prefix}_MODPROBE_HASH" '%s' "${modprobe_hash}"
}

gen2_target_matches() {
    local path="$1"
    shift
    local expected actual
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        for expected in "$@"; do
            [[ "${expected}" == "absent" ]] && return 0
        done
        return 1
    fi
    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    actual="$(file_hash "${path}")" || return 1
    for expected in "$@"; do
        [[ "${actual}" == "${expected}" ]] && return 0
    done
    return 1
}

preflight_target_parent() {
    local target="$1"
    local parent
    parent="$(dirname "${target}")"
    [[ -d "${parent}" && ! -L "${parent}" && -w "${parent}" ]]
}

for legacy_path in /etc/systemd/system/cmpretrain.service \
                   /etc/systemd/system/cmp-gen2-retrain.service \
                   /usr/local/sbin/retrain.sh \
                   /usr/local/sbin/cmp-gen2-retrain.sh; do
    [[ ! -e "${legacy_path}" && ! -L "${legacy_path}" ]] || \
        die "Ambiguous legacy Gen2 helper exists; remove it manually before installing: ${legacy_path}"
done
[[ -f "${GEN2_UNIT_SOURCE}" && ! -L "${GEN2_UNIT_SOURCE}" ]] || die "Missing safe Gen2 unit source"
[[ -f "${GEN2_HAMMER_SOURCE}" && ! -L "${GEN2_HAMMER_SOURCE}" ]] || die "Missing safe Gen2 helper source"
GEN2_REPO_UNIT_HASH="$(file_hash "${GEN2_UNIT_SOURCE}")"
GEN2_REPO_HAMMER_HASH="$(file_hash "${GEN2_HAMMER_SOURCE}")"
GEN2_REPO_MODPROBE_HASH="$(text_hash "${GEN2_MODPROBE_CONTENT}")"
GEN2_LEGACY_MODPROBE_CONTENT=$'options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"\n'
GEN2_LEGACY_MODPROBE_HASH="$(text_hash "${GEN2_LEGACY_MODPROBE_CONTENT}")"
GEN2_STATE_PRESENT=0
GEN2_PENDING_PRESENT=0
if [[ -e "${GEN2_STATE}" || -L "${GEN2_STATE}" ]]; then
    load_gen2_receipt "${GEN2_STATE}" GEN2_OLD || die "Invalid Gen2 ownership receipt: ${GEN2_STATE}"
    GEN2_STATE_PRESENT=1
fi
if [[ -e "${GEN2_PENDING}" || -L "${GEN2_PENDING}" ]]; then
    load_gen2_receipt "${GEN2_PENDING}" GEN2_NEXT || die "Invalid Gen2 pending receipt: ${GEN2_PENDING}"
    GEN2_PENDING_PRESENT=1
fi
if (( GEN2_PENDING_PRESENT == 1 )); then
    (( GEN2_STATE_PRESENT == 1 )) && old_unit="${GEN2_OLD_UNIT_HASH}" || old_unit="absent"
    (( GEN2_STATE_PRESENT == 1 )) && old_hammer="${GEN2_OLD_HAMMER_HASH}" || old_hammer="absent"
    (( GEN2_STATE_PRESENT == 1 )) && old_modprobe="${GEN2_OLD_MODPROBE_HASH}" || old_modprobe="absent"
    gen2_target_matches "${GEN2_UNIT_PATH}" "${old_unit}" "${GEN2_NEXT_UNIT_HASH}" || \
        die "Gen2 unit changed outside its pending ownership transaction"
    gen2_target_matches "${GEN2_HAMMER_PATH}" "${old_hammer}" "${GEN2_NEXT_HAMMER_HASH}" || \
        die "Gen2 helper changed outside its pending ownership transaction"
    gen2_target_matches "${GEN2_MODPROBE_PATH}" "${old_modprobe}" "${GEN2_NEXT_MODPROBE_HASH}" || \
        die "Gen2 modprobe config changed outside its pending ownership transaction"
else
    if (( GEN2_STATE_PRESENT == 1 )); then
        gen2_target_matches "${GEN2_UNIT_PATH}" "${GEN2_OLD_UNIT_HASH}" || die "Owned Gen2 unit hash conflict"
        gen2_target_matches "${GEN2_HAMMER_PATH}" "${GEN2_OLD_HAMMER_HASH}" || die "Owned Gen2 helper hash conflict"
        gen2_target_matches "${GEN2_MODPROBE_PATH}" "${GEN2_OLD_MODPROBE_HASH}" || die "Owned Gen2 modprobe hash conflict"
    else
        if gen2_target_matches "${GEN2_UNIT_PATH}" "${GEN2_REPO_UNIT_HASH}" &&
           gen2_target_matches "${GEN2_HAMMER_PATH}" "${GEN2_REPO_HAMMER_HASH}" &&
           gen2_target_matches "${GEN2_MODPROBE_PATH}" "${GEN2_LEGACY_MODPROBE_HASH}"; then
            GEN2_ADOPT_CONTENT="$(printf 'format=1\nunit_path=%s\nunit_sha256=%s\nhammer_path=%s\nhammer_sha256=%s\nmodprobe_path=%s\nmodprobe_sha256=%s\n' \
                "${GEN2_UNIT_PATH}" "${GEN2_REPO_UNIT_HASH}" \
                "${GEN2_HAMMER_PATH}" "${GEN2_REPO_HAMMER_HASH}" \
                "${GEN2_MODPROBE_PATH}" "${GEN2_LEGACY_MODPROBE_HASH}")"$'\n'
            atomic_write_text "${GEN2_STATE}" 0600 "${GEN2_ADOPT_CONTENT}" || \
                die "Could not durably adopt the exact known legacy Gen2 assets"
            load_gen2_receipt "${GEN2_STATE}" GEN2_OLD || die "Internal Gen2 adoption receipt error"
            GEN2_STATE_PRESENT=1
            ok "Adopted three byte-exact known legacy Gen2 assets into durable ownership state"
        else
            for unmanaged_target in "${GEN2_UNIT_PATH}" "${GEN2_HAMMER_PATH}" "${GEN2_MODPROBE_PATH}"; do
                [[ ! -e "${unmanaged_target}" && ! -L "${unmanaged_target}" ]] || \
                    die "Refusing to overwrite unreceipted or non-exact Gen2 target: ${unmanaged_target}"
            done
        fi
    fi
fi

if (( GEN2_STATE_PRESENT == 1 )); then
    GEN2_CAS_OLD_UNIT_HASH="${GEN2_OLD_UNIT_HASH}"
    GEN2_CAS_OLD_HAMMER_HASH="${GEN2_OLD_HAMMER_HASH}"
    GEN2_CAS_OLD_MODPROBE_HASH="${GEN2_OLD_MODPROBE_HASH}"
else
    GEN2_CAS_OLD_UNIT_HASH="absent"
    GEN2_CAS_OLD_HAMMER_HASH="absent"
    GEN2_CAS_OLD_MODPROBE_HASH="absent"
fi

if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    GEN2_DESIRED_UNIT_HASH="${GEN2_REPO_UNIT_HASH}"
    GEN2_DESIRED_HAMMER_HASH="${GEN2_REPO_HAMMER_HASH}"
else
    if (( GEN2_STATE_PRESENT == 1 )); then
        GEN2_DESIRED_UNIT_HASH="${GEN2_OLD_UNIT_HASH}"
        GEN2_DESIRED_HAMMER_HASH="${GEN2_OLD_HAMMER_HASH}"
    else
        GEN2_DESIRED_UNIT_HASH="absent"
        GEN2_DESIRED_HAMMER_HASH="absent"
    fi
fi
GEN2_DESIRED_MODPROBE_HASH="${GEN2_REPO_MODPROBE_HASH}"
GEN2_RECEIPT_CONTENT="$(printf 'format=1\nunit_path=%s\nunit_sha256=%s\nhammer_path=%s\nhammer_sha256=%s\nmodprobe_path=%s\nmodprobe_sha256=%s\n' \
    "${GEN2_UNIT_PATH}" "${GEN2_DESIRED_UNIT_HASH}" \
    "${GEN2_HAMMER_PATH}" "${GEN2_DESIRED_HAMMER_HASH}" \
    "${GEN2_MODPROBE_PATH}" "${GEN2_DESIRED_MODPROBE_HASH}")"$'\n'
if (( GEN2_PENDING_PRESENT == 1 )); then
    [[ "${GEN2_NEXT_UNIT_HASH}" == "${GEN2_DESIRED_UNIT_HASH}" &&
       "${GEN2_NEXT_HAMMER_HASH}" == "${GEN2_DESIRED_HAMMER_HASH}" &&
       "${GEN2_NEXT_MODPROBE_HASH}" == "${GEN2_DESIRED_MODPROBE_HASH}" ]] || \
        die "Pending Gen2 transaction targets a different install option or source revision"
fi
preflight_target_parent "${GEN2_MODPROBE_PATH}" || \
    die "Gen2 modprobe parent is unsafe or not writable: $(dirname "${GEN2_MODPROBE_PATH}")"
if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    validate_trusted_executable "${SYSTEMCTL_EXECUTABLE}" || \
        die "A trusted systemctl is required to arm the Gen2 service"
    command -v setpci &>/dev/null || die "setpci is required to arm the Gen2 service"
    preflight_target_parent "${GEN2_UNIT_PATH}" || \
        die "Gen2 unit parent is unsafe or not writable: $(dirname "${GEN2_UNIT_PATH}")"
    preflight_target_parent "${GEN2_HAMMER_PATH}" || \
        die "Gen2 helper parent is unsafe or not writable: $(dirname "${GEN2_HAMMER_PATH}")"
fi

# IOMMU ownership is preflighted before any module or DKMS mutation.  The
# implementation functions are defined below and invoked here deliberately.
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

load_iommu_receipt() {
    local file="$1"
    local prefix="$2"
    local -a lines=()
    local backend source base_hash expected_hash generator target key
    read_secure_state_lines "${file}" lines || return 1
    (( ${#lines[@]} == 8 )) || return 1
    [[ "${lines[0]}" == "format=1" && "${lines[1]}" == backend=* &&
       "${lines[2]}" == source=* && "${lines[3]}" == base_sha256=* &&
       "${lines[4]}" == expected_sha256=* && "${lines[5]}" == generator=* &&
       "${lines[6]}" == target=* && "${lines[7]}" == key=* ]] || return 1
    backend="${lines[1]#backend=}"
    source="${lines[2]#source=}"
    base_hash="${lines[3]#base_sha256=}"
    expected_hash="${lines[4]#expected_sha256=}"
    generator="${lines[5]#generator=}"
    target="${lines[6]#target=}"
    key="${lines[7]#key=}"
    [[ "${base_hash}" =~ ^[0-9a-f]{64}$ && "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    case "${backend}|${source}|${generator}|${target}|${key}" in
        "grub|/etc/default/grub|update-grub|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
        "grub|/etc/default/grub|update-grub|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX"|\
        "grub|/etc/default/grub|grub2-mkconfig|/boot/grub2/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
        "grub|/etc/default/grub|grub2-mkconfig|/boot/grub2/grub.cfg|GRUB_CMDLINE_LINUX"|\
        "grub|/etc/default/grub|grub-mkconfig|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
        "grub|/etc/default/grub|grub-mkconfig|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX"|\
        "kernel-cmdline|/etc/kernel/cmdline|kernel-install|/boot/loader/entries|-") ;;
        *) return 1 ;;
    esac
    printf -v "${prefix}_BACKEND" '%s' "${backend}"
    printf -v "${prefix}_SOURCE" '%s' "${source}"
    printf -v "${prefix}_BASE_HASH" '%s' "${base_hash}"
    printf -v "${prefix}_EXPECTED_HASH" '%s' "${expected_hash}"
    printf -v "${prefix}_GENERATOR" '%s' "${generator}"
    printf -v "${prefix}_TARGET" '%s' "${target}"
    printf -v "${prefix}_KEY" '%s' "${key}"
}

load_iommu_prepare() {
    local file="$1"
    local -a lines=()
    read_secure_state_lines "${file}" lines || return 1
    (( ${#lines[@]} == 5 )) || return 1
    [[ "${lines[0]}" == "format=prepare" && "${lines[1]}" == backend=* &&
       "${lines[2]}" == source=* && "${lines[3]}" == generator=* &&
       "${lines[4]}" == target=* ]] || return 1
    IOMMU_PREP_BACKEND="${lines[1]#backend=}"
    IOMMU_PREP_SOURCE="${lines[2]#source=}"
    IOMMU_PREP_GENERATOR="${lines[3]#generator=}"
    IOMMU_PREP_TARGET="${lines[4]#target=}"
    case "${IOMMU_PREP_BACKEND}|${IOMMU_PREP_SOURCE}|${IOMMU_PREP_GENERATOR}|${IOMMU_PREP_TARGET}" in
        "grub|/etc/default/grub|update-grub|/boot/grub/grub.cfg"|\
        "grub|/etc/default/grub|grub2-mkconfig|/boot/grub2/grub.cfg"|\
        "grub|/etc/default/grub|grub-mkconfig|/boot/grub/grub.cfg"|\
        "kernel-cmdline|/etc/kernel/cmdline|kernel-install|/boot/loader/entries") ;;
        *) return 1 ;;
    esac
}

prepare_iommu_candidate() {
    local source="$1"
    local backend="$2"
    local params="$3"
    local forced_key="$4"
    local candidate="$5"
    python3 - "${source}" "${backend}" "${params}" "${forced_key}" "${candidate}" <<'PY'
import os
import pathlib
import re
import stat
import sys
import tempfile

source = pathlib.Path(sys.argv[1])
backend = sys.argv[2]
params = sys.argv[3]
forced_key = sys.argv[4]
candidate = pathlib.Path(sys.argv[5])
sst = os.lstat(source)
if not stat.S_ISREG(sst.st_mode) or stat.S_ISLNK(sst.st_mode):
    raise SystemExit(f"unsafe command-line source: {source}")
text = source.read_text(encoding="utf-8")
if "\r" in text or "\x00" in text:
    raise SystemExit("unsupported control character in command-line source")

def merge(value):
    tokens = [t for t in value.split() if not (
        t.startswith("intel_iommu=") or t.startswith("amd_iommu=") or t.startswith("iommu=")
    )]
    tokens.extend(params.split())
    return " ".join(tokens)

key = "-"
if backend == "grub":
    lines = text.splitlines(keepends=True)
    values = {}
    indices = {}
    for wanted in ("GRUB_CMDLINE_LINUX_DEFAULT", "GRUB_CMDLINE_LINUX"):
        values[wanted] = []
        indices[wanted] = []
    for index, line in enumerate(lines):
        raw = line[:-1] if line.endswith("\n") else line
        for wanted in values:
            if re.match(rf"^{re.escape(wanted)}\s*=", raw):
                match = re.fullmatch(rf'{re.escape(wanted)}="([^"\n]*)"', raw)
                if match is None:
                    raise SystemExit(f"unsupported or ambiguous {wanted} syntax")
                values[wanted].append(match.group(1))
                indices[wanted].append(index)
    if any(len(values[wanted]) > 1 for wanted in values):
        raise SystemExit("duplicate GRUB command-line assignment")
    if forced_key != "-":
        key = forced_key
    elif values["GRUB_CMDLINE_LINUX_DEFAULT"]:
        key = "GRUB_CMDLINE_LINUX_DEFAULT"
    elif values["GRUB_CMDLINE_LINUX"]:
        key = "GRUB_CMDLINE_LINUX"
    else:
        key = "GRUB_CMDLINE_LINUX_DEFAULT"
    if key not in values:
        raise SystemExit("invalid persisted GRUB key")
    current = values[key][0] if values[key] else ""
    merged = merge(current)
    replacement = f'{key}="{merged}"'
    if indices[key]:
        index = indices[key][0]
        newline = "\n" if lines[index].endswith("\n") else ""
        lines[index] = replacement + newline
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(replacement + "\n")
    expected = "".join(lines)
elif backend == "kernel-cmdline":
    body = text[:-1] if text.endswith("\n") else text
    if "\n" in body:
        raise SystemExit("/etc/kernel/cmdline must contain exactly one line")
    current = body.strip()
    merged = merge(current)
    expected = merged + "\n"
else:
    raise SystemExit("invalid command-line backend")

parent = candidate.parent
pst = os.lstat(parent)
if not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode):
    raise SystemExit("unsafe candidate parent")
try:
    cst = os.lstat(candidate)
except FileNotFoundError:
    pass
else:
    if not stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode):
        raise SystemExit("unsafe candidate path")
fd, tmp = tempfile.mkstemp(prefix=f".cmpunlocker-install.{candidate.name}.tmp.", dir=parent)
try:
    os.fchmod(fd, 0o600)
    os.fchown(fd, 0, 0)
    with os.fdopen(fd, "wb", closefd=True) as stream:
        fd = -1
        stream.write(expected.encode("utf-8"))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, candidate)
    dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
except BaseException:
    if fd >= 0:
        os.close(fd)
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
changed = 1 if expected != text else 0
print(f"{key}\t{changed}\t{merged}")
PY
}

resolve_grub_tools() {
    local candidate
    GRUB_GENERATOR_EXECUTABLE=""
    case "${IOMMU_GENERATOR}" in
        update-grub|grub-mkconfig)
            for candidate in /usr/bin/grub-mkconfig /usr/sbin/grub-mkconfig; do
                if [[ -x "${candidate}" ]]; then
                    GRUB_GENERATOR_EXECUTABLE="$(/usr/bin/readlink -f -- "${candidate}" 2>/dev/null || true)"
                    break
                fi
            done
            ;;
        grub2-mkconfig)
            for candidate in /usr/bin/grub2-mkconfig /usr/sbin/grub2-mkconfig; do
                if [[ -x "${candidate}" ]]; then
                    GRUB_GENERATOR_EXECUTABLE="$(/usr/bin/readlink -f -- "${candidate}" 2>/dev/null || true)"
                    break
                fi
            done
            ;;
        *) return 1 ;;
    esac
    GRUB_SCRIPT_CHECK_EXECUTABLE=""
    for candidate in /usr/bin/grub-script-check /usr/sbin/grub-script-check; do
        if [[ -x "${candidate}" ]]; then
            GRUB_SCRIPT_CHECK_EXECUTABLE="$(/usr/bin/readlink -f -- "${candidate}" 2>/dev/null || true)"
            break
        fi
    done
    [[ -n "${GRUB_GENERATOR_EXECUTABLE}" && -n "${GRUB_SCRIPT_CHECK_EXECUTABLE}" ]] || return 1
    validate_trusted_executable "${GRUB_GENERATOR_EXECUTABLE}" || return 1
    validate_trusted_executable "${GRUB_SCRIPT_CHECK_EXECUTABLE}" || return 1
}

select_iommu_generator() {
    local backend="$1"
    if [[ "${backend}" == "grub" ]]; then
        # These fields make a prepare-only journal self-describing.  They are
        # never executed or used to select a live boot target: automatic boot
        # mutation is deliberately disabled below.
        IOMMU_GENERATOR="grub-mkconfig"
        IOMMU_TARGET="/boot/grub/grub.cfg"
    else
        # kernel-install is a multi-plugin, multi-output transaction and has no
        # bounded atomic target comparable to grub.cfg.  Leave that backend to
        # explicit administrator tooling instead of editing its source here.
        return 1
    fi
}

preflight_grub_atomic_target() {
    python3 - "${IOMMU_TARGET}" "${IOMMU_SOURCE}" "${IOMMU_PENDING}" <<'PY'
import os
import pathlib
import stat
import sys

target = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
pending = pathlib.Path(sys.argv[3])

def secure_regular(path, private=False):
    st = os.lstat(path)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
            or stat.S_IMODE(st.st_mode) & 0o022
            or (private and stat.S_IMODE(st.st_mode) != 0o600)):
        raise SystemExit(f"unsafe GRUB transaction object: {path}")
    return st

source_st = secure_regular(source)
parent = target.parent
parent_st = os.lstat(parent)
if (not stat.S_ISDIR(parent_st.st_mode) or stat.S_ISLNK(parent_st.st_mode)
        or parent_st.st_uid != 0 or parent_st.st_gid != 0
        or stat.S_IMODE(parent_st.st_mode) & 0o022
        or parent.resolve(strict=True) != parent):
    raise SystemExit(f"unsafe GRUB target parent: {parent}")
target_st = secure_regular(target)
if target_st.st_dev != parent_st.st_dev or target_st.st_size <= 0:
    raise SystemExit(f"unsafe live GRUB target: {target}")
stage_names = (f".{target.name}.cmpunlocker-stage", f".{target.name}.cmpunlocker-stage.new")
stages = [parent / name for name in stage_names if os.path.lexists(parent / name)]
if stages:
    secure_regular(pending, private=True)
for stage in stages:
    stage_st = secure_regular(stage)
    if stage_st.st_dev != parent_st.st_dev:
        raise SystemExit(f"cross-device stale GRUB stage: {stage}")
PY
}

run_iommu_generator() {
    resolve_grub_tools || return 1
    python3 - "${GRUB_GENERATOR_EXECUTABLE}" "${GRUB_SCRIPT_CHECK_EXECUTABLE}" \
        "${IOMMU_TARGET}" "${IOMMU_SOURCE}" "${IOMMU_PENDING}" "${IOMMU_PARAMS}" <<'PY'
import hashlib
import os
import pathlib
import stat
import subprocess
import sys

generator = pathlib.Path(sys.argv[1])
checker = pathlib.Path(sys.argv[2])
target = pathlib.Path(sys.argv[3])
source = pathlib.Path(sys.argv[4])
pending = pathlib.Path(sys.argv[5])
params = tuple(sys.argv[6].split())
dir_flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
             | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)

def secure_regular(path, private=False, executable=False):
    st = os.lstat(path)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
            or stat.S_IMODE(st.st_mode) & 0o022
            or (private and stat.S_IMODE(st.st_mode) != 0o600)
            or (executable and not os.access(path, os.X_OK))):
        raise SystemExit(f"unsafe boot transaction object: {path}")
    return st

def hash_fd(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        digest.update(block)
    return digest.hexdigest()

for executable in (generator, checker):
    if not executable.is_absolute() or executable.resolve(strict=True) != executable:
        raise SystemExit(f"untrusted boot executable: {executable}")
    secure_regular(executable, executable=True)
secure_regular(pending, private=True)
source_st = secure_regular(source)
source_fd = os.open(source, file_flags)
source_opened = os.fstat(source_fd)
if (source_opened.st_dev, source_opened.st_ino) != (source_st.st_dev, source_st.st_ino):
    raise SystemExit("IOMMU source changed while opening it for generation")
source_hash = hash_fd(source_fd)

parent = target.parent
parent_fd = os.open(parent, dir_flags)
parent_st = os.fstat(parent_fd)
if (not stat.S_ISDIR(parent_st.st_mode) or parent_st.st_uid != 0
        or parent_st.st_gid != 0 or stat.S_IMODE(parent_st.st_mode) & 0o022
        or parent.resolve(strict=True) != parent):
    raise SystemExit(f"unsafe GRUB target parent: {parent}")
target_st = secure_regular(target)
if target_st.st_dev != parent_st.st_dev or target_st.st_size <= 0:
    raise SystemExit(f"unsafe live GRUB target: {target}")
target_fd = os.open(target.name, file_flags, dir_fd=parent_fd)
target_opened = os.fstat(target_fd)
if (target_opened.st_dev, target_opened.st_ino) != (target_st.st_dev, target_st.st_ino):
    raise SystemExit("live GRUB target changed while opening it")
target_hash = hash_fd(target_fd)
target_attrs = (
    target_opened.st_dev, target_opened.st_ino, target_opened.st_mode,
    target_opened.st_uid, target_opened.st_gid, target_opened.st_nlink,
    target_opened.st_size, target_opened.st_mtime_ns, target_opened.st_ctime_ns,
)
target_xattrs = {
    name: os.getxattr(target, name, follow_symlinks=False)
    for name in os.listxattr(target, follow_symlinks=False)
}

stage_name = f".{target.name}.cmpunlocker-stage"
new_name = stage_name + ".new"
for stale_name in (stage_name, new_name):
    try:
        stale = os.stat(stale_name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        continue
    if (not stat.S_ISREG(stale.st_mode) or stat.S_ISLNK(stale.st_mode)
            or stale.st_uid != 0 or stale.st_gid != 0 or stale.st_nlink != 1
            or stale.st_dev != parent_st.st_dev or stat.S_IMODE(stale.st_mode) & 0o022):
        raise SystemExit(f"unsafe stale GRUB stage: {parent / stale_name}")
    os.unlink(stale_name, dir_fd=parent_fd)
    os.fsync(parent_fd)

stage_fd = os.open(
    stage_name,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0),
    stat.S_IMODE(target_opened.st_mode),
    dir_fd=parent_fd,
)
os.fchown(stage_fd, target_opened.st_uid, target_opened.st_gid)
os.fchmod(stage_fd, stat.S_IMODE(target_opened.st_mode))
os.close(stage_fd)
stage = parent / stage_name

environment = {
    "PATH": "/usr/bin:/usr/sbin:/bin:/sbin",
    "HOME": "/root",
    "LC_ALL": "C",
    "LANG": "C",
}
try:
    subprocess.run([str(generator), "-o", str(stage)], check=True, env=environment)
except BaseException:
    # The stage is deliberately retained and is safe to replace on a retry
    # only while the durable IOMMU pending receipt remains.
    raise
if os.path.lexists(parent / new_name):
    raise SystemExit(f"GRUB generator left an uncommitted sidecar: {parent / new_name}")

stage_st = secure_regular(stage)
if stage_st.st_dev != parent_st.st_dev or not (0 < stage_st.st_size <= 128 * 1024 * 1024):
    raise SystemExit("generated GRUB candidate has an unsafe size or filesystem")
stage_fd = os.open(stage_name, file_flags, dir_fd=parent_fd)
stage_initial = os.fstat(stage_fd)
if (stage_initial.st_dev, stage_initial.st_ino) != (stage_st.st_dev, stage_st.st_ino):
    raise SystemExit("GRUB candidate changed while opening it")
os.fchown(stage_fd, target_opened.st_uid, target_opened.st_gid)
os.fchmod(stage_fd, stat.S_IMODE(target_opened.st_mode))
for name in os.listxattr(stage_fd):
    if name not in target_xattrs:
        os.removexattr(stage_fd, name)
for name, value in target_xattrs.items():
    os.setxattr(stage_fd, name, value)
stage_opened = os.fstat(stage_fd)
candidate_hash = hash_fd(stage_fd)
stage_after = os.fstat(stage_fd)
if (stage_after.st_dev, stage_after.st_ino, stage_after.st_size,
        stage_after.st_mtime_ns, stage_after.st_ctime_ns) != (
        stage_opened.st_dev, stage_opened.st_ino, stage_opened.st_size,
        stage_opened.st_mtime_ns, stage_opened.st_ctime_ns):
    raise SystemExit("GRUB candidate changed while hashing it")
subprocess.run([str(checker), str(stage)], check=True, env=environment)
candidate = stage.read_bytes()
if any(token.encode("ascii") not in candidate for token in params):
    raise SystemExit("generated GRUB candidate lacks the intended IOMMU parameters")

source_now = os.stat(source, follow_symlinks=False)
if (source_now.st_dev, source_now.st_ino) != (source_opened.st_dev, source_opened.st_ino):
    raise SystemExit("IOMMU source path changed during GRUB generation")
if hash_fd(source_fd) != source_hash:
    raise SystemExit("IOMMU source bytes changed during GRUB generation")
target_now = os.stat(target.name, dir_fd=parent_fd, follow_symlinks=False)
target_current = (
    target_now.st_dev, target_now.st_ino, target_now.st_mode,
    target_now.st_uid, target_now.st_gid, target_now.st_nlink,
    target_now.st_size, target_now.st_mtime_ns, target_now.st_ctime_ns,
)
if target_current != target_attrs or hash_fd(target_fd) != target_hash:
    raise SystemExit("live GRUB target changed before atomic publication")
parent_now = os.stat(parent)
if (parent_now.st_dev, parent_now.st_ino) != (parent_st.st_dev, parent_st.st_ino):
    raise SystemExit("GRUB target parent changed before atomic publication")

os.fsync(stage_fd)
os.replace(stage_name, target.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
published_fd = os.open(target.name, file_flags, dir_fd=parent_fd)
published = os.fstat(published_fd)
if (not stat.S_ISREG(published.st_mode) or published.st_nlink != 1
        or published.st_uid != target_opened.st_uid
        or published.st_gid != target_opened.st_gid
        or stat.S_IMODE(published.st_mode) != stat.S_IMODE(target_opened.st_mode)
        or hash_fd(published_fd) != candidate_hash):
    raise SystemExit("atomically published GRUB target failed verification")
os.fsync(published_fd)
os.fsync(parent_fd)
PY
}

load_iommu_adopt() {
    local file="$1"
    local -a lines=()
    read_secure_state_lines "${file}" lines || return 1
    (( ${#lines[@]} == 6 )) || return 1
    [[ "${lines[0]}" == "format=adopt" &&
       "${lines[1]}" == "backend=grub" &&
       "${lines[2]}" == "source=/etc/default/grub" &&
       "${lines[3]}" == "legacy=/etc/default/grub.cmpunlocker.bak" &&
       "${lines[4]}" == generator=* && "${lines[5]}" == target=* ]] || return 1
    IOMMU_ADOPT_GENERATOR="${lines[4]#generator=}"
    IOMMU_ADOPT_TARGET="${lines[5]#target=}"
    case "${IOMMU_ADOPT_GENERATOR}|${IOMMU_ADOPT_TARGET}" in
        "update-grub|/boot/grub/grub.cfg"|\
        "grub2-mkconfig|/boot/grub2/grub.cfg"|\
        "grub-mkconfig|/boot/grub/grub.cfg") ;;
        *) return 1 ;;
    esac
}

complete_legacy_iommu_adoption() {
    local legacy_plan legacy_key legacy_changed legacy_merged
    local legacy_base_hash legacy_expected_hash state_content
    [[ -n "${IOMMU_PARAMS}" ]] || return 1
    [[ -f /etc/default/grub && ! -L /etc/default/grub &&
       -f /etc/default/grub.cmpunlocker.bak && ! -L /etc/default/grub.cmpunlocker.bak ]] || return 1
    load_iommu_adopt "${IOMMU_PENDING}" || return 1
    IOMMU_GENERATOR="${IOMMU_ADOPT_GENERATOR}"
    IOMMU_TARGET="${IOMMU_ADOPT_TARGET}"
    resolve_grub_tools || return 1
    if ! legacy_plan="$(prepare_iommu_candidate /etc/default/grub.cmpunlocker.bak grub \
        "${IOMMU_PARAMS}" - "${IOMMU_CANDIDATE}")"; then
        return 1
    fi
    IFS=$'\t' read -r legacy_key legacy_changed legacy_merged <<< "${legacy_plan}"
    if [[ "${legacy_changed}" != "1" ||
          "$(file_hash "${IOMMU_CANDIDATE}")" != "$(file_hash /etc/default/grub)" ]]; then
        durable_remove "${IOMMU_CANDIDATE}" || true
        return 1
    fi
    if [[ -e "${IOMMU_BASE}" || -L "${IOMMU_BASE}" ]]; then
        [[ -f "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
           "$(file_hash "${IOMMU_BASE}")" == "$(file_hash /etc/default/grub.cmpunlocker.bak)" ]] || return 1
    else
        atomic_copy_mode /etc/default/grub.cmpunlocker.bak "${IOMMU_BASE}" 0600 || return 1
    fi
    if [[ -e "${IOMMU_EXPECTED}" || -L "${IOMMU_EXPECTED}" ]]; then
        [[ -f "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" &&
           "$(file_hash "${IOMMU_EXPECTED}")" == "$(file_hash /etc/default/grub)" ]] || return 1
    else
        atomic_copy_mode /etc/default/grub "${IOMMU_EXPECTED}" 0600 || return 1
    fi
    durable_remove "${IOMMU_CANDIDATE}" || return 1
    legacy_base_hash="$(file_hash "${IOMMU_BASE}")"
    legacy_expected_hash="$(file_hash "${IOMMU_EXPECTED}")"
    state_content="$(printf 'format=1\nbackend=grub\nsource=/etc/default/grub\nbase_sha256=%s\nexpected_sha256=%s\ngenerator=%s\ntarget=%s\nkey=%s\n' \
        "${legacy_base_hash}" "${legacy_expected_hash}" "${IOMMU_GENERATOR}" "${IOMMU_TARGET}" "${legacy_key}")"$'\n'
    atomic_write_text "${IOMMU_PENDING}" 0600 "${state_content}" || return 1
    atomic_write_text "${IOMMU_STATE}" 0600 "${state_content}" || return 1
}

IOMMU_STATE_PRESENT=0
IOMMU_RECOVERY=0
IOMMU_CANDIDATE="${STATE_DIR}/iommu.candidate"
# CPU-derived parameters are also needed to prove a narrow legacy B -> E
# adoption when --no-iommu is requested.  That proof is read-only with respect
# to the live command-line source and does not authorize running its generator.
IOMMU_PARAMS="$(iommu_params_for_cpu)"
if [[ -e "${IOMMU_CANDIDATE}" || -L "${IOMMU_CANDIDATE}" ]]; then
    [[ -f "${IOMMU_CANDIDATE}" && ! -L "${IOMMU_CANDIDATE}" ]] || \
        die "Unsafe stale IOMMU candidate: ${IOMMU_CANDIDATE}"
    durable_remove "${IOMMU_CANDIDATE}" || die "Could not clear stale non-authoritative IOMMU candidate"
fi
if [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]]; then
    load_iommu_receipt "${IOMMU_STATE}" IOMMU_OLD || die "Invalid IOMMU ownership state: ${IOMMU_STATE}"
    IOMMU_STATE_PRESENT=1
fi

LEGACY_GRUB_BACKUP="/etc/default/grub.cmpunlocker.bak"
IOMMU_LEGACY_ADOPTION_ACTIVE=0
legacy_iommu_count=0
for legacy_iommu in "${LEGACY_GRUB_BACKUP}" \
                    /etc/default/grub.cmpunlocker.pending \
                    /etc/kernel/cmdline.cmpunlocker.bak \
                    /etc/kernel/cmdline.cmpunlocker.pending; do
    if [[ -e "${legacy_iommu}" || -L "${legacy_iommu}" ]]; then
        legacy_iommu_count=$((legacy_iommu_count + 1))
        legacy_iommu_found="${legacy_iommu}"
    fi
done
LEGACY_IOMMU_PRESERVED=0
if (( legacy_iommu_count > 0 )); then
    if (( legacy_iommu_count == 1 && IOMMU_STATE_PRESENT == 0 )) &&
       [[ "${legacy_iommu_found}" == "${LEGACY_GRUB_BACKUP}" && -n "${IOMMU_PARAMS}" &&
          ! -e "${IOMMU_PENDING}" && ! -L "${IOMMU_PENDING}" &&
          ! -e "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
          ! -e "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" ]]; then
        legacy_preserve_plan="$(prepare_iommu_candidate "${LEGACY_GRUB_BACKUP}" grub \
            "${IOMMU_PARAMS}" - "${IOMMU_CANDIDATE}")" || \
            die "Could not prove the legacy IOMMU backup without mutating boot state"
        IFS=$'\t' read -r legacy_preserve_key legacy_preserve_changed legacy_preserve_merged <<< "${legacy_preserve_plan}"
        [[ "${legacy_preserve_changed}" == "1" &&
           "$(file_hash "${IOMMU_CANDIDATE}")" == "$(file_hash /etc/default/grub)" ]] || \
            die "Legacy IOMMU backup is not an exact read-only derivation of the current GRUB source"
        durable_remove "${IOMMU_CANDIDATE}" || die "Could not retire the legacy read-only proof candidate"
        legacy_iommu_count=0
        LEGACY_IOMMU_PRESERVED=1
        warn "Preserving the exact legacy IOMMU backup without guessing or rewriting its historical boot target"
    else
        die "Legacy cmpunlocker IOMMU sidecars do not prove their historical boot target; reconcile them manually before installing"
    fi
fi
if (( legacy_iommu_count > 0 )); then
    if (( legacy_iommu_count == 1 )) && [[ "${legacy_iommu_found}" == "${LEGACY_GRUB_BACKUP}" ]] &&
       [[ -n "${IOMMU_PARAMS}" ]]; then
        if [[ -e "${IOMMU_PENDING}" || -L "${IOMMU_PENDING}" ]]; then
            if load_iommu_adopt "${IOMMU_PENDING}"; then
                (( IOMMU_STATE_PRESENT == 0 )) || die "Legacy adoption journal conflicts with committed IOMMU state"
                complete_legacy_iommu_adoption || \
                    die "Interrupted legacy IOMMU adoption cannot be deterministically completed"
            elif load_iommu_receipt "${IOMMU_PENDING}" IOMMU_ADOPT_NEXT; then
                [[ -f "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
                   -f "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" &&
                   "$(file_hash "${IOMMU_BASE}")" == "${IOMMU_ADOPT_NEXT_BASE_HASH}" &&
                   "$(file_hash "${IOMMU_EXPECTED}")" == "${IOMMU_ADOPT_NEXT_EXPECTED_HASH}" &&
                   "$(file_hash "${LEGACY_GRUB_BACKUP}")" == "${IOMMU_ADOPT_NEXT_BASE_HASH}" &&
                   "$(file_hash /etc/default/grub)" == "${IOMMU_ADOPT_NEXT_EXPECTED_HASH}" ]] || \
                    die "Full legacy adoption journal conflicts with B/E/current files"
                if (( IOMMU_STATE_PRESENT == 1 )); then
                    [[ "$(<"${IOMMU_STATE}")"$'\n' == "$(<"${IOMMU_PENDING}")"$'\n' ]] || \
                        die "Committed legacy adoption state conflicts with its journal"
                else
                    atomic_copy_mode "${IOMMU_PENDING}" "${IOMMU_STATE}" 0600 || \
                        die "Could not converge full legacy adoption journal to committed state"
                    IOMMU_STATE_PRESENT=1
                fi
            else
                die "Legacy IOMMU backup conflicts with its pending transaction"
            fi
        else
            if (( IOMMU_STATE_PRESENT == 1 )); then
                # The only valid no-journal legacy shape is cleanup after the
                # full state/pending transaction already committed.  Re-prove
                # B -> E before retiring the redundant old backup.
                [[ "${IOMMU_OLD_BACKEND}" == "grub" &&
                   "${IOMMU_OLD_SOURCE}" == "/etc/default/grub" &&
                   -f "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
                   -f "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" &&
                   "$(file_hash "${IOMMU_BASE}")" == "${IOMMU_OLD_BASE_HASH}" &&
                   "$(file_hash "${IOMMU_EXPECTED}")" == "${IOMMU_OLD_EXPECTED_HASH}" &&
                   "$(file_hash "${LEGACY_GRUB_BACKUP}")" == "${IOMMU_OLD_BASE_HASH}" &&
                   "$(file_hash /etc/default/grub)" == "${IOMMU_OLD_EXPECTED_HASH}" ]] || \
                    die "Legacy backup conflicts with committed IOMMU B/E state"
                if ! legacy_cleanup_plan="$(prepare_iommu_candidate "${LEGACY_GRUB_BACKUP}" grub \
                    "${IOMMU_PARAMS}" "${IOMMU_OLD_KEY}" "${IOMMU_CANDIDATE}")"; then
                    die "Could not re-prove committed legacy IOMMU derivation"
                fi
                IFS=$'\t' read -r legacy_cleanup_key legacy_cleanup_changed legacy_cleanup_merged <<< "${legacy_cleanup_plan}"
                [[ "${legacy_cleanup_key}" == "${IOMMU_OLD_KEY}" && "${legacy_cleanup_changed}" == "1" &&
                   "$(file_hash "${IOMMU_CANDIDATE}")" == "${IOMMU_OLD_EXPECTED_HASH}" ]] || \
                    die "Committed legacy IOMMU state is not exact derive(B, CPU params) == E"
                durable_remove "${IOMMU_CANDIDATE}" || die "Could not retire legacy proof candidate"
                durable_remove "${LEGACY_GRUB_BACKUP}" || die "Could not finish committed legacy cleanup"
            else
                [[ ! -e "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
                   ! -e "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" ]] || \
                    die "Unjournaled partial legacy IOMMU adoption is ambiguous"
                die "A bare legacy GRUB backup does not prove its historical generator/EFI target; restore or reconcile it manually before installing"
            fi
        fi
        if [[ -e "${IOMMU_PENDING}" && ! -L "${IOMMU_PENDING}" ]]; then
            IOMMU_LEGACY_ADOPTION_ACTIVE=1
        fi
        load_iommu_receipt "${IOMMU_STATE}" IOMMU_OLD || die "Internal IOMMU adoption receipt error"
        IOMMU_STATE_PRESENT=1
        [[ "$(file_hash "${IOMMU_OLD_SOURCE}")" == "${IOMMU_OLD_EXPECTED_HASH}" ]] || \
            die "Legacy adoption source changed after exact B -> E proof"
        if (( CONFIGURE_IOMMU == 0 )); then
            # The full receipt plus B/E snapshots are sufficient for remove.sh
            # to restore B.  Finish ownership adoption without touching the
            # source or regenerating boot output, exactly as --no-iommu asks.
            if (( IOMMU_LEGACY_ADOPTION_ACTIVE == 1 )); then
                durable_remove "${IOMMU_PENDING}" || \
                    die "Could not finish no-IOMMU legacy ownership adoption"
                durable_remove "${LEGACY_GRUB_BACKUP}" || \
                    die "Could not retire the adopted legacy backup"
                IOMMU_LEGACY_ADOPTION_ACTIVE=0
            fi
            ok "Adopted exact legacy IOMMU B/E ownership without changing the command line or running a generator"
        else
            ok "Adopted exact derive(legacy B, ${IOMMU_PARAMS}) == current E into durable IOMMU state"
        fi
    else
        die "Ambiguous legacy IOMMU state exists; only exact single-backup derivation can be adopted"
    fi
fi
if [[ -e "${IOMMU_PENDING}" || -L "${IOMMU_PENDING}" ]]; then
    if load_iommu_prepare "${IOMMU_PENDING}"; then
        (( IOMMU_STATE_PRESENT == 0 )) || die "Prepare-only IOMMU journal conflicts with committed state"
        if [[ -e "${IOMMU_BASE}" || -L "${IOMMU_BASE}" ]]; then
            [[ -f "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" ]] || die "Unsafe prepare-phase IOMMU base"
            prepare_current_hash="$(file_hash "${IOMMU_PREP_SOURCE}")"
            [[ "${prepare_current_hash}" == "$(file_hash "${IOMMU_BASE}")" ]] || \
                die "IOMMU source changed during an interrupted prepare phase"
            durable_remove "${IOMMU_BASE}"
        fi
        [[ ! -e "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" ]] || durable_remove "${IOMMU_EXPECTED}"
        durable_remove "${IOMMU_PENDING}"
        info "Cleared an interrupted pre-write IOMMU preparation; source was unchanged"
    else
        load_iommu_receipt "${IOMMU_PENDING}" IOMMU_NEXT || die "Invalid IOMMU pending state"
        if (( IOMMU_STATE_PRESENT == 1 )); then
            [[ "$(<"${IOMMU_STATE}")"$'\n' == "$(<"${IOMMU_PENDING}")"$'\n' ]] || \
                die "IOMMU pending state conflicts with committed state"
        fi
        [[ -f "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
           -f "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" ]] || \
            die "IOMMU pending state is missing its durable B/E snapshots"
        [[ "$(file_hash "${IOMMU_BASE}")" == "${IOMMU_NEXT_BASE_HASH}" &&
           "$(file_hash "${IOMMU_EXPECTED}")" == "${IOMMU_NEXT_EXPECTED_HASH}" ]] || \
            die "IOMMU pending B/E snapshot hash mismatch"
        iommu_current_hash="$(file_hash "${IOMMU_NEXT_SOURCE}")"
        [[ "${iommu_current_hash}" == "${IOMMU_NEXT_BASE_HASH}" ||
           "${iommu_current_hash}" == "${IOMMU_NEXT_EXPECTED_HASH}" ]] || \
            die "IOMMU source conflicts with both pending B and E snapshots"
        IOMMU_RECOVERY=1
    fi
fi
if (( IOMMU_RECOVERY == 0 )); then
    if (( IOMMU_STATE_PRESENT == 1 )); then
        [[ -f "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
           -f "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" ]] || \
            die "Committed IOMMU state is missing B/E snapshots"
        [[ "$(file_hash "${IOMMU_BASE}")" == "${IOMMU_OLD_BASE_HASH}" &&
           "$(file_hash "${IOMMU_EXPECTED}")" == "${IOMMU_OLD_EXPECTED_HASH}" ]] || \
            die "Committed IOMMU B/E snapshot hash mismatch"
        [[ "$(file_hash "${IOMMU_OLD_SOURCE}")" == "${IOMMU_OLD_EXPECTED_HASH}" ]] || \
            die "IOMMU source was edited after cmpunlocker installed it; refusing overwrite"
    else
        [[ ! -e "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" &&
           ! -e "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" ]] || \
            die "Unreceipted IOMMU B/E snapshots are ambiguous"
    fi
fi

if (( CONFIGURE_IOMMU == 1 )); then
    if [[ -n "${IOMMU_PARAMS}" ]]; then
        if (( IOMMU_RECOVERY == 1 )); then
            IOMMU_BACKEND="${IOMMU_NEXT_BACKEND}"
            IOMMU_SOURCE="${IOMMU_NEXT_SOURCE}"
            IOMMU_GENERATOR="${IOMMU_NEXT_GENERATOR}"
            IOMMU_TARGET="${IOMMU_NEXT_TARGET}"
            IOMMU_KEY="${IOMMU_NEXT_KEY}"
        elif (( IOMMU_STATE_PRESENT == 1 )); then
            IOMMU_BACKEND="${IOMMU_OLD_BACKEND}"
            IOMMU_SOURCE="${IOMMU_OLD_SOURCE}"
            IOMMU_GENERATOR="${IOMMU_OLD_GENERATOR}"
            IOMMU_TARGET="${IOMMU_OLD_TARGET}"
            IOMMU_KEY="${IOMMU_OLD_KEY}"
        elif [[ -f /etc/default/grub && ! -L /etc/default/grub ]]; then
            IOMMU_BACKEND="grub"
            IOMMU_SOURCE="/etc/default/grub"
            IOMMU_KEY="-"
            select_iommu_generator "${IOMMU_BACKEND}" || die "No supported GRUB generator is available"
        elif [[ -f /etc/kernel/cmdline && ! -L /etc/kernel/cmdline ]]; then
            warn "Automatic /etc/kernel/cmdline editing is disabled because kernel-install has unbounded plugin outputs"
            warn "Add these to the kernel command line with your boot manager: ${IOMMU_PARAMS}"
            IOMMU_STATUS="manual"
        else
            warn "No safe /etc/default/grub or /etc/kernel/cmdline source found"
            warn "Add these to your kernel command line manually: ${IOMMU_PARAMS}"
            IOMMU_STATUS="manual"
        fi
        if [[ "${IOMMU_STATUS}" != "manual" ]]; then
            [[ -f "${IOMMU_SOURCE}" && ! -L "${IOMMU_SOURCE}" ]] || \
                die "Persisted IOMMU source is unsafe: ${IOMMU_SOURCE}"
        fi
    fi
fi
if (( IOMMU_RECOVERY == 1 )); then
    die "A legacy automatic IOMMU transaction is pending; reconcile its B/E source and boot output manually before installing"
fi

# Format=1 deliberately excludes DKMS original-module backups because it does
# not carry the path/hash identity needed to distinguish installed bytes from
# a restored vendor module.  Prove this invariant before any receipt, build,
# or boot-helper write, including when status output has collapsed to `added`.
verify_no_exact_dkms_originals || \
    die "DKMS original-module backups for this kernel/arch are unsupported; no install mutation was attempted"
classify_exact_dkms_tuple || die "Cannot safely classify the exact DKMS tuple before installation"
[[ "${DKMS_TUPLE_STATE}" != "originals" ]] || \
    die "DKMS original modules exist; normalize that tuple before installing cmpunlocker"

# Publish the exact intended ownership hashes before any DKMS or module
# mutation.  Every post-build failure therefore leaves an unambiguous retry
# record rather than unreceipted generic boot files.
atomic_write_text "${GEN2_PENDING}" 0600 "${GEN2_RECEIPT_CONTENT}" || \
    die "Could not durably publish the Gen2 ownership transaction before module work"

# No boot-helper ownership ambiguity remains.  Only now may the installer alter
# a currently winning DKMS tuple or commit new kernel modules.
DKMS_CLEANUP_REQUIRED="${DKMS_RECEIPT_PREEXISTED}"

publish_dkms_cleanup_intent() {
    verify_no_exact_dkms_originals || return 1
    if (( DKMS_RECEIPT_PREEXISTED == 1 )); then
        load_dkms_receipt "${DKMS_RECEIPT}" || return 1
        DKMS_CLEANUP_REQUIRED=1
        return 0
    fi
    classify_exact_dkms_tuple || return 1
    [[ "${DKMS_TUPLE_STATE}" == "installed" && "${DKMS_SOURCE_REGISTERED}" == "1" ]] || return 1
    # Before format=1 exists, prove that every installed leaf is bound to the
    # exact complete B/module tuple.  This prevents publishing an intent that
    # could authorize an impossible or ambiguous forward cleanup.
    validate_remaining_dkms_target_bindings complete || return 1
    [[ ! -e "${DKMS_RECEIPT}" && ! -L "${DKMS_RECEIPT}" ]] || return 1
    atomic_write_text "${DKMS_RECEIPT}" 0600 "${DKMS_RECEIPT_CONTENT}" || return 1
    load_dkms_receipt "${DKMS_RECEIPT}" || return 1
    DKMS_RECEIPT_PREEXISTED=1
    DKMS_CLEANUP_REQUIRED=1
}

converge_dkms_cleanup_forward() {
    local i resolved_path
    load_dkms_receipt "${DKMS_RECEIPT}" || \
        die "DKMS cleanup intent changed or disappeared: ${DKMS_RECEIPT}"
    verify_no_exact_dkms_originals || \
        die "Unsupported exact DKMS original-module state exists; receipt retained and no cleanup was attempted"
    classify_exact_dkms_tuple || \
        die "Cannot classify exact DKMS tuple state; receipt retained and no rollback was attempted"
    (( DKMS_SOURCE_REGISTERED == 1 )) || \
        die "DKMS source registration disappeared; receipt retained and no cleanup was attempted"
    case "${DKMS_TUPLE_STATE}" in
        installed|present)
            # B is still present and is the byte-identity authority for each
            # remaining installed leaf.  Keep L/B until target absence is
            # durably sealed so every hard cut retries in the same direction.
            info "Removing exact DKMS target leaves bound to tuple build evidence"
            cleanup_exact_dkms_target_artifacts || \
                die "Unsafe, replaced, or unbound exact DKMS target artifact; receipt and B/L were preserved"
            ;;
        absent)
            # Once B/L are gone, format=1 carries no content hashes.  It can
            # prove absence but must never authorize deletion of a newly
            # appeared same-name module.
            ;;
        originals)
            die "DKMS original-module backups are unsupported by format=1 cleanup; receipt retained"
            ;;
        *) die "Internal error: unclassified DKMS cleanup state" ;;
    esac

    # Do not execute DKMS here.  Its configuration sourcing, hooks, weak-module
    # helpers, broad .ko* globs, and recursive B/K removal exceed the authority
    # carried by a format=1 receipt.  Delete only the exact fixed target leaves,
    # seal their absence, then retire exact L/B leaf-by-leaf.  The global source
    # registration is intentionally retained for remove.sh.
    info "Converging exact DKMS tuple nvidia/${detected}, ${KVER}, ${DKMS_ARCH} with filesystem evidence"
    seal_no_dkms_module_artifacts || \
        die "Ambiguous NVIDIA artifacts remain in updates/dkms; tuple evidence and receipt were preserved"
    cleanup_exact_dkms_tuple_tree || \
        die "Unsafe or incomplete exact DKMS tuple-tree residue; cleanup intent retained"
    seal_no_dkms_module_artifacts || \
        die "NVIDIA artifacts reappeared in updates/dkms after tuple cleanup; receipt retained"
    classify_exact_dkms_tuple || \
        die "Cannot revalidate the exact DKMS tuple after physical cleanup"
    [[ "${DKMS_TUPLE_STATE}" == "absent" && "${DKMS_SOURCE_REGISTERED}" == "1" ]] || \
        die "Exact DKMS tuple reappeared during forward cleanup"

    depmod -a "${KVER}" || die "depmod failed after exact DKMS cleanup; receipt retained"
    rebuild_current_initramfs "${KVER}" || \
        die "initramfs rebuild failed after exact DKMS cleanup; receipt retained"
    verify_cmp_physical_set safe || \
        die "Patched module set changed during exact DKMS cleanup"
    resolve_module_set || die "Cannot resolve NVIDIA modules after exact DKMS cleanup"
    (( CMP_RESOLUTION_EXACT == 1 )) || \
        die "Patched five-module set stopped winning after exact DKMS cleanup"
    for i in "${!MODULE_NAMES[@]}"; do
        resolved_path="${RESOLVED_MODULE_PATHS[$i]}"
        validate_module_file "${resolved_path}" "${MODULE_NAMES[$i]}" || \
            die "Final cmpunlocker resolver identity failed: ${resolved_path}"
    done
    ok "Converged exact current-kernel DKMS cleanup forward; restore receipt retained for remove.sh"
}

run_patched_module_build() {
    CMPUNLOCKER_DRIVER_VERSION="${detected}" \
    CMPUNLOCKER_CARD_PROFILE="${CARD_PROFILE}" \
    CMPUNLOCKER_GPU_INVENTORY="${CMPUNLOCKER_GPU_INVENTORY}" \
    CMPUNLOCKER_LIFECYCLE_LOCK_FD="${LIFECYCLE_LOCK_FD}" \
        bash "${SCRIPT_DIR}/driver/build.sh"
}

# A live marker is never accepted as a committed physical set.  It can,
# however, be the exact crash boundary after build.sh published the directory
# and before it retired its external journal/marker.  Hand that shape back to
# build.sh under the inherited lifecycle lock; its trusted journal either
# converges it or rejects it.  Only the marker-free result is classified below.
BUILD_ALREADY_RUN=0
BUILD_TX_ROOT="/lib/modules/.cmpunlocker-transactions"
BUILD_TX_JOURNAL="${BUILD_TX_ROOT}/${KVER}.journal"
BUILD_LEGACY_JOURNAL="${BUILD_TX_ROOT}/${KVER}.legacy.pending"
BUILD_LEGACY_IN_TREE=0
BUILD_UPDATES_DIR="${MODULE_ROOT}/updates"
if [[ -e "${BUILD_UPDATES_DIR}" || -L "${BUILD_UPDATES_DIR}" ]]; then
    [[ -d "${BUILD_UPDATES_DIR}" && ! -L "${BUILD_UPDATES_DIR}" ]] || \
        die "Unsafe kernel updates directory: ${BUILD_UPDATES_DIR}"
    mapfile -d '' -t BUILD_DOT_OBJECTS < <(
        find -P "${BUILD_UPDATES_DIR}" -maxdepth 1 -mindepth 1 \
            -name '.cmpunlocker.*' -print0 &&
        printf '%s\0' '__CMPUNLOCKER_FIND_OK__'
    )
    (( ${#BUILD_DOT_OBJECTS[@]} >= 1 )) || die "Could not scan legacy build transaction objects"
    BUILD_DOT_LAST=$(( ${#BUILD_DOT_OBJECTS[@]} - 1 ))
    [[ "${BUILD_DOT_OBJECTS[$BUILD_DOT_LAST]}" == '__CMPUNLOCKER_FIND_OK__' ]] || \
        die "Could not complete legacy build transaction scan"
    unset 'BUILD_DOT_OBJECTS[BUILD_DOT_LAST]'
    for BUILD_DOT_OBJECT in "${BUILD_DOT_OBJECTS[@]}"; do
        case "$(basename -- "${BUILD_DOT_OBJECT}")" in
            .cmpunlocker.stage.*|.cmpunlocker.backup.*|.cmpunlocker.failed.*)
                BUILD_LEGACY_IN_TREE=1
                ;;
            *) die "Unknown in-tree cmpunlocker transaction object: ${BUILD_DOT_OBJECT}" ;;
        esac
    done
fi
if [[ -e "${MODULE_DIR}/.cmpunlocker-transaction" ||
      -L "${MODULE_DIR}/.cmpunlocker-transaction" ||
      -e "${BUILD_TX_JOURNAL}" || -L "${BUILD_TX_JOURNAL}" ||
      -e "${BUILD_LEGACY_JOURNAL}" || -L "${BUILD_LEGACY_JOURNAL}" ||
      "${BUILD_LEGACY_IN_TREE}" == "1" ]]; then
    info "Handing interrupted module publication state to build.sh recovery"
    run_patched_module_build
    BUILD_ALREADY_RUN=1
fi

INITIAL_RESOLVE_OK=0
if resolve_module_set; then
    INITIAL_RESOLVE_OK=1
fi
if (( DKMS_RECEIPT_PREEXISTED == 1 )) && verify_cmp_physical_set safe; then
    # After a hard cut in exact leaf-by-leaf cleanup, stale modules.dep can
    # resolve missing or mixed files.  The durable receipt plus a complete
    # physical safety-v3 CMP set is sufficient to rebuild metadata first; the
    # post-build cleanup path re-proves exact resolution and tuple absence.
    classify_exact_dkms_tuple || die "Cannot classify the receipted exact DKMS tuple"
    if (( INITIAL_RESOLVE_OK == 0 || CMP_RESOLUTION_EXACT == 0 )); then
        warn "Ignoring stale or mixed pre-cleanup module resolution under a durable DKMS receipt"
    fi
    ok "Verified physical safety-v3 CMP set plus durable DKMS forward-cleanup intent"
elif (( INITIAL_RESOLVE_OK == 0 )); then
    die "Cannot resolve the complete NVIDIA five-module set for ${KVER}"
elif (( CMP_RESOLUTION_EXACT == 1 )); then
    verify_cmp_physical_set legacy || die "The selected cmpunlocker module set is physically invalid"
    if (( DKMS_RECEIPT_PREEXISTED == 1 )); then
        classify_exact_dkms_tuple || die "Cannot classify the receipted exact DKMS tuple"
        ok "Verified durable forward-cleanup intent for the existing cmpunlocker set"
    elif dkms_module_artifacts_present; then
        load_exact_dkms_module_set || \
            die "Unreceipted DKMS artifacts are not one strict NVIDIA five-module set"
        classify_exact_dkms_tuple || die "Cannot classify the unreceipted exact DKMS tuple"
        [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
            die "Unreceipted DKMS artifacts do not map to one exact installed tuple"
        publish_dkms_cleanup_intent || \
            die "Could not durably adopt exact installed DKMS artifacts into forward cleanup"
        ok "Adopted exact installed DKMS artifacts into durable cleanup intent"
    else
        load_stock_module_set || \
            die "Selected cmpunlocker modules lack both cleanup intent and a unique non-DKMS stock fallback"
        ok "Verified exact non-DKMS stock five-module fallback for the existing patched set"
    fi
    ok "Existing cmpunlocker five-module set already wins exact resolution"
else
    if load_exact_dkms_module_set && resolved_is_exact_dkms_set; then
        classify_exact_dkms_tuple || die "Cannot classify the exact winning DKMS tuple"
        if (( DKMS_RECEIPT_PREEXISTED == 0 )); then
            [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
                die "Winning DKMS paths do not map to an exact installed tuple"
            publish_dkms_cleanup_intent || \
                die "Could not durably record DKMS cleanup intent before module build"
        fi
        ok "Verified exact current-kernel DKMS set and durable pre-build cleanup intent"
    else
        load_stock_module_set || \
            die "No unique complete non-DKMS stock NVIDIA ${detected} module set is available before installation"
        for i in "${!MODULE_NAMES[@]}"; do
            [[ "${RESOLVED_MODULE_PATHS[$i]}" == "${STOCK_MODULE_PATHS[$i]}" ]] || \
                die "Mixed or unverified NVIDIA resolver before install: ${MODULE_NAMES[$i]} -> ${RESOLVED_MODULE_PATHS[$i]}"
        done
        if (( DKMS_RECEIPT_PREEXISTED == 1 )); then
            classify_exact_dkms_tuple || die "Cannot classify the receipted exact DKMS tuple"
            ok "Verified exact stock resolver plus durable DKMS forward-cleanup intent"
        elif dkms_module_artifacts_present; then
            load_exact_dkms_module_set || \
                die "Unreceipted DKMS artifacts are not one strict NVIDIA five-module set"
            classify_exact_dkms_tuple || die "Cannot classify the unreceipted exact DKMS tuple"
            [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
                die "Unreceipted DKMS artifacts do not map to one exact installed tuple"
            publish_dkms_cleanup_intent || \
                die "Could not durably adopt exact installed DKMS artifacts before module build"
            ok "Adopted exact installed DKMS artifacts into durable cleanup intent"
        else
            ok "Verified exact non-DKMS stock five-module set; no current-kernel DKMS cleanup is needed"
        fi
    fi
fi

step "Building and installing patched modules"
if (( BUILD_ALREADY_RUN == 0 )); then
    run_patched_module_build
else
    ok "Interrupted build transaction was recovered and completed under the lifecycle lock"
fi

verify_cmp_physical_set safe || die "Patched module directory lacks the exact safety-v3 plus Gen2 five-module set"
resolve_module_set || die "Cannot resolve NVIDIA modules after patched install"
(( CMP_RESOLUTION_EXACT == 1 )) || die "Patched five-module set does not win exact resolver selection"

# Remove DKMS only after build.sh has durably committed and selected the
# complete patched directory plus its initramfs.  The receipt was published
# before build, so SIGKILL at every boundary retries this direction forward.
if (( DKMS_CLEANUP_REQUIRED == 1 )); then
    converge_dkms_cleanup_forward
fi

info "Configuring owned PCIe Gen2 boot files"
atomic_write_text_cas "${GEN2_MODPROBE_PATH}" 0644 "${GEN2_MODPROBE_CONTENT}" \
    "${GEN2_DESIRED_MODPROBE_HASH}" \
    "${GEN2_CAS_OLD_MODPROBE_HASH}" "${GEN2_DESIRED_MODPROBE_HASH}" || \
    die "Could not atomically install ${GEN2_MODPROBE_PATH}; Gen2 pending state retained—do not power-cycle"

# This rebuild is intentionally after the Gen2 modprobe configuration and is
# the final initramfs commit for the module transaction.
depmod -a "${KVER}" || die "Final depmod failed after installing Gen2 options"
rebuild_current_initramfs "${KVER}" || \
    die "Final initramfs rebuild failed after installing Gen2 options; do not power-cycle"
resolve_module_set || die "Cannot resolve NVIDIA modules after final initramfs rebuild"
(( CMP_RESOLUTION_EXACT == 1 )) || die "Final resolver does not select all five cmpunlocker modules"
verify_cmp_physical_set safe || \
    die "Final cmpunlocker module set failed exact metadata and safety-marker validation"

if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    grep -aFq 'CMP Gen2:' "${MODULE_DIR}/nvidia.ko" || \
        die "Patched core module lacks the required Gen2 retrain marker; pending state retained—do not power-cycle"
    atomic_copy_mode_cas "${GEN2_HAMMER_SOURCE}" "${GEN2_HAMMER_PATH}" 0755 \
        "${GEN2_DESIRED_HAMMER_HASH}" \
        "${GEN2_CAS_OLD_HAMMER_HASH}" "${GEN2_DESIRED_HAMMER_HASH}" || \
        die "Could not atomically install ${GEN2_HAMMER_PATH}"
    atomic_copy_mode_cas "${GEN2_UNIT_SOURCE}" "${GEN2_UNIT_PATH}" 0644 \
        "${GEN2_DESIRED_UNIT_HASH}" \
        "${GEN2_CAS_OLD_UNIT_HASH}" "${GEN2_DESIRED_UNIT_HASH}" || \
        die "Could not atomically install ${GEN2_UNIT_PATH}"
    systemctl_sanitized daemon-reload || die "systemd daemon-reload failed for the Gen2 service"
    gen2_manager_identity_is_exact || \
        die "systemd selected an unexpected gen2.service fragment or drop-in"
    systemctl_sanitized enable gen2.service >/dev/null || die "Could not enable gen2.service for next boot"
    gen2_manager_identity_is_exact || \
        die "gen2.service manager identity changed while enabling it"
    ok "Early-boot Gen2 retrain service armed (not started in this session)"
else
    warn "--no-gen2-service given; early-boot PCIe retraining was left unchanged"
fi
gen2_target_matches "${GEN2_UNIT_PATH}" "${GEN2_DESIRED_UNIT_HASH}" || die "Gen2 unit does not match intended ownership hash"
gen2_target_matches "${GEN2_HAMMER_PATH}" "${GEN2_DESIRED_HAMMER_HASH}" || die "Gen2 helper does not match intended ownership hash"
gen2_target_matches "${GEN2_MODPROBE_PATH}" "${GEN2_DESIRED_MODPROBE_HASH}" || die "Gen2 modprobe config does not match intended ownership hash"
atomic_write_text "${GEN2_STATE}" 0600 "${GEN2_RECEIPT_CONTENT}" || die "Could not commit Gen2 ownership receipt"
sync || die "Could not persist the completed Gen2 transaction"
durable_remove "${GEN2_PENDING}" || die "Could not retire the Gen2 pending receipt"

ok "Patched modules installed and selected for the next cold power-on (profile ${CARD_PROFILE})"

configure_iommu_transaction() {
    local plan plan_key changed merged prepare_content source_hash_before
    if (( IOMMU_RECOVERY == 1 )); then
        die "Automatic IOMMU source/boot recovery is disabled; reconcile the pending B/E transaction manually"
    fi

    if (( IOMMU_STATE_PRESENT == 1 )); then
        [[ "$(file_hash "${IOMMU_SOURCE}")" == "${IOMMU_OLD_EXPECTED_HASH}" ]] || \
            die "Managed IOMMU source changed after preflight; refusing point-of-use overwrite"
        if ! plan="$(prepare_iommu_candidate "${IOMMU_SOURCE}" "${IOMMU_BACKEND}" \
            "${IOMMU_PARAMS}" "${IOMMU_KEY}" "${IOMMU_CANDIDATE}")"; then
            die "Could not safely parse the managed IOMMU command-line source"
        fi
        IFS=$'\t' read -r plan_key changed merged <<< "${plan}"
        [[ "${plan_key}" == "${IOMMU_KEY}" && "${changed}" =~ ^[01]$ ]] || die "Invalid IOMMU plan result"
        [[ "$(file_hash "${IOMMU_SOURCE}")" == "${IOMMU_OLD_EXPECTED_HASH}" ]] || \
            die "Managed IOMMU source changed while re-deriving its expected snapshot"
        if [[ "${changed}" == "1" ]]; then
            durable_remove "${IOMMU_CANDIDATE}" || true
            die "Managed IOMMU parameters would change an existing E snapshot; uninstall/reconcile first"
        fi
        durable_remove "${IOMMU_CANDIDATE}" || die "Could not remove unchanged IOMMU candidate"
        ok "Owned IOMMU source already matches its expected snapshot"
        IOMMU_STATUS="already-set"
        return 0
    fi

    prepare_content="$(printf 'format=prepare\nbackend=%s\nsource=%s\ngenerator=%s\ntarget=%s\n' \
        "${IOMMU_BACKEND}" "${IOMMU_SOURCE}" "${IOMMU_GENERATOR}" "${IOMMU_TARGET}")"$'\n'
    atomic_write_text "${IOMMU_PENDING}" 0600 "${prepare_content}" || \
        die "Could not durably publish IOMMU prepare state"
    source_hash_before="$(file_hash "${IOMMU_SOURCE}")"
    if ! plan="$(prepare_iommu_candidate "${IOMMU_SOURCE}" "${IOMMU_BACKEND}" \
        "${IOMMU_PARAMS}" "${IOMMU_KEY}" "${IOMMU_CANDIDATE}")"; then
        die "Could not safely parse or prepare the IOMMU command-line source"
    fi
    IFS=$'\t' read -r plan_key changed merged <<< "${plan}"
    [[ "${changed}" =~ ^[01]$ ]] || die "Invalid IOMMU plan result"
    [[ "$(file_hash "${IOMMU_SOURCE}")" == "${source_hash_before}" ]] || \
        die "IOMMU source changed while deriving the expected snapshot"
    if [[ "${changed}" == "0" ]]; then
        durable_remove "${IOMMU_CANDIDATE}" || die "Could not remove unused IOMMU candidate"
        durable_remove "${IOMMU_PENDING}" || die "Could not retire unused IOMMU prepare state"
        ok "Kernel command line already has ${IOMMU_PARAMS}"
        IOMMU_STATUS="already-set"
        return 0
    fi

    # Boot generators have distro-specific, multi-file mutation surfaces that
    # cannot be made crash-atomic from this installer.  The prepare journal and
    # candidate are still useful for strict parsing, but no source or live boot
    # artifact is changed when parameters are absent.
    durable_remove "${IOMMU_CANDIDATE}" || die "Could not retire the read-only IOMMU candidate"
    durable_remove "${IOMMU_PENDING}" || die "Could not retire the read-only IOMMU prepare state"
    warn "Kernel command line lacks ${IOMMU_PARAMS}; add it with the distribution bootloader tooling"
    IOMMU_STATUS="manual"
}

info "Configuring IOMMU (passthrough)"
if (( CONFIGURE_IOMMU == 0 )); then
    warn "--no-iommu given; leaving kernel command line untouched"
elif [[ -z "${IOMMU_PARAMS}" ]]; then
    warn "Unrecognized CPU vendor — cannot pick IOMMU kernel parameters; skipping"
elif [[ "${IOMMU_STATUS}" == "manual" ]]; then
    :
else
    info "Target: ${IOMMU_PARAMS} (${IOMMU_BACKEND}, ${IOMMU_GENERATOR} -> ${IOMMU_TARGET})"
    configure_iommu_transaction
fi

if grep -qw iommu=pt /proc/cmdline 2>/dev/null && [[ -d /sys/class/iommu ]] && \
   [[ -n "$(ls -A /sys/class/iommu 2>/dev/null)" ]]; then
    ok "IOMMU is already active in passthrough mode on the running kernel"
elif [[ "${IOMMU_STATUS}" == "manual" ]]; then
    warn "IOMMU was not changed; configure ${IOMMU_PARAMS} manually before the cold power cycle"
elif [[ "${IOMMU_STATUS}" != "skipped" ]]; then
    info "IOMMU passthrough takes effect after the next reboot"
    warn "IOMMU must also be enabled in BIOS/UEFI (VT-d / AMD-Vi / SVM)"
fi

cleanup_known_atomic_temps

step "Done"
banner
echo "cmpunlocker install finished!"
echo "Profile: ${CARD_PROFILE}  |  ${#GPU_BDFS[@]} GPU(s): ${COUNT_8GB}× 8gb, ${COUNT_10GB}× 10gb"
if [[ -n "${IOMMU_PARAMS}" && "${IOMMU_STATUS}" != "skipped" ]]; then
    if [[ "${IOMMU_STATUS}" == "manual" ]]; then
        echo "IOMMU:   manual action required: ${IOMMU_PARAMS}"
    else
        echo "IOMMU:   ${IOMMU_PARAMS} (${IOMMU_STATUS})"
    fi
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
if [[ "${IOMMU_STATUS}" == "manual" ]]; then
    echo -e "  0. Add ${CYAN}${IOMMU_PARAMS}${NC} with your distribution bootloader tooling"
fi
echo -e "  1. Required full power cycle: ${CYAN}sudo shutdown -h now${NC}  (then power on)"
echo -e "  2. Verify all GPUs: ${CYAN}sudo ./verify.sh${NC}  (must return 0 before any workload)"
echo -e "  3. Verify PCIe Gen2: ${CYAN}nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max --format=csv${NC}  (expect 2,2)"
echo -e "  4. Capacity shown by ${CYAN}nvidia-smi${NC} is informational only, not a health verdict"
echo -e "  5. Unlock logs: ${CYAN}sudo dmesg | grep SEC2_DEBUG${NC}"
echo -e "  6. Verify IOMMU after power-on: ${CYAN}cat /proc/cmdline${NC} and ${CYAN}ls /sys/class/iommu${NC}"
if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    echo -e "  7. Verify negotiated Gen2: ${CYAN}sudo ./tools/service.sh verify${NC}"
    echo -e "     Recovery boot option: ${CYAN}systemd.mask=gen2.service${NC}"
fi
echo ""
if (( DKMS_CLEANUP_REQUIRED == 1 )); then
    echo "Converged exact NVIDIA DKMS cleanup for ${KVER}; the restore receipt remains for remove.sh."
else
    echo "No current-kernel NVIDIA DKMS cleanup intent was needed; unrelated DKMS records were preserved."
fi
echo "Re-run this script after each kernel upgrade."
echo "Log saved to: ${LOG_FILE}"
echo ""
