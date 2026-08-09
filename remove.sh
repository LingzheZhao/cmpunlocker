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
      MKINITCPIO_POST_HOOKS MKINITCPIO_PRESETS

PYTHON_EXECUTABLE="$(/usr/bin/readlink -f -- /usr/bin/python3 2>/dev/null || :)"
[[ -n "${PYTHON_EXECUTABLE}" && -f "${PYTHON_EXECUTABLE}" && \
   ! -L "${PYTHON_EXECUTABLE}" && -x "${PYTHON_EXECUTABLE}" && \
   "$(/usr/bin/stat -c '%u:%g' -- "${PYTHON_EXECUTABLE}" 2>/dev/null)" == "0:0" ]] || {
    echo "Unsafe or missing system Python interpreter" >&2
    exit 1
}
python3() {
    /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C PYTHONNOUSERSITE=1 \
        "${PYTHON_EXECUTABLE}" -I "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cmpunlocker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/cmpunlocker"
STATE_DIR="/var/lib/cmpunlocker"
TX_ROOT="/lib/modules/.cmpunlocker-transactions"
IOMMU_STATE="${STATE_DIR}/iommu.state"
IOMMU_BASE="${STATE_DIR}/iommu.base"
IOMMU_EXPECTED="${STATE_DIR}/iommu.expected"
IOMMU_CANDIDATE="${STATE_DIR}/iommu.candidate"
IOMMU_INSTALL_PENDING="${STATE_DIR}/iommu.pending"
IOMMU_REMOVE_PENDING="${STATE_DIR}/iommu.remove.pending"
GEN2_STATE="${STATE_DIR}/gen2.state"
GEN2_INSTALL_PENDING="${STATE_DIR}/gen2.pending"
SERVICE_REMOVE_PENDING="${STATE_DIR}/service.remove.pending"
LIFECYCLE_LOCK="${STATE_DIR}/lifecycle.lock"
REMOVE_COMMIT="${STATE_DIR}/remove.commit.pending"
REMOVE_FORWARD="${STATE_DIR}/remove.forward.pending"
DKMS_TREE="/var/lib/dkms"
DKMS_INSTALL_TREE="/usr/lib/modules"
DKMS_SAFE_DIRECTIVES=(
    "--directive=NO_WEAK_MODULES=yes"
    "--directive=BUILD_DEPENDS_REBUILD=no"
    "--directive=PRE_BUILD="
    "--directive=POST_BUILD="
    "--directive=PRE_INSTALL="
    "--directive=POST_INSTALL="
    "--directive=POST_REMOVE="
)

MODULE_FILES=(nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko)
MODULE_QUERIES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm nvidia_peermem)
MODULE_INTERNAL=(nvidia nvidia_modeset nvidia_uvm nvidia_drm nvidia_peermem)
# Byte identities from exact historical Git objects; names alone never
# authorize deletion.  Provenance (commit:path -> blob):
# 9b9fb2f27a618f13e6b016adfc6e86b1e60fa84d:daemon/cmpunlocker.service
#   -> 742dfe7138eac873a57f901b20237b1868eb3ef9
# 746d9f78643399cc1aff2475977e674057390658:tools/cmpretrain.service
#   -> 4c44de15a6668b861209a8e68bafaeca5aa802d4
# d88af88d5fa9818b34cecd63e2e2749bfca2c240:tools/cmpretrain.service
#   -> a81dd2ab295711f2d45088c4ebbad94df7853414
LEGACY_WATCHDOG_UNIT_HASHES=(
    fde8bf584e9817a22312d04d93d5fec172b572b5af99ba19ea984338d733e390
)
LEGACY_RETRAIN_UNIT_HASHES=(
    c63cb7fc92b706492cdfb510003a5f5e07d30bc7262f9a1799a00c6ac8483757
    f555109885e8a04a742c32a121eee4d0195fe966df78a826c917f62227a5ee5e
)
LEGACY_RETRAIN_HELPER_HASHES=(
    # tools/retrain.sh blobs, respectively:
    # 7047108f20eb6bdcff7a564d2642f9631254a590 (746d9f78643399cc1aff2475977e674057390658)
    # 03cfaa3f6a4b103811cbadc81738277a635f0698 (d88af88d5fa9818b34cecd63e2e2749bfca2c240)
    # 4e3c1173001daa74ebbfe94f781266aa8a0ef972 (146da6ff102cb255d461d8fee19b2d6ae3680df9)
    0a4a5a52742114188a4fa4d2a27b6f8e590a3be471cf91f1b0939ca3396fdfca
    688b6fd163646c0340837bd7b8c303bf0ecc3607ba98811fa9f8e11c96531543
    a955b7e80c38f5dcbf1084978833eff77fe59153dda965139e84bb10cd559ab9
)
# e50e8738ef24357cfa9e32ff1ebd76cba3ceb24f:systemd/gen2.service
# -> fae80054d9eee1d38234d5d16d42a32a4b676a91 (WantedBy=sysinit.target).
GEN2_SYSINIT_UNIT_HASH="d4583a1f67c42b3ec5ee31dd92f9103af293a3d12899e4d84885ba8c82494b0f"
# Exact tracked hammer revisions copied by tools/service.sh to
# /usr/local/sbin/gen2-hammer.  Provenance (commit:path -> blob):
# 2e0a2c02308ff4cd9036d16c1e2e693515eb878e:tools/hammer.sh
# e50e8738ef24357cfa9e32ff1ebd76cba3ceb24f:tools/hammer.sh
#   -> 2b914a17084a50b2b879fc8fb6197ffefa50264e
# 85ce74a8b57d179d10ae2ee4043f795fdd798139:tools/hammer.sh
#   -> 66e6278effd61e6389cb2d3b5c4a70357bdb572a
# 360acd7ac1d83d1024ce4b91ae3cf797f148d4f2:tools/hammer.sh
#   -> 76fa17b53596cb00d18043dce54589fd8c059575
GEN2_LEGACY_HAMMER_HASHES=(
    eebcd890b64921da9c2b30f0656c63b02b8ac58bf620f62f35c07a24fa59f02b
    3cf42a042a0be4eb68823ce6f6af1cbefb5e8e333c2103e54676dbaea1b07a3f
    fff46137f849f243bad600833acd9e3cd476002287634d5c02d9657fc77688da
)
SYSTEMD_RESERVED_UNITS=(
    cmpunlocker.service
    cmpretrain.service
    cmp-gen2-retrain.service
    gen2.service
)
SYSTEMD_UNIT_ROOTS=(
    /etc/systemd/system.control
    /run/systemd/system.control
    /run/systemd/transient
    /run/systemd/generator.early
    /etc/systemd/system
    /etc/systemd/system.attached
    /run/systemd/system
    /run/systemd/system.attached
    /run/systemd/generator
    /usr/local/lib/systemd/system
    /usr/lib/systemd/system
    /lib/systemd/system
    /run/systemd/generator.late
)
SERVICE_SYSTEMD_MUTATION_REQUIRED=0
GEN2_SYSTEMD_MUTATION_REQUIRED=0
declare -A SERVICE_REMOVE_DATA=()
SERVICE_REMOVE_PRESENT=0
SERVICE_PENDING_WATCHDOG_HASH="absent"
SERVICE_PENDING_WATCHDOG_LINK="absent"
SERVICE_PENDING_RETRAIN_HASH="absent"
SERVICE_PENDING_RETRAIN_LINK="absent"

source "${SCRIPT_DIR}/common/lib.sh"

banner

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
    warn "This removes cmpunlocker patched kernel modules:"
    echo "  - Stops cmpunlocker systemd service"
    echo "  - Removes /lib/modules/*/updates/cmpunlocker/"
    echo "  - Removes ${INSTALL_DIR} (legacy install dir, if present)"
    echo "  - Leaves the running driver untouched until a mandatory cold power cycle"
    echo "  - Removes only receipt-owned PCIe Gen2 helpers"
    echo "  - Restores the receipt-bound pre-install kernel command line"
    echo ""
    echo "Run: sudo ./remove.sh --yes"
    exit 1
fi

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./remove.sh --yes"
[[ -x /usr/bin/id ]] || die "Required command not found: /usr/bin/id"
REMOVE_EFFECTIVE_GID="$(/usr/bin/id -g 2>/dev/null)" || die "Could not determine effective group"
[[ "${REMOVE_EFFECTIVE_GID}" =~ ^[0-9]+$ && \
   "${REMOVE_EFFECTIVE_GID}" != *$'\n'* ]] || die "Invalid effective group result"
if (( 10#${REMOVE_EFFECTIVE_GID} != 0 )); then
    exec /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C PYTHONNOUSERSITE=1 \
        "${PYTHON_EXECUTABLE}" -I - "${BASH_SOURCE[0]}" "$@" <<'PY'
import os
import pathlib
import stat
import sys

script = pathlib.Path(sys.argv[1]).resolve(strict=True)
st = os.lstat(script)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
    raise SystemExit("unsafe remove script path")
os.setgid(0)
os.execv("/bin/bash", ["bash", str(script), *sys.argv[2:]])
PY
fi
umask 077
unset ADDON_MODULES_DIR source_tree dkms_tree install_tree tmp_location verbose \
      symlink_modules autoinstall_all_kernels modprobe_on_install parallel_jobs \
      compress_gzip_opts compress_xz_opts compress_zstd_opts build_environment \
      post_transaction sign_file mok_signing_key mok_certificate try_sign_modules \
      TMPDIR MODULES_SIGN_KEY MODULES_SIGN_CERT

step_init 6

step "Verifying root privileges and durable state"

LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="/tmp"
fi
LOG_FILE="${LOG_DIR}/remove_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

shopt -s nullglob

valid_kernel() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

valid_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_root_file() {
    local path="$1"
    local require_private="${2:-0}"
    local owner group mode

    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    owner="$(stat -c %u -- "${path}")" || return 1
    group="$(stat -c %g -- "${path}")" || return 1
    [[ "${owner}" == "0" && "${group}" == "0" ]] || return 1
    if (( require_private == 1 )); then
        mode="$(stat -c %a -- "${path}")" || return 1
        [[ "${mode}" == "600" && "$(stat -c %h -- "${path}")" == "1" ]] || return 1
    fi
}

validate_root_managed_file() {
    local path="$1" parent mode

    validate_root_file "${path}" 0 || return 1
    [[ "$(stat -c %h -- "${path}" 2>/dev/null)" == "1" ]] || return 1
    mode="$(stat -c %a -- "${path}" 2>/dev/null)" || return 1
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${mode} & 8#22) == 0 )) || return 1
    parent="$(dirname -- "${path}")"
    [[ -d "${parent}" && ! -L "${parent}" && \
       "$(readlink -f -- "${parent}" 2>/dev/null)" == "${parent}" && \
       "$(stat -c '%u:%g' -- "${parent}" 2>/dev/null)" == "0:0" && \
       "$(stat -c %d -- "${path}" 2>/dev/null)" == \
         "$(stat -c %d -- "${parent}" 2>/dev/null)" ]] || return 1
    mode="$(stat -c %a -- "${parent}" 2>/dev/null)" || return 1
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] && (( (8#${mode} & 8#22) == 0 ))
}

SYSTEMCTL_EXECUTABLE="/usr/bin/systemctl"
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

systemctl_sanitized() {
    /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C "${SYSTEMCTL_EXECUTABLE}" "$@"
}

create_private_root_dir_if_absent() {
    local path="$1"

    python3 - "${path}" <<'PY'
import os
import stat
import sys

path = os.fsencode(sys.argv[1])
parent = os.path.dirname(path)
pst = os.lstat(parent)
if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != 0 or pst.st_gid != 0):
    raise SystemExit("unsafe private-directory parent")
try:
    os.lstat(path)
except FileNotFoundError:
    if os.geteuid() != 0:
        raise SystemExit("private root directory requires EUID 0")
    os.setegid(0)
    old_umask = os.umask(0)
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    finally:
        os.umask(old_umask)
    dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
PY
}

prepare_state_dir() {
    local owner group mode

    [[ ! -L "${STATE_DIR}" ]] || die "Refusing symlink state directory ${STATE_DIR}"
    if [[ ! -e "${STATE_DIR}" ]]; then
        create_private_root_dir_if_absent "${STATE_DIR}" || \
            die "Could not safely create ${STATE_DIR}"
    fi
    [[ -d "${STATE_DIR}" && ! -L "${STATE_DIR}" ]] || \
        die "Unsafe state directory ${STATE_DIR}"
    owner="$(stat -c %u -- "${STATE_DIR}")"
    group="$(stat -c %g -- "${STATE_DIR}")"
    mode="$(stat -c %a -- "${STATE_DIR}")"
    [[ "${owner}" == "0" && "${group}" == "0" && "${mode}" == "700" ]] || \
        die "${STATE_DIR} must be root:root mode 0700"
    sync -f "${STATE_DIR}" || die "Cannot persist ${STATE_DIR}"
}

atomic_copy_file() {
    local source="$1"
    local target="$2"
    local target_dir target_base temp target_mode target_uid target_gid
    local preserve_target_metadata=0

    [[ -f "${source}" && ! -L "${source}" ]] || return 1
    if [[ -e "${target}" || -L "${target}" ]]; then
        [[ -f "${target}" && ! -L "${target}" ]] || return 1
        target_mode="$(stat -c %a -- "${target}")" || return 1
        target_uid="$(stat -c %u -- "${target}")" || return 1
        target_gid="$(stat -c %g -- "${target}")" || return 1
        preserve_target_metadata=1
    fi
    target_dir="$(dirname -- "${target}")"
    target_base="$(basename -- "${target}")"
    [[ -d "${target_dir}" && ! -L "${target_dir}" ]] || return 1
    temp="$(mktemp "${target_dir}/.cmpunlocker-remove.${target_base}.tmp.XXXXXX")" || return 1
    if ! cp -a -- "${source}" "${temp}"; then
        rm -f -- "${temp}" 2>/dev/null || true
        return 1
    fi
    if [[ "${target_dir}" == "${STATE_DIR}" ]]; then
        if ! chmod 0600 "${temp}" || ! chown 0:0 "${temp}"; then
            rm -f -- "${temp}" 2>/dev/null || true
            return 1
        fi
    elif (( preserve_target_metadata == 1 )); then
        if ! chmod "${target_mode}" "${temp}" || ! chown "${target_uid}:${target_gid}" "${temp}"; then
            rm -f -- "${temp}" 2>/dev/null || true
            return 1
        fi
    fi
    if ! sync -f "${temp}" || ! mv -fT -- "${temp}" "${target}" || \
       ! sync -f "${target_dir}"; then
        rm -f -- "${temp}" 2>/dev/null || true
        return 1
    fi
}

atomic_restore_iommu_source() {
    local snapshot="$1" target="$2" expected_current="$3" expected_new="$4"
    local expected_parent_dev="$5" expected_parent_ino="$6"
    python3 - "${snapshot}" "${target}" "${expected_current}" "${expected_new}" \
        "${expected_parent_dev}" "${expected_parent_ino}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

snapshot, target = map(pathlib.Path, sys.argv[1:3])
expected_current, expected_new = sys.argv[3:5]
expected_parent_dev, expected_parent_ino = map(int, sys.argv[5:7])
if (target not in (pathlib.Path("/etc/default/grub"),
                   pathlib.Path("/etc/kernel/cmdline"))
        or re.fullmatch(r"[a-f0-9]{64}", expected_current) is None
        or re.fullmatch(r"[a-f0-9]{64}", expected_new) is None
        or min(expected_parent_dev, expected_parent_ino) <= 0):
    raise SystemExit("invalid IOMMU source restore authority")

def digest_fd(fd):
    value = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        value.update(block)
    return value.hexdigest()

def read_xattrs(fd):
    return tuple((name, os.getxattr(fd, name))
                 for name in sorted(os.listxattr(fd)))

def install_xattrs(fd, expected):
    wanted = dict(expected)
    for name in os.listxattr(fd):
        if name not in wanted:
            os.removexattr(fd, name)
    for name, value in expected:
        os.setxattr(fd, name, value)
    if read_xattrs(fd) != expected:
        raise SystemExit("IOMMU source replacement xattrs did not round-trip")

def strict_mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

parent = target.parent
if parent not in (pathlib.Path("/etc/default"), pathlib.Path("/etc/kernel")):
    raise SystemExit("invalid literal IOMMU source parent")
mounted = strict_mounts()
allowed_ancestor_mounts = {"/", "/etc"}
for ancestor in (pathlib.Path("/"), pathlib.Path("/etc"), parent):
    normalized = os.path.normpath(os.fspath(ancestor))
    if normalized in mounted and normalized not in allowed_ancestor_mounts:
        raise SystemExit(f"mount redirects IOMMU source ancestor: {ancestor}")
aliases = {os.path.normpath(os.fspath(target)),
           os.path.normpath(os.path.realpath(target))}
if aliases & mounted:
    raise SystemExit("mount blocks IOMMU source restore")

dir_flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
             | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
ancestor_fds = []
chain = []
root_fd = os.open("/", dir_flags)
ancestor_fds.append(root_fd)
root_st = os.fstat(root_fd)
current_fd = root_fd
for component in ("etc", parent.name):
    lst = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
    child_fd = os.open(component, dir_flags, dir_fd=current_fd)
    fst = os.fstat(child_fd)
    if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISDIR(fst.st_mode) or fst.st_uid != 0
            or fst.st_gid != 0 or stat.S_IMODE(fst.st_mode) & 0o022):
        raise SystemExit(f"unsafe literal IOMMU source ancestor: {component}")
    chain.append((current_fd, component, child_fd, fst))
    ancestor_fds.append(child_fd)
    current_fd = child_fd
dfd = current_fd
pst = os.fstat(dfd)
if (pst.st_dev, pst.st_ino) != (expected_parent_dev, expected_parent_ino):
    raise SystemExit("IOMMU source parent differs from its durable receipt")

def verify_chain():
    opened_root = os.fstat(root_fd)
    if (not stat.S_ISDIR(opened_root.st_mode)
            or (opened_root.st_dev, opened_root.st_ino) !=
               (root_st.st_dev, root_st.st_ino)
            or opened_root.st_uid != root_st.st_uid
            or opened_root.st_gid != root_st.st_gid
            or stat.S_IMODE(opened_root.st_mode) != stat.S_IMODE(root_st.st_mode)
            or opened_root.st_uid != 0 or opened_root.st_gid != 0
            or stat.S_IMODE(opened_root.st_mode) & 0o022):
        raise SystemExit("IOMMU source root identity changed")
    for parent_fd, name, child_fd, expected in chain:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(child_fd)
        for observed in (current, opened):
            if (not stat.S_ISDIR(observed.st_mode)
                    or (observed.st_dev, observed.st_ino) !=
                       (expected.st_dev, expected.st_ino)
                    or observed.st_uid != expected.st_uid
                    or observed.st_gid != expected.st_gid
                    or stat.S_IMODE(observed.st_mode) !=
                       stat.S_IMODE(expected.st_mode)
                    or observed.st_uid != 0 or observed.st_gid != 0
                    or stat.S_IMODE(observed.st_mode) & 0o022):
                raise SystemExit("literal IOMMU source ancestry changed")
    opened_parent = os.fstat(dfd)
    if ((opened_parent.st_dev, opened_parent.st_ino) != (pst.st_dev, pst.st_ino)
            or opened_parent.st_uid != pst.st_uid
            or opened_parent.st_gid != pst.st_gid
            or stat.S_IMODE(opened_parent.st_mode) != stat.S_IMODE(pst.st_mode)
            or mounted != strict_mounts()):
        raise SystemExit("IOMMU source parent or mount topology changed")

target_fd = source_fd = temp_fd = new_fd = -1
candidate_name = f".cmpunlocker-remove.{target.name}.tmp.{expected_new}"
temp_name = None
temp_identity = None
try:
    verify_chain()
    opened_parent = os.fstat(dfd)
    if ((opened_parent.st_dev, opened_parent.st_ino) != (pst.st_dev, pst.st_ino)
            or opened_parent.st_uid != pst.st_uid
            or opened_parent.st_gid != pst.st_gid
            or stat.S_IMODE(opened_parent.st_mode) != stat.S_IMODE(pst.st_mode)
            or opened_parent.st_uid != 0 or opened_parent.st_gid != 0
            or stat.S_IMODE(opened_parent.st_mode) & 0o022):
        raise SystemExit("IOMMU source parent changed while opening")
    shared = [entry.name for entry in os.scandir(dfd)
              if entry.name.startswith(".cmpunlocker-remove.")
              or entry.name.startswith(".cmpunlocker-install.")]
    if any(name.startswith(".cmpunlocker-install.") for name in shared):
        raise SystemExit("install-side shared temp requires install-side recovery")
    if any(name != candidate_name for name in shared):
        raise SystemExit("unbound shared IOMMU source temp requires manual reconciliation")
    if candidate_name in shared:
        stale_fd = os.open(candidate_name, os.O_RDONLY
                           | getattr(os, "O_CLOEXEC", 0)
                           | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
        try:
            stale_st = os.fstat(stale_fd)
            stale_path = os.stat(candidate_name, dir_fd=dfd,
                                 follow_symlinks=False)
            if ((stale_path.st_dev, stale_path.st_ino) !=
                    (stale_st.st_dev, stale_st.st_ino)
                    or not stat.S_ISREG(stale_st.st_mode)
                    or stale_st.st_uid != 0 or stale_st.st_gid != 0
                    or stale_st.st_nlink != 1
                    or stat.S_IMODE(stale_st.st_mode) & 0o022
                    or stale_st.st_dev != pst.st_dev):
                raise SystemExit("unsafe receipt-bound IOMMU source temp")
            verify_chain()
            current_stale = os.stat(candidate_name, dir_fd=dfd,
                                    follow_symlinks=False)
            held_stale = os.fstat(stale_fd)
            if ((current_stale.st_dev, current_stale.st_ino) !=
                    (stale_st.st_dev, stale_st.st_ino)
                    or (held_stale.st_dev, held_stale.st_ino) !=
                       (stale_st.st_dev, stale_st.st_ino)
                    or current_stale.st_uid != held_stale.st_uid
                    or current_stale.st_gid != held_stale.st_gid
                    or current_stale.st_nlink != held_stale.st_nlink
                    or current_stale.st_size != held_stale.st_size
                    or current_stale.st_mtime_ns != held_stale.st_mtime_ns
                    or current_stale.st_ctime_ns != held_stale.st_ctime_ns
                    or stat.S_IMODE(current_stale.st_mode) !=
                       stat.S_IMODE(held_stale.st_mode)):
                raise SystemExit("receipt-bound IOMMU source temp changed before cleanup")
            os.unlink(candidate_name, dir_fd=dfd)
            os.fsync(dfd)
        finally:
            os.close(stale_fd)
        verify_chain()
    target_lst = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    target_fd = os.open(target.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                        | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    tst = os.fstat(target_fd)
    if ((tst.st_dev, tst.st_ino) != (target_lst.st_dev, target_lst.st_ino)
            or not stat.S_ISREG(tst.st_mode) or tst.st_uid != 0 or tst.st_gid != 0
            or tst.st_nlink != 1 or stat.S_IMODE(tst.st_mode) & 0o022
            or tst.st_dev != pst.st_dev):
        raise SystemExit("unsafe live IOMMU source")
    live_hash = digest_fd(target_fd)
    target_xattrs = read_xattrs(target_fd)
    if live_hash == expected_new:
        verify_chain()
        current = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
        if ((current.st_dev, current.st_ino) != (tst.st_dev, tst.st_ino)
                or current.st_uid != tst.st_uid or current.st_gid != tst.st_gid
                or stat.S_IMODE(current.st_mode) != stat.S_IMODE(tst.st_mode)
                or digest_fd(target_fd) != expected_new
                or read_xattrs(target_fd) != target_xattrs
                or aliases & strict_mounts()):
            raise SystemExit("existing IOMMU source content or metadata changed")
        os.fsync(target_fd)
        os.fsync(dfd)
        raise SystemExit(0)
    if live_hash != expected_current:
        raise SystemExit("IOMMU source changed before restore")
    source_fd = os.open(snapshot, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                        | getattr(os, "O_NOFOLLOW", 0))
    sst = os.fstat(source_fd)
    if (not stat.S_ISREG(sst.st_mode) or sst.st_uid != 0 or sst.st_gid != 0
            or sst.st_nlink != 1 or digest_fd(source_fd) != expected_new):
        raise SystemExit("IOMMU base snapshot changed")
    temp_fd = os.open(candidate_name, os.O_RDWR | os.O_CREAT | os.O_EXCL
                      | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                      stat.S_IMODE(tst.st_mode), dir_fd=dfd)
    temp_name = candidate_name
    created_temp = os.fstat(temp_fd)
    temp_identity = (created_temp.st_dev, created_temp.st_ino)
    os.lseek(source_fd, 0, os.SEEK_SET)
    while True:
        block = os.read(source_fd, 1024 * 1024)
        if not block:
            break
        view = memoryview(block)
        while view:
            view = view[os.write(temp_fd, view):]
    os.fchown(temp_fd, tst.st_uid, tst.st_gid)
    os.fchmod(temp_fd, stat.S_IMODE(tst.st_mode))
    install_xattrs(temp_fd, target_xattrs)
    os.fsync(temp_fd)
    temp_st = os.fstat(temp_fd)
    if (not stat.S_ISREG(temp_st.st_mode) or temp_st.st_uid != tst.st_uid
            or temp_st.st_gid != tst.st_gid or temp_st.st_nlink != 1
            or stat.S_IMODE(temp_st.st_mode) != stat.S_IMODE(tst.st_mode)
            or temp_st.st_dev != pst.st_dev
            or digest_fd(temp_fd) != expected_new
            or read_xattrs(temp_fd) != target_xattrs):
        raise SystemExit("IOMMU source temp content or metadata mismatch")
    verify_chain()
    current = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    current_temp = os.stat(temp_name, dir_fd=dfd, follow_symlinks=False)
    held_temp = os.fstat(temp_fd)
    if ((current.st_dev, current.st_ino) != (tst.st_dev, tst.st_ino)
            or current.st_uid != tst.st_uid or current.st_gid != tst.st_gid
            or stat.S_IMODE(current.st_mode) != stat.S_IMODE(tst.st_mode)
            or digest_fd(target_fd) != expected_current
            or read_xattrs(target_fd) != target_xattrs
            or (current_temp.st_dev, current_temp.st_ino) !=
               (temp_st.st_dev, temp_st.st_ino)
            or (held_temp.st_dev, held_temp.st_ino) !=
               (temp_st.st_dev, temp_st.st_ino)
            or not stat.S_ISREG(current_temp.st_mode)
            or current_temp.st_uid != temp_st.st_uid
            or current_temp.st_gid != temp_st.st_gid
            or current_temp.st_nlink != temp_st.st_nlink
            or stat.S_IMODE(current_temp.st_mode) != stat.S_IMODE(temp_st.st_mode)
            or current_temp.st_size != temp_st.st_size
            or digest_fd(temp_fd) != expected_new
            or read_xattrs(temp_fd) != target_xattrs
            or mounted != strict_mounts()):
        raise SystemExit("IOMMU source changed before atomic publication")
    os.replace(temp_name, target.name, src_dir_fd=dfd, dst_dir_fd=dfd)
    temp_name = None
    new_fd = os.open(target.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                     | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    nst = os.fstat(new_fd)
    if ((nst.st_dev, nst.st_ino) != (temp_st.st_dev, temp_st.st_ino)
            or not stat.S_ISREG(nst.st_mode) or nst.st_uid != tst.st_uid
            or nst.st_gid != tst.st_gid or nst.st_nlink != 1
            or stat.S_IMODE(nst.st_mode) != stat.S_IMODE(tst.st_mode)
            or digest_fd(new_fd) != expected_new
            or read_xattrs(new_fd) != target_xattrs):
        raise SystemExit("published IOMMU source metadata or content mismatch")
    os.fsync(new_fd)
    os.fsync(dfd)
    verify_chain()
finally:
    if temp_name is not None:
        try:
            verify_chain()
            if temp_fd < 0 or temp_identity is None:
                raise SystemExit("IOMMU source temp name was never owned")
            current_temp = os.stat(temp_name, dir_fd=dfd, follow_symlinks=False)
            held_temp = os.fstat(temp_fd)
            if ((current_temp.st_dev, current_temp.st_ino) != temp_identity
                    or (held_temp.st_dev, held_temp.st_ino) != temp_identity
                    or not stat.S_ISREG(current_temp.st_mode)
                    or not stat.S_ISREG(held_temp.st_mode)
                    or current_temp.st_uid != held_temp.st_uid
                    or current_temp.st_gid != held_temp.st_gid
                    or current_temp.st_nlink != held_temp.st_nlink
                    or held_temp.st_nlink != 1
                    or stat.S_IMODE(current_temp.st_mode) !=
                       stat.S_IMODE(held_temp.st_mode)
                    or held_temp.st_dev != pst.st_dev):
                raise SystemExit("refusing to remove a changed IOMMU source temp")
            os.unlink(temp_name, dir_fd=dfd)
            os.fsync(dfd)
        except FileNotFoundError:
            pass
    for fd in (new_fd, temp_fd, source_fd, target_fd):
        if fd >= 0:
            os.close(fd)
    for ancestor_fd in reversed(ancestor_fds):
        os.close(ancestor_fd)
PY
}

durable_write_state() {
    local target="$1"
    shift
    local target_dir target_base temp

    target_dir="$(dirname -- "${target}")"
    target_base="$(basename -- "${target}")"
    [[ "${target_dir}" == "${STATE_DIR}" ]] || return 1
    temp="$(mktemp "${target_dir}/.cmpunlocker-remove.${target_base}.tmp.XXXXXX")" || return 1
    if ! chmod 0600 "${temp}" || ! chown 0:0 "${temp}" || \
       ! printf '%s\n' "$@" > "${temp}" || \
       ! sync -f "${temp}" || ! mv -fT -- "${temp}" "${target}" || \
       ! sync -f "${target_dir}"; then
        rm -f -- "${temp}" 2>/dev/null || true
        return 1
    fi
}

durable_write_state_noreplace() {
    local target="$1"
    shift
    local target_dir target_base temp

    target_dir="$(dirname -- "${target}")"
    target_base="$(basename -- "${target}")"
    [[ "${target_dir}" == "${STATE_DIR}" && \
       ! -e "${target}" && ! -L "${target}" ]] || return 1
    temp="$(mktemp "${target_dir}/.cmpunlocker-remove.${target_base}.tmp.XXXXXX")" || return 1
    if ! chmod 0600 "${temp}" || ! chown 0:0 "${temp}" || \
       ! printf '%s\n' "$@" > "${temp}" || ! sync -f "${temp}"; then
        rm -f -- "${temp}" 2>/dev/null || true
        return 1
    fi
    if ! python3 - "${temp}" "${target}" <<'PY'
import ctypes
import errno
import os
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
if source.parent != target.parent:
    raise SystemExit("atomic state paths have different parents")
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    raise SystemExit("renameat2 is unavailable")
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                      ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
dfd = os.open(source.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
              | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
try:
    if renameat2(dfd, os.fsencode(source.name), dfd, os.fsencode(target.name), 1) != 0:
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            raise SystemExit("state target appeared before no-replace publication")
        raise OSError(error, os.strerror(error), target)
    os.fsync(dfd)
finally:
    os.close(dfd)
PY
    then
        rm -f -- "${temp}" 2>/dev/null || true
        return 1
    fi
}

durable_remove_file() {
    local target="$1"
    local target_dir

    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        return 0
    fi
    [[ -f "${target}" && ! -L "${target}" ]] || return 1
    target_dir="$(dirname -- "${target}")"
    rm -f -- "${target}" || return 1
    sync -f "${target_dir}" || return 1
}

managed_state_temp_target() {
    local base="$1" kernel

    case "${base}" in
        iommu.state|iommu.base|iommu.expected|iommu.candidate|iommu.pending|iommu.remove.pending|\
        gen2.state|gen2.pending|service.remove.pending|remove.commit.pending|remove.forward.pending)
            return 0
            ;;
        remove.*.state)
            kernel="${base#remove.}"
            kernel="${kernel%.state}"
            valid_kernel "${kernel}" && [[ "${base}" == "remove.${kernel}.state" ]]
            return
            ;;
        dkms-removed.*.receipt)
            kernel="${base#dkms-removed.}"
            kernel="${kernel%.receipt}"
            valid_kernel "${kernel}" && [[ "${base}" == "dkms-removed.${kernel}.receipt" ]]
            return
            ;;
        *) return 1 ;;
    esac
}

validate_atomic_temp_candidate() {
    local candidate="$1" owner="$2" expected_base="${3:-}"
    local name payload base suffix owner_links

    [[ -f "${candidate}" && ! -L "${candidate}" ]] || return 1
    owner_links="$(stat -c '%u:%h' -- "${candidate}" 2>/dev/null)" || return 1
    [[ "${owner_links}" == "0:1" ]] || return 1
    name="${candidate##*/}"
    case "${owner}" in
        remove) payload="${name#.cmpunlocker-remove.}" ;;
        install) payload="${name#.cmpunlocker-install.}" ;;
        *) return 1 ;;
    esac
    if [[ "${owner}" == "remove" ]]; then
        [[ "${payload}" != "${name}" && \
           "${payload}" =~ ^(.+)\.tmp\.([A-Za-z0-9]{6})$ ]] || return 1
    else
        [[ "${payload}" != "${name}" && \
           "${payload}" =~ ^(.+)\.tmp\.([A-Za-z0-9_]+)$ ]] || return 1
    fi
    base="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    [[ -n "${base}" && -n "${suffix}" && \
       "${name}" == ".cmpunlocker-${owner}.${base}.tmp.${suffix}" ]] || return 1
    [[ -z "${expected_base}" || "${base}" == "${expected_base}" ]] || return 1
    ATOMIC_TEMP_BASE="${base}"
}

reclaim_atomic_temp() {
    local candidate="$1"

    durable_remove_file "${candidate}" || \
        die "Could not reclaim interrupted atomic-write artifact ${candidate}"
}

cleanup_known_atomic_temps() {
    local candidate name owner base firmware_dir version path

    # STATE_DIR is a private root namespace, but each interrupted object must
    # still prove an exact writer namespace, managed target, root owner, and a
    # single link before it can be reclaimed.
    for owner in remove install; do
        for candidate in "${STATE_DIR}/.cmpunlocker-${owner}."*.tmp.*; do
            validate_atomic_temp_candidate "${candidate}" "${owner}" || \
                die "Unsafe interrupted state-write artifact ${candidate}"
            managed_state_temp_target "${ATOMIC_TEMP_BASE}" || \
                die "Unbound interrupted state-write artifact ${candidate}"
        done
    done
    for owner in remove install; do
        for candidate in "${STATE_DIR}/.cmpunlocker-${owner}."*.tmp.*; do
            reclaim_atomic_temp "${candidate}"
        done
    done
    for candidate in "${STATE_DIR}"/.cmpunlocker-*; do
        die "Unknown hidden state object ${candidate}"
    done

    # The shared IOMMU parents were already inspected through retained literal
    # dirfds.  Other shared namespaces are never mutated during startup.
    for path in /etc/systemd/system /usr/local/sbin /etc/modprobe.d; do
        [[ -d "${path}" && ! -L "${path}" ]] || continue
        for candidate in "${path}"/.cmpunlocker-remove.* \
                         "${path}"/.cmpunlocker-install.*; do
            die "Unknown interrupted atomic-write artifact ${candidate}"
        done
    done
}

validate_state_namespace_names() {
    local path base kernel

    while IFS= read -r -d '' path; do
        base="${path##*/}"
        case "${base}" in
            lifecycle.lock|iommu.state|iommu.base|iommu.expected|iommu.candidate|iommu.pending|\
            iommu.remove.pending|gen2.state|gen2.pending|service.remove.pending|remove.commit.pending|\
            remove.forward.pending)
                ;;
            remove.*.state)
                kernel="${base#remove.}"
                kernel="${kernel%.state}"
                valid_kernel "${kernel}" && [[ "${base}" == "remove.${kernel}.state" ]] || \
                    die "Unsafe removal-state name ${path}"
                ;;
            dkms-removed.*.receipt)
                kernel="${base#dkms-removed.}"
                kernel="${kernel%.receipt}"
                valid_kernel "${kernel}" && \
                    [[ "${base}" == "dkms-removed.${kernel}.receipt" ]] || \
                    die "Unsafe DKMS receipt name ${path}"
                ;;
            *) die "Unknown durable state object ${path}" ;;
        esac
    done < <(find -P "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print0)
}

read_kv_state() {
    local path="$1"
    local allowed="$2"
    local output_name="$3"
    local key value index last_index
    local -a fields=()
    local -n output="${output_name}"

    mapfile -d '' -t fields < <(python3 - "${path}" "${allowed}" <<'PY'
import os
import re
import stat
import sys

path = os.fsencode(sys.argv[1])
allowed = set(sys.argv[2].split(","))
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError as error:
    raise SystemExit(f"cannot open private state: {error}")
try:
    before = os.fstat(fd)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != 0 or before.st_gid != 0
            or stat.S_IMODE(before.st_mode) != 0o600 or before.st_nlink != 1
            or before.st_size <= 0 or before.st_size > 1024 * 1024):
        raise SystemExit("unsafe private state metadata")
    data = bytearray()
    while len(data) <= 1024 * 1024:
        block = os.read(fd, min(65536, 1024 * 1024 + 1 - len(data)))
        if not block:
            break
        data.extend(block)
    after = os.fstat(fd)
    if ((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
         before.st_ctime_ns) !=
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
         after.st_ctime_ns)):
        raise SystemExit("private state changed while reading")
finally:
    os.close(fd)

raw = bytes(data)
if len(raw) != before.st_size or not raw.endswith(b"\n"):
    raise SystemExit("private state is truncated or oversized")
if any(byte == 0 or byte == 13 or byte >= 0x7f or
       (byte < 0x20 and byte != 0x0a) for byte in raw):
    raise SystemExit("private state contains non-canonical bytes")
records = raw[:-1].split(b"\n")
if not records or any(not record for record in records):
    raise SystemExit("private state contains an empty record")
seen = set()
out = sys.stdout.buffer
for record in records:
    if b"=" not in record:
        raise SystemExit("private state record has no assignment")
    key, value = record.split(b"=", 1)
    if re.fullmatch(rb"[a-z_][a-z0-9_]*", key) is None:
        raise SystemExit("private state has an invalid key")
    decoded = key.decode("ascii")
    if decoded not in allowed or decoded in seen:
        raise SystemExit("private state has an unknown or duplicate key")
    seen.add(decoded)
    out.write(key + b"\0" + value + b"\0")
out.write(b"__CMPUNLOCKER_KV_EOF__\0")
PY
) || return 1
    (( ${#fields[@]} > 0 )) || return 1
    last_index=$(( ${#fields[@]} - 1 ))
    [[ "${fields[$last_index]}" == "__CMPUNLOCKER_KV_EOF__" ]] || return 1
    unset 'fields[last_index]'
    (( ${#fields[@]} > 0 && ${#fields[@]} % 2 == 0 )) || return 1
    output=()
    for ((index=0; index<${#fields[@]}; index+=2)); do
        key="${fields[$index]}"
        value="${fields[$((index + 1))]}"
        output["${key}"]="${value}"
    done
}

validate_early_shared_iommu_temp_inventory() {
    local authority=0 source=absent base_hash=absent expected_hash=absent
    local source_parent_dev=0 source_parent_ino=0 actual_base actual_expected
    local state_format backend generator target key legacy_key
    local pending_target=absent pending_stage=absent
    local pending_stage_new=absent boot_target_hash=absent boot_generator_attempted=0
    local boot_parent_dev=0 boot_parent_ino=0
    local pending_seen=0 restoring_format5_seen=0
    local -A state_data=() pending_data=()

    if [[ -e "${IOMMU_REMOVE_PENDING}" || -L "${IOMMU_REMOVE_PENDING}" ]]; then
        [[ -e "${IOMMU_REMOVE_PENDING}" && ! -L "${IOMMU_REMOVE_PENDING}" ]] && \
            read_kv_state "${IOMMU_REMOVE_PENDING}" \
                "format,phase,legacy_grub_backup_sha256,legacy_grub_pending_sha256,legacy_cmdline_backup_sha256,legacy_cmdline_pending_sha256,boot_target,boot_target_sha256,boot_candidate_sha256,boot_stage,boot_stage_new,boot_generator_attempted,boot_parent_dev,boot_parent_ino,source_parent_dev,source_parent_ino" \
                pending_data || die "Unsafe early IOMMU removal marker"
        pending_seen=1
        if [[ "${pending_data[format]:-}" == "5" && \
              "${pending_data[phase]:-}" == "restoring" ]]; then
            restoring_format5_seen=1
        fi
    fi

    if [[ -e "${IOMMU_STATE}" && ! -L "${IOMMU_STATE}" && \
          "${pending_seen}" == "1" ]] && \
       read_kv_state "${IOMMU_STATE}" \
           "format,backend,source,base_sha256,expected_sha256,generator,target,key,legacy_grub_backup_sha256,legacy_grub_pending_sha256,legacy_cmdline_backup_sha256,legacy_cmdline_pending_sha256" \
           state_data; then
        authority=1
        state_format="${state_data[format]:-}"
        source="${state_data[source]:-}"
        base_hash="${state_data[base_sha256]:-}"
        expected_hash="${state_data[expected_sha256]:-}"
        backend="${state_data[backend]:-}"
        generator="${state_data[generator]:-}"
        target="${state_data[target]:-}"
        key="${state_data[key]:-}"
        case "${state_format}" in
            1)
                (( ${#state_data[@]} == 8 )) || authority=0
                ;;
            2)
                (( ${#state_data[@]} == 12 )) || authority=0
                for legacy_key in legacy_grub_backup_sha256 legacy_grub_pending_sha256 \
                                  legacy_cmdline_backup_sha256 legacy_cmdline_pending_sha256; do
                    [[ "${state_data[${legacy_key}]:-}" == "absent" || \
                       "${state_data[${legacy_key}]:-}" =~ ^[a-f0-9]{64}$ ]] || authority=0
                done
                ;;
            *) authority=0 ;;
        esac
        [[ "${source}" == "/etc/default/grub" || \
           "${source}" == "/etc/kernel/cmdline" ]] || authority=0
        [[ "${base_hash}" =~ ^[a-f0-9]{64}$ && \
           "${expected_hash}" =~ ^[a-f0-9]{64}$ ]] || authority=0
        case "${backend}|${source}|${generator}|${target}|${key}" in
            "grub|/etc/default/grub|update-grub|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
            "grub|/etc/default/grub|update-grub|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX"|\
            "grub|/etc/default/grub|grub2-mkconfig|/boot/grub2/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
            "grub|/etc/default/grub|grub2-mkconfig|/boot/grub2/grub.cfg|GRUB_CMDLINE_LINUX"|\
            "grub|/etc/default/grub|grub2-mkconfig|/boot/efi/EFI/"*"/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
            "grub|/etc/default/grub|grub2-mkconfig|/boot/efi/EFI/"*"/grub.cfg|GRUB_CMDLINE_LINUX"|\
            "grub|/etc/default/grub|grub-mkconfig|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
            "grub|/etc/default/grub|grub-mkconfig|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX"|\
            "kernel-cmdline|/etc/kernel/cmdline|kernel-install|/boot/loader/entries|-" ) ;;
            *) authority=0 ;;
        esac
        if [[ "${target}" == /boot/efi/EFI/* ]]; then
            [[ "${target}" =~ ^/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg$ ]] || authority=0
        fi
        if (( authority == 1 )); then
            actual_base="$(sha256_regular "${IOMMU_BASE}")" || authority=0
            actual_expected="$(sha256_regular "${IOMMU_EXPECTED}")" || authority=0
            [[ "${actual_base:-}" == "${base_hash}" && \
               "${actual_expected:-}" == "${expected_hash}" ]] || authority=0
        fi

        (( ${#pending_data[@]} == 16 )) || authority=0
        [[ "${pending_data[format]:-}" == "5" && \
           "${pending_data[phase]:-}" == "restoring" && \
           "${pending_data[boot_target_sha256]:-}" =~ ^[a-f0-9]{64}$ && \
           "${pending_data[boot_candidate_sha256]:-}" == "absent" && \
           "${pending_data[boot_generator_attempted]:-}" =~ ^[01]$ && \
           "${pending_data[boot_parent_dev]:-}" =~ ^[1-9][0-9]*$ && \
           "${pending_data[boot_parent_ino]:-}" =~ ^[1-9][0-9]*$ && \
           "${pending_data[source_parent_dev]:-}" =~ ^[1-9][0-9]*$ && \
           "${pending_data[source_parent_ino]:-}" =~ ^[1-9][0-9]*$ ]] || authority=0
        for legacy_key in legacy_grub_backup_sha256 legacy_grub_pending_sha256 \
                          legacy_cmdline_backup_sha256 legacy_cmdline_pending_sha256; do
            if [[ "${state_format}" == "1" ]]; then
                [[ "${pending_data[${legacy_key}]:-}" == "absent" ]] || authority=0
            else
                [[ "${pending_data[${legacy_key}]:-}" == "${state_data[${legacy_key}]:-}" ]] || authority=0
            fi
        done
        pending_target="${pending_data[boot_target]:-}"
        pending_stage="${pending_data[boot_stage]:-}"
        pending_stage_new="${pending_data[boot_stage_new]:-}"
        boot_target_hash="${pending_data[boot_target_sha256]:-}"
        boot_generator_attempted="${pending_data[boot_generator_attempted]:-0}"
        boot_parent_dev="${pending_data[boot_parent_dev]:-0}"
        boot_parent_ino="${pending_data[boot_parent_ino]:-0}"
        case "${pending_target}" in
            /boot/grub/grub.cfg|/boot/grub2/grub.cfg) ;;
            /boot/efi/EFI/*/grub.cfg)
                [[ "${pending_target}" =~ ^/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg$ ]] || authority=0
                ;;
            *) authority=0 ;;
        esac
        [[ "${pending_target}" == "${target}" && \
           "${pending_stage}" == "$(dirname -- "${pending_target}")/.cmpunlocker-remove.$(basename -- "${pending_target}").boot."* && \
           "${pending_stage}" =~ ^/boot/[A-Za-z0-9._+/-]+/\.cmpunlocker-remove\.grub\.cfg\.boot\.[a-f0-9]{6}$ && \
           "${pending_stage_new}" == "${pending_stage}.new" ]] || authority=0
        source_parent_dev="${pending_data[source_parent_dev]:-0}"
        source_parent_ino="${pending_data[source_parent_ino]:-0}"
    fi
    if (( restoring_format5_seen == 1 && authority == 0 )); then
        die "Format-5 restoring IOMMU marker lacks exact early namespace authority"
    fi

    python3 - "${authority}" "${source}" "${base_hash}" "${expected_hash}" \
        "${source_parent_dev}" "${source_parent_ino}" "${pending_target}" \
        "${pending_stage}" "${pending_stage_new}" "${boot_target_hash}" \
        "${boot_generator_attempted}" "${boot_parent_dev}" "${boot_parent_ino}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

(allow_raw, source_raw, base_hash, expected_hash, parent_dev_raw, parent_ino_raw,
 boot_target_raw, boot_stage_raw, boot_stage_new_raw, boot_hash,
 boot_attempted_raw, boot_parent_dev_raw, boot_parent_ino_raw) = sys.argv[1:]
if allow_raw not in ("0", "1"):
    raise SystemExit("invalid early IOMMU temp authority")
allow = allow_raw == "1"
source = pathlib.Path(source_raw) if allow else None
if allow:
    if (source not in (pathlib.Path("/etc/default/grub"), pathlib.Path("/etc/kernel/cmdline"))
            or re.fullmatch(r"[a-f0-9]{64}", base_hash) is None
            or re.fullmatch(r"[a-f0-9]{64}", expected_hash) is None):
        raise SystemExit("invalid receipt-bound shared IOMMU temp authority")
    parent_authority = (int(parent_dev_raw), int(parent_ino_raw))
    if min(parent_authority) <= 0:
        raise SystemExit("invalid IOMMU source-parent authority")
    reserved = f".cmpunlocker-remove.{source.name}.tmp.{base_hash}"
    boot_target = pathlib.Path(boot_target_raw)
    boot_stage = pathlib.Path(boot_stage_raw)
    boot_stage_new = pathlib.Path(boot_stage_new_raw)
    boot_parent_authority = (int(boot_parent_dev_raw), int(boot_parent_ino_raw))
    if (boot_target not in (pathlib.Path("/boot/grub/grub.cfg"),
                            pathlib.Path("/boot/grub2/grub.cfg"))
            and re.fullmatch(r"/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg",
                             os.fspath(boot_target)) is None):
        raise SystemExit("invalid receipt-bound boot target")
    if (boot_stage.parent != boot_target.parent
            or boot_stage_new != pathlib.Path(os.fspath(boot_stage) + ".new")
            or re.fullmatch(rf"\.cmpunlocker-remove\.{re.escape(boot_target.name)}\.boot\.[a-f0-9]{{6}}",
                            boot_stage.name) is None
            or re.fullmatch(r"[a-f0-9]{64}", boot_hash) is None
            or boot_attempted_raw not in ("0", "1")
            or min(boot_parent_authority) <= 0):
        raise SystemExit("invalid receipt-bound boot namespace authority")
    boot_attempted = boot_attempted_raw == "1"
else:
    parent_authority = None
    reserved = None
    boot_target = boot_stage = boot_stage_new = None
    boot_parent_authority = None
    boot_attempted = False

def mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3 or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567" for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

mounted = mounts()
flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
         | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
fds = []

def digest_fd(fd):
    value = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        value.update(block)
    return value.hexdigest()

def read_xattrs(fd):
    return tuple((name, os.getxattr(fd, name))
                 for name in sorted(os.listxattr(fd)))

def exact_stat(current, expected):
    return (stat.S_IFMT(current.st_mode) == stat.S_IFMT(expected.st_mode)
            and (current.st_dev, current.st_ino) ==
               (expected.st_dev, expected.st_ino)
            and current.st_uid == expected.st_uid
            and current.st_gid == expected.st_gid
            and current.st_nlink == expected.st_nlink
            and stat.S_IMODE(current.st_mode) == stat.S_IMODE(expected.st_mode)
            and current.st_size == expected.st_size
            and current.st_mtime_ns == expected.st_mtime_ns
            and current.st_ctime_ns == expected.st_ctime_ns)

def mount_aliases(path):
    return {os.path.normpath(os.fspath(path)),
            os.path.normpath(os.path.realpath(path))}

leaf_proofs = []

def open_leaf(dfd, parent_st, path, require_nonempty=False):
    if mount_aliases(path) & mounted:
        raise SystemExit(f"mount blocks early IOMMU namespace proof: {path}")
    lst = os.stat(path.name, dir_fd=dfd, follow_symlinks=False)
    fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    fds.append(fd)
    opened = os.fstat(fd)
    if ((opened.st_dev, opened.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISREG(opened.st_mode) or opened.st_uid != 0
            or opened.st_gid != 0 or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) & 0o022
            or opened.st_dev != parent_st.st_dev
            or (require_nonempty and opened.st_size <= 0)):
        raise SystemExit(f"unsafe early IOMMU namespace leaf: {path}")
    proof = (dfd, path.name, fd, opened, digest_fd(fd), read_xattrs(fd))
    leaf_proofs.append(proof)
    return proof

root_fd = os.open("/", flags); fds.append(root_fd)
root_st = os.fstat(root_fd)
etc_lst = os.stat("etc", dir_fd=root_fd, follow_symlinks=False)
etc_fd = os.open("etc", flags, dir_fd=root_fd); fds.append(etc_fd)
etc_st = os.fstat(etc_fd)
for observed in (root_st, etc_lst, etc_st):
    if (not stat.S_ISDIR(observed.st_mode) or observed.st_uid != 0 or observed.st_gid != 0
            or stat.S_IMODE(observed.st_mode) & 0o022):
        raise SystemExit("unsafe literal IOMMU shared-temp ancestry")
if (etc_lst.st_dev, etc_lst.st_ino) != (etc_st.st_dev, etc_st.st_ino):
    raise SystemExit("literal /etc changed while opening")

parents = {}
initial_inventory = {}
try:
    for component in ("default", "kernel"):
        path = pathlib.Path("/etc") / component
        normalized = os.path.normpath(os.fspath(path))
        if normalized in mounted or os.path.normpath(os.path.realpath(path)) in mounted:
            raise SystemExit(f"mount redirects shared IOMMU temp parent: {path}")
        try:
            lst = os.stat(component, dir_fd=etc_fd, follow_symlinks=False)
        except FileNotFoundError:
            parents[component] = None
            initial_inventory[component] = ()
            continue
        fd = os.open(component, flags, dir_fd=etc_fd); fds.append(fd)
        opened = os.fstat(fd)
        if ((opened.st_dev, opened.st_ino) != (lst.st_dev, lst.st_ino)
                or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != 0
                or opened.st_gid != 0 or stat.S_IMODE(opened.st_mode) & 0o022
                or opened.st_dev != etc_st.st_dev):
            raise SystemExit(f"unsafe literal shared IOMMU temp parent: {path}")
        parents[component] = (fd, opened)
        initial_inventory[component] = tuple(sorted(
            entry.name for entry in os.scandir(fd)
            if entry.name.startswith(".cmpunlocker-remove.")
            or entry.name.startswith(".cmpunlocker-install.")))

    candidates = []
    for component, inventory in initial_inventory.items():
        for name in inventory:
            if name.startswith(".cmpunlocker-install."):
                raise SystemExit(f"install-side shared temp requires install recovery: /etc/{component}/{name}")
            candidates.append((component, name))
    if candidates and (not allow or len(candidates) != 1):
        raise SystemExit("shared IOMMU temp lacks unique format-5 restoring authority")

    boot_chain = []
    absent_boot_leaves = []
    if allow:
        parent = parents.get(source.parent.name)
        if parent is None or (parent[1].st_dev, parent[1].st_ino) != parent_authority:
            raise SystemExit("IOMMU source parent differs from its durable authority")
        source_dfd, source_parent_st = parent
        source_proof = open_leaf(source_dfd, source_parent_st, source)
        if source_proof[4] not in (base_hash, expected_hash):
            raise SystemExit("receipt-bound IOMMU source changed")

        if candidates:
            component, name = candidates[0]
            if component != source.parent.name or name != reserved:
                raise SystemExit("shared IOMMU temp is not the receipt-reserved pathname")
            temp_path = source.parent / name
            open_leaf(source_dfd, source_parent_st, temp_path)

        current_fd = root_fd
        ancestor_path = pathlib.Path("/")
        allowed_boot_mounts = {"/", "/boot", "/boot/efi"}
        for component in boot_target.parent.parts[1:]:
            ancestor_path /= component
            normalized = os.path.normpath(os.fspath(ancestor_path))
            if normalized in mounted and normalized not in allowed_boot_mounts:
                raise SystemExit(f"mount redirects boot output ancestor: {ancestor_path}")
            lst = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
            child_fd = os.open(component, flags, dir_fd=current_fd)
            fds.append(child_fd)
            opened = os.fstat(child_fd)
            if ((opened.st_dev, opened.st_ino) != (lst.st_dev, lst.st_ino)
                    or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != 0
                    or opened.st_gid != 0 or stat.S_IMODE(opened.st_mode) & 0o022):
                raise SystemExit(f"unsafe retained boot ancestor: {ancestor_path}")
            boot_chain.append((current_fd, component, child_fd, opened))
            current_fd = child_fd
        boot_dfd = current_fd
        boot_parent_st = os.fstat(boot_dfd)
        if (boot_parent_st.st_dev, boot_parent_st.st_ino) != boot_parent_authority:
            raise SystemExit("boot parent differs from its durable authority")
        target_proof = open_leaf(boot_dfd, boot_parent_st, boot_target, True)
        if target_proof[4] != boot_hash:
            raise SystemExit("boot target differs from its durable authority")
        for path in (boot_stage, boot_stage_new):
            try:
                os.stat(path.name, dir_fd=boot_dfd, follow_symlinks=False)
            except FileNotFoundError:
                absent_boot_leaves.append((boot_dfd, path.name))
                continue
            if not boot_attempted:
                raise SystemExit(f"unattempted boot generator artifact exists: {path}")
            open_leaf(boot_dfd, boot_parent_st, path)
    current_etc = os.stat("etc", dir_fd=root_fd, follow_symlinks=False)
    held_etc = os.fstat(etc_fd)
    if (not exact_stat(current_etc, etc_st) or not exact_stat(held_etc, etc_st)
            or mounted != mounts()):
        raise SystemExit("IOMMU shared-temp ancestry or mounts changed")
    for component, retained in parents.items():
        if retained is None:
            try:
                os.stat(component, dir_fd=etc_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise SystemExit("shared IOMMU temp parent appeared during inspection")
        fd, opened = retained
        current = os.stat(component, dir_fd=etc_fd, follow_symlinks=False)
        held = os.fstat(fd)
        inventory = tuple(sorted(entry.name for entry in os.scandir(fd)
            if entry.name.startswith(".cmpunlocker-remove.")
            or entry.name.startswith(".cmpunlocker-install.")))
        if (not exact_stat(current, opened) or not exact_stat(held, opened)
                or inventory != initial_inventory[component]):
            raise SystemExit("shared IOMMU temp namespace changed during inspection")
    for parent_fd, name, child_fd, opened in boot_chain:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        held = os.fstat(child_fd)
        if (not exact_stat(current, opened) or not exact_stat(held, opened)):
            raise SystemExit("retained boot namespace changed during early inspection")
    for parent_fd, name, fd, opened, expected_digest, expected_xattrs in leaf_proofs:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        held = os.fstat(fd)
        if (not exact_stat(current, opened) or not exact_stat(held, opened)
                or digest_fd(fd) != expected_digest
                or read_xattrs(fd) != expected_xattrs):
            raise SystemExit("IOMMU namespace leaf changed during early inspection")
    for parent_fd, name in absent_boot_leaves:
        try:
            os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        raise SystemExit("boot namespace leaf appeared during early inspection")
    if mounted != mounts():
        raise SystemExit("IOMMU mount namespace changed after retained inspection")
finally:
    for fd in reversed(fds):
        os.close(fd)
PY
}

sha256_regular() {
    validate_root_file "$1" 0 || return 1
    sha256sum -- "$1" | awk '{print $1}'
}

command -v python3 &>/dev/null || die "Required command not found: python3"
prepare_state_dir
python3 - "${LIFECYCLE_LOCK}" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
if os.geteuid() != 0:
    raise SystemExit("lifecycle lock requires EUID 0")
os.setegid(0)
flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
created = False
try:
    fd = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    created = True
except FileExistsError:
    fd = os.open(path, flags)
try:
    st = os.fstat(fd)
    if (not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1):
        raise SystemExit(f"unsafe lifecycle lock: {path}")
    if created:
        os.fsync(fd)
finally:
    os.close(fd)
if created:
    dfd = os.open(os.path.dirname(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
PY
validate_root_file "${LIFECYCLE_LOCK}" 1 || die "Unsafe lifecycle lock ${LIFECYCLE_LOCK}"
exec {LIFECYCLE_LOCK_FD}<>"${LIFECYCLE_LOCK}"
[[ -f "${LIFECYCLE_LOCK}" && ! -L "${LIFECYCLE_LOCK}" && \
   "$(stat -c '%a:%u:%g' -- "${LIFECYCLE_LOCK}")" == "600:0:0" && \
   "$(stat -c %h -- "${LIFECYCLE_LOCK}")" == "1" && \
   "$(stat -c '%d:%i' -- "${LIFECYCLE_LOCK}")" == \
   "$(stat -Lc '%d:%i' -- "/proc/self/fd/${LIFECYCLE_LOCK_FD}")" ]] || \
    die "Lifecycle lock changed during acquisition"
flock -n "${LIFECYCLE_LOCK_FD}" || die "Another cmpunlocker lifecycle operation is active"

for required_cmd in awk chmod chown cmp cp depmod env find flock grep head install mktemp \
                    modinfo mv readlink sed sha256sum sort stat sync timeout tr; do
    command -v "${required_cmd}" &>/dev/null || die "Required command not found: ${required_cmd}"
done
validate_early_shared_iommu_temp_inventory
cleanup_known_atomic_temps
validate_state_namespace_names
ok "Durable state directory and required tools are available"

INITRAMFS_TOOL=""
INITRAMFS_IMAGE=""
INITRAMFS_CONFIG=""

select_mkinitcpio_target() {
    local kernel="$1"
    local pkgbase_file="/lib/modules/${kernel}/pkgbase"
    local module_kernel="/lib/modules/${kernel}/vmlinuz"
    local preset_name preset
    local values=()

    validate_root_file "${pkgbase_file}" 0 && \
        validate_root_file "${module_kernel}" 0 || return 1
    preset_name="$(tr -d '[:space:]' < "${pkgbase_file}")"
    [[ "${preset_name}" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    preset="/etc/mkinitcpio.d/${preset_name}.preset"
    mapfile -t values < <(python3 - "${preset}" "${kernel}" "${module_kernel}" <<'PY'
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
if (not stat.S_ISREG(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != 0 or pst.st_gid != 0):
    raise SystemExit("unsafe mkinitcpio preset")
encoded_assignments = {}
assignments = {}
active_keys = {
    "default_uki", "default_efi_image", "default_options", "ALL_options",
    "default_cmdline", "ALL_cmdline",
    "default_splash", "ALL_splash",
    "default_kerneldest", "ALL_kerneldest",
    "default_kver", "ALL_kver",
    "default_image", "default_config", "ALL_config",
}
presets = None
for number, raw in enumerate(preset.read_text(encoding="utf-8").splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    array = re.fullmatch(r"PRESETS=\((.*)\)", line)
    if array:
        if presets is not None:
            raise SystemExit("duplicate PRESETS assignment")
        presets = shlex.split(array.group(1), posix=True)
        if not presets or any(not re.fullmatch(r"[A-Za-z0-9._+-]+", x) for x in presets):
            raise SystemExit("unsafe PRESETS assignment")
        continue
    scalar = re.fullmatch(r"([A-Za-z0-9_]+)=(.*)", line)
    if not scalar:
        raise SystemExit(f"unsupported executable preset syntax on line {number}")
    key, encoded = scalar.groups()
    if key not in active_keys:
        continue
    if key in encoded_assignments:
        raise SystemExit(f"duplicate preset assignment: {key}")
    encoded_assignments[key] = (encoded, number)
if presets != ["default"]:
    raise SystemExit("mkinitcpio preset must select exactly one default image")

def value(key):
    if key in assignments:
        return assignments[key]
    if key not in encoded_assignments:
        return ""
    encoded, number = encoded_assignments[key]
    if any(token in encoded for token in ("$", "`", ";", "(", ")")):
        raise SystemExit(f"dynamic preset value on line {number}")
    parsed = shlex.split(encoded, posix=True)
    if not parsed and not encoded.strip():
        assignments[key] = ""
        return ""
    if len(parsed) != 1:
        raise SystemExit(f"ambiguous preset value on line {number}")
    assignments[key] = parsed[0]
    return parsed[0]

if value("default_uki") or value("default_efi_image"):
    raise SystemExit("default preset UKI output is unsupported")
if value("default_options") or value("ALL_options"):
    raise SystemExit("preset options could override the exact kernel")
for field in ("cmdline", "splash", "kerneldest"):
    effective = value(f"default_{field}") or value(f"ALL_{field}")
    if effective:
        raise SystemExit(f"mkinitcpio effective {field} is not reproduced safely")
kernel_spec = value("default_kver") or value("ALL_kver")
if kernel_spec and kernel_spec != kver:
    kernel_path = pathlib.Path(kernel_spec)
    if not kernel_path.is_absolute():
        raise SystemExit("preset kver is neither exact release nor absolute image")
    for candidate in (kernel_path, module_kernel):
        cst = os.lstat(candidate)
        if (not stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode)
                or cst.st_uid != 0 or cst.st_gid != 0):
            raise SystemExit(f"unsafe kernel image {candidate}")
    def digest(path):
        value = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
        return value.digest()
    if digest(kernel_path) != digest(module_kernel):
        raise SystemExit("preset kernel image does not match target KVER")
image = value("default_image")
# Match mkinitcpio v41 preset selection: a non-empty image-specific config
# wins, otherwise a non-empty ALL_config is the effective fallback.
config = value("default_config") or value("ALL_config")
image_path = pathlib.Path(image)
if not image or not image_path.is_absolute():
    raise SystemExit("mkinitcpio image is not absolute")
if config:
    config_path = pathlib.Path(config)
    if not config_path.is_absolute():
        raise SystemExit("mkinitcpio config is not absolute")
    cst = os.lstat(config_path)
    if (not stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode)
            or cst.st_uid != 0 or cst.st_gid != 0):
        raise SystemExit("unsafe mkinitcpio config")
dst = os.lstat(image_path.parent)
if (not stat.S_ISDIR(dst.st_mode) or stat.S_ISLNK(dst.st_mode)
        or dst.st_uid != 0 or dst.st_gid != 0):
    raise SystemExit("unsafe mkinitcpio output parent")
try:
    ist = os.lstat(image_path)
except FileNotFoundError:
    pass
else:
    if (not stat.S_ISREG(ist.st_mode) or stat.S_ISLNK(ist.st_mode)
            or ist.st_uid != 0 or ist.st_gid != 0):
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
    else
        return 1
    fi
}

rebuild_kernel_initramfs() {
    local kernel="$1"
    local -a mkinitcpio_args=()

    case "${INITRAMFS_TOOL}" in
        update-initramfs)
            info "Rebuilding initramfs for ${kernel} (update-initramfs)..."
            update-initramfs -u -k "${kernel}"
            ;;
        dracut)
            info "Rebuilding initramfs for ${kernel} (dracut)..."
            dracut --force --kver "${kernel}"
            ;;
        mkinitcpio)
            select_mkinitcpio_target "${kernel}" || return 1
            info "Rebuilding ${INITRAMFS_IMAGE} explicitly for ${kernel} (mkinitcpio)..."
            mkinitcpio_args=(-k "${kernel}" -g "${INITRAMFS_IMAGE}")
            if [[ "${INITRAMFS_CONFIG}" != "absent" ]]; then
                mkinitcpio_args+=(-c "${INITRAMFS_CONFIG}")
            fi
            mkinitcpio "${mkinitcpio_args[@]}" || return 1
            [[ -s "${INITRAMFS_IMAGE}" && ! -L "${INITRAMFS_IMAGE}" ]] || return 1
            sync -f "${INITRAMFS_IMAGE}" || return 1
            sync -f "$(dirname -- "${INITRAMFS_IMAGE}")" || return 1
            ;;
        *) return 1 ;;
    esac
}

declare -a LOCK_FDS=()
declare -A LOCKED_KERNELS=()

valid_kernel_lock_object() {
    local path="$1" base kernel
    base="${path##*/}"
    [[ "${base}" == *.lock ]] || return 1
    kernel="${base%.lock}"
    valid_kernel "${kernel}" || return 1
    [[ "${base}" == "${kernel}.lock" && -f "${path}" && ! -L "${path}" ]] || return 1
    [[ "$(stat -c '%a:%u:%g' -- "${path}" 2>/dev/null)" == "600:0:0" ]]
}

prepare_transaction_root() {
    local owner group mode root_dev modules_dev object

    [[ ! -L "${TX_ROOT}" ]] || die "Refusing symlink transaction root ${TX_ROOT}"
    if [[ ! -e "${TX_ROOT}" ]]; then
        create_private_root_dir_if_absent "${TX_ROOT}" || \
            die "Could not safely create ${TX_ROOT}"
    fi
    [[ -d "${TX_ROOT}" && ! -L "${TX_ROOT}" ]] || die "Unsafe ${TX_ROOT}"
    owner="$(stat -c %u -- "${TX_ROOT}")"
    group="$(stat -c %g -- "${TX_ROOT}")"
    mode="$(stat -c %a -- "${TX_ROOT}")"
    [[ "${owner}" == "0" && "${group}" == "0" && "${mode}" == "700" ]] || \
        die "${TX_ROOT} must be root:root mode 0700"
    root_dev="$(stat -c %d -- "${TX_ROOT}")"
    modules_dev="$(stat -c %d -- /lib/modules)"
    [[ "${root_dev}" == "${modules_dev}" ]] || \
        die "Module transaction root is not on the /lib/modules filesystem"
    while IFS= read -r -d '' object; do
        valid_kernel_lock_object "${object}" || \
            die "Unrecovered or unsafe build transaction object exists: ${object}"
    done < <(find -P "${TX_ROOT}" -mindepth 1 -maxdepth 1 -print0)
}

prepare_kernel_lock_file() {
    local lock_path="$1"
    python3 - "${lock_path}" "${TX_ROOT}" <<'PY'
import os
import stat
import sys

path = os.fsencode(sys.argv[1])
root = os.fsencode(sys.argv[2])
if os.geteuid() != 0:
    raise SystemExit("transaction lock requires EUID 0")
os.setegid(0)
rst = os.lstat(root)
if (not stat.S_ISDIR(rst.st_mode) or stat.S_ISLNK(rst.st_mode)
        or rst.st_uid != 0 or rst.st_gid != 0
        or stat.S_IMODE(rst.st_mode) != 0o700):
    raise SystemExit("unsafe transaction lock namespace")
flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
created = False
try:
    fd = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    created = True
except FileExistsError:
    lst = os.lstat(path)
    if (not stat.S_ISREG(lst.st_mode) or stat.S_ISLNK(lst.st_mode)
            or lst.st_uid != 0 or lst.st_gid != 0
            or stat.S_IMODE(lst.st_mode) != 0o600 or lst.st_nlink != 1):
        raise SystemExit("unsafe preexisting transaction lock object")
    fd = os.open(path, flags)
try:
    fst = os.fstat(fd)
    if (not stat.S_ISREG(fst.st_mode) or fst.st_uid != 0 or fst.st_gid != 0
            or stat.S_IMODE(fst.st_mode) != 0o600 or fst.st_nlink != 1):
        raise SystemExit("unsafe transaction lock object")
    if created:
        os.fsync(fd)
finally:
    os.close(fd)
if created:
    dfd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
PY
}

lock_kernel() {
    local kernel="$1"
    local lock_path fd

    [[ -z "${LOCKED_KERNELS[${kernel}]+x}" ]] || return 0
    prepare_transaction_root
    lock_path="${TX_ROOT}/${kernel}.lock"
    prepare_kernel_lock_file "${lock_path}" || die "Unsafe lock object ${lock_path}"
    exec {fd}<>"${lock_path}"
    [[ -f "${lock_path}" && ! -L "${lock_path}" && \
       "$(stat -c '%a:%u:%g' -- "${lock_path}")" == "600:0:0" && \
       "$(stat -c %h -- "${lock_path}")" == "1" && \
       "$(stat -c '%d:%i' -- "${lock_path}")" == \
       "$(stat -Lc '%d:%i' -- "/proc/self/fd/${fd}")" ]] || \
        die "Kernel lock changed during acquisition: ${lock_path}"
    flock -n "${fd}" || die "Another cmpunlocker transaction is active for ${kernel}"
    LOCK_FDS+=("${fd}")
    LOCKED_KERNELS["${kernel}"]=1
}

prelock_all_kernels() {
    local path base payload kernel nonce
    local -A candidates=()
    local sorted=()

    prepare_transaction_root
    for path in /lib/modules/*/updates/cmpunlocker; do
        kernel="$(basename "$(dirname "$(dirname "${path}")")")"
        valid_kernel "${kernel}" || die "Unsafe kernel path ${path}"
        candidates["${kernel}"]=1
    done
    for path in /lib/modules/*/updates/.cmpunlocker.stage.* \
                /lib/modules/*/updates/.cmpunlocker.backup.* \
                /lib/modules/*/updates/.cmpunlocker.failed.*; do
        kernel="$(basename "$(dirname "$(dirname "${path}")")")"
        valid_kernel "${kernel}" || die "Unsafe legacy module transaction path ${path}"
        candidates["${kernel}"]=1
    done
    for path in /lib/modules/*/updates/dkms/.cmpunlocker-forward.*; do
        kernel="${path#/lib/modules/}"
        kernel="${kernel%%/*}"
        valid_kernel "${kernel}" || die "Unsafe forward DKMS temporary path ${path}"
        candidates["${kernel}"]=1
    done
    for path in /lib/modules/.cmpunlocker.remove.*; do
        base="${path##*/}"
        payload="${base#.cmpunlocker.remove.}"
        kernel="${payload%.*}"
        nonce="${payload##*.}"
        valid_kernel "${kernel}" && [[ "${nonce}" =~ ^[A-Za-z0-9]{6}$ ]] || \
            die "Unsafe orphan transaction name ${path}"
        candidates["${kernel}"]=1
    done
    for path in "${STATE_DIR}"/remove.*.state; do
        base="${path##*/}"
        kernel="${base#remove.}"
        kernel="${kernel%.state}"
        valid_kernel "${kernel}" || die "Unsafe removal-state name ${path}"
        candidates["${kernel}"]=1
    done
    if (( ${#candidates[@]} > 0 )); then
        mapfile -t sorted < <(printf '%s\n' "${!candidates[@]}" | LC_ALL=C sort)
        for kernel in "${sorted[@]}"; do
            lock_kernel "${kernel}"
        done
    fi
    for path in /lib/modules/*/updates/.cmpunlocker.stage.* \
                /lib/modules/*/updates/.cmpunlocker.backup.* \
                /lib/modules/*/updates/.cmpunlocker.failed.*; do
        die "Legacy module transaction remains inside the depmod tree: ${path}; rerun install for quarantine recovery"
    done
    if [[ ! -e "${REMOVE_FORWARD}" && ! -L "${REMOVE_FORWARD}" ]]; then
        for path in /lib/modules/*/updates/dkms/.cmpunlocker-forward.*; do
            die "Unbound forward DKMS temporary exists without ${REMOVE_FORWARD}: ${path}"
        done
    fi
}

module_contains_cmp_marker() {
    local module="$1"
    local temp rc

    case "${module}" in
        *.gz)
            command -v gzip &>/dev/null || return 2
            temp="$(mktemp -t cmpunlocker-module.XXXXXX)" || return 2
            gzip -cd -- "${module}" > "${temp}" || { rm -f "${temp}"; return 2; }
            ;;
        *.xz)
            command -v xz &>/dev/null || return 2
            temp="$(mktemp -t cmpunlocker-module.XXXXXX)" || return 2
            xz -cd -- "${module}" > "${temp}" || { rm -f "${temp}"; return 2; }
            ;;
        *.zst)
            command -v zstdcat &>/dev/null || return 2
            temp="$(mktemp -t cmpunlocker-module.XXXXXX)" || return 2
            zstdcat -- "${module}" > "${temp}" || { rm -f "${temp}"; return 2; }
            ;;
        *) temp="${module}" ;;
    esac

    if grep -aEq 'cmpunlocker-safety-v3|CMP Gen2:' "${temp}"; then
        rc=0
    else
        rc=$?
    fi
    [[ "${temp}" == "${module}" ]] || rm -f -- "${temp}"
    (( rc == 0 )) && return 0
    (( rc == 1 )) && return 1
    return 2
}

module_payload_sha256() {
    local module="$1" temp hash

    case "${module}" in
        *.gz)
            command -v gzip &>/dev/null || return 1
            temp="$(mktemp -t cmpunlocker-module-hash.XXXXXX)" || return 1
            gzip -cd -- "${module}" > "${temp}" || { rm -f -- "${temp}"; return 1; }
            ;;
        *.xz)
            command -v xz &>/dev/null || return 1
            temp="$(mktemp -t cmpunlocker-module-hash.XXXXXX)" || return 1
            xz -cd -- "${module}" > "${temp}" || { rm -f -- "${temp}"; return 1; }
            ;;
        *.zst)
            command -v zstdcat &>/dev/null || return 1
            temp="$(mktemp -t cmpunlocker-module-hash.XXXXXX)" || return 1
            zstdcat -- "${module}" > "${temp}" || { rm -f -- "${temp}"; return 1; }
            ;;
        *) temp="${module}" ;;
    esac
    hash="$(sha256sum -- "${temp}" | awk '{print $1}')" || {
        [[ "${temp}" == "${module}" ]] || rm -f -- "${temp}"
        return 1
    }
    [[ "${temp}" == "${module}" ]] || rm -f -- "${temp}"
    [[ "${hash}" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "${hash}"
}

collect_physical_module_objects() {
    local directory="$1" output_name="$2"
    local -n output="${output_name}"

    output=()
    mapfile -d '' -t output < <(find -P "${directory}" -mindepth 1 \
        \( -type f -o -type l \) \
        \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
        -print0)
}

validate_stock_physical_directory() {
    local directory="$1" resolved_name="$2"
    local -n expected_paths="${resolved_name}"
    local objects=() object canonical i matched unsafe

    [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
    unsafe="$(find -P "${directory}" -mindepth 1 ! -type f -print -quit)" || return 1
    [[ -z "${unsafe}" ]] || return 1
    collect_physical_module_objects "${directory}" objects
    [[ ${#objects[@]} -eq ${#MODULE_FILES[@]} ]] || return 1
    for object in "${objects[@]}"; do
        [[ -f "${object}" && ! -L "${object}" ]] || return 1
        canonical="$(readlink -f -- "${object}")" || return 1
        matched=0
        for i in "${!expected_paths[@]}"; do
            [[ "${canonical}" == "${expected_paths[$i]}" ]] && matched=1
        done
        (( matched == 1 )) || return 1
    done
}

VALIDATED_DRIVER_VERSION=""
VALIDATED_CORE_SRC=""
VALIDATED_PATCHED_HASHES=""

cmp_module_namespace() {
    local action="$1" source="$2" kernel="$3" target="${4:-absent}"
    local expected_version="${5:-pending}" expected_hashes="${6:-pending}"

    [[ "${action}" == "validate" || "${action}" == "move" ]] || return 1
    valid_kernel "${kernel}" || return 1
    python3 - "${action}" "${source}" "${kernel}" "${target}" \
        "${expected_version}" "${expected_hashes}" \
        "${MODULE_FILES[@]}" <<'PY'
import ctypes
import errno
import hashlib
import os
import pathlib
import re
import stat
import sys

action = sys.argv[1]
source_arg = pathlib.Path(sys.argv[2])
kernel = sys.argv[3]
target_arg = pathlib.Path(sys.argv[4]) if sys.argv[4] != "absent" else None
expected_version = sys.argv[5]
expected_hashes_raw = sys.argv[6]
module_files = sys.argv[7:]
if (action not in ("validate", "move")
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", kernel) is None
        or module_files != ["nvidia.ko", "nvidia-modeset.ko", "nvidia-uvm.ko",
                            "nvidia-drm.ko", "nvidia-peermem.ko"]):
    raise SystemExit("invalid CMP namespace authority")
if (action == "move") != (target_arg is not None):
    raise SystemExit("invalid CMP namespace action")
if expected_hashes_raw == "pending":
    expected_hashes = None
elif re.fullmatch(r"(?:[a-f0-9]{64}:){4}[a-f0-9]{64}", expected_hashes_raw):
    expected_hashes = expected_hashes_raw.split(":")
else:
    raise SystemExit("invalid expected CMP hashes")
if expected_version != "pending" and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",
                                                   expected_version) is None:
    raise SystemExit("invalid expected CMP version")
if action == "move" and (expected_hashes is None or expected_version == "pending"):
    raise SystemExit("CMP move lacks exact retained-content authority")

root = pathlib.Path("/lib/modules").resolve(strict=True)
root_st = os.lstat(root)
if (not stat.S_ISDIR(root_st.st_mode) or stat.S_ISLNK(root_st.st_mode)
        or root_st.st_uid != 0 or root_st.st_gid != 0
        or stat.S_IMODE(root_st.st_mode) & 0o022):
    raise SystemExit("unsafe /lib/modules root")

live_parts = (kernel, "updates", "cmpunlocker")
backup_re = re.compile(rf"\.cmpunlocker\.remove\.{re.escape(kernel)}\.[A-Za-z0-9]{{6}}")

def classify(path, require_exists):
    if not path.is_absolute():
        raise SystemExit("CMP path is not absolute")
    logical = pathlib.Path(os.path.normpath(os.fspath(path)))
    try:
        resolved = logical.resolve(strict=require_exists)
    except FileNotFoundError:
        if require_exists:
            raise
        resolved = logical.parent.resolve(strict=True) / logical.name
    try:
        relative = resolved.relative_to(root)
    except ValueError:
        raise SystemExit("CMP path escapes /lib/modules")
    if relative.parts == live_parts:
        kind = "live"
    elif len(relative.parts) == 1 and backup_re.fullmatch(relative.name):
        kind = "backup"
    else:
        raise SystemExit(f"unrecognized CMP path: {logical}")
    # A symlink in the final component or an alternate lexical hierarchy must
    # never acquire move authority.  /lib itself may be the distro's canonical
    # usr-merge symlink, so compare against the resolved module root.
    expected = root.joinpath(*relative.parts)
    if resolved != expected:
        raise SystemExit("non-canonical CMP path")
    return logical, resolved, kind

source_logical, source, source_kind = classify(source_arg, True)
if target_arg is not None:
    target_logical, target, target_kind = classify(target_arg, False)
    if {source_kind, target_kind} != {"live", "backup"}:
        raise SystemExit("CMP move does not connect live and backup namespaces")
else:
    target_logical = target = target_kind = None

def trusted_dir(path):
    value = os.lstat(path)
    if (not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode)
            or value.st_uid != 0 or value.st_gid != 0
            or stat.S_IMODE(value.st_mode) & 0o022
            or value.st_dev != root_st.st_dev):
        raise SystemExit(f"unsafe CMP directory ancestry: {path}")
    return value

trusted_dir(root)
relative = source.relative_to(root)
cursor = root
for part in relative.parts:
    cursor = cursor / part
    trusted_dir(cursor)
if target is not None:
    target_relative = target.relative_to(root)
    cursor = root
    for part in target_relative.parts[:-1]:
        cursor = cursor / part
        trusted_dir(cursor)
    target_parent_lstat = os.lstat(target.parent)
else:
    target_parent_lstat = None

expected_names = {"driver_version", *module_files}

def validate_open_dir(dfd, expected_identity=None):
    dst = os.fstat(dfd)
    if (not stat.S_ISDIR(dst.st_mode) or dst.st_uid != 0 or dst.st_gid != 0
            or stat.S_IMODE(dst.st_mode) & 0o022 or dst.st_dev != root_st.st_dev):
        raise SystemExit("unsafe opened CMP directory")
    if (expected_identity is not None
            and (dst.st_dev, dst.st_ino) != expected_identity):
        raise SystemExit("CMP directory changed during descriptor acquisition")
    entries = list(os.scandir(dfd))
    names = {entry.name for entry in entries}
    if names != expected_names or len(entries) != len(expected_names):
        raise SystemExit("CMP directory is not the exact six-object namespace")
    for name in sorted(names):
        leaf = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if (not stat.S_ISREG(leaf.st_mode) or leaf.st_uid != 0 or leaf.st_gid != 0
                or leaf.st_nlink != 1 or stat.S_IMODE(leaf.st_mode) & 0o022
                or leaf.st_dev != root_st.st_dev):
            raise SystemExit(f"unsafe CMP leaf: {name}")
    if expected_version != "pending":
        version_fd = os.open("driver_version", os.O_RDONLY
                             | getattr(os, "O_CLOEXEC", 0)
                             | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
        try:
            version_st = os.fstat(version_fd)
            if version_st.st_size > 4096:
                raise SystemExit("oversized CMP driver version")
            raw = os.read(version_fd, 4097)
        finally:
            os.close(version_fd)
        try:
            recorded_version = raw.decode("ascii").strip()
        except UnicodeDecodeError:
            raise SystemExit("non-ASCII CMP driver version")
        if recorded_version != expected_version:
            raise SystemExit("CMP driver version changed before transition")
    if expected_hashes is not None:
        for name, expected_hash in zip(module_files, expected_hashes):
            leaf_fd = os.open(name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                              | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
            try:
                value = hashlib.sha256()
                while True:
                    block = os.read(leaf_fd, 1024 * 1024)
                    if not block:
                        break
                    value.update(block)
            finally:
                os.close(leaf_fd)
            if value.hexdigest() != expected_hash:
                raise SystemExit(f"CMP payload changed before transition: {name}")
    return dst

def decoded_mounts():
    mounts = []
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields = left.split(b" ")
            tail = right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not field for field in fields)
                    or any(not field for field in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded = fields[4]
            output = bytearray()
            index = 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    output.append(encoded[index])
                    index += 1
                    continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                output.append(int(encoded[index + 1:index + 4], 8))
                index += 4
            decoded = bytes(output)
            if not decoded or b"\x00" in decoded:
                raise SystemExit("empty or NUL mount point")
            mount = os.path.normpath(os.fsdecode(decoded))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            mounts.append(mount)
            mounts.append(os.path.normpath(os.path.realpath(mount)))
    return mounts

def reject_transition_mounts():
    source_aliases = {os.path.normpath(os.fspath(source_logical)),
                      os.path.normpath(os.fspath(source))}
    exact_aliases = set(source_aliases)
    for start in (source_logical, source, target_logical, target):
        if start is None:
            continue
        cursor = pathlib.Path(start)
        while cursor != cursor.parent:
            normalized = os.path.normpath(os.fspath(cursor))
            root_normalized = os.path.normpath(os.fspath(root))
            logical_root = os.path.normpath("/lib/modules")
            if normalized in (root_normalized, logical_root):
                break
            exact_aliases.add(normalized)
            cursor = cursor.parent
    for mount in decoded_mounts():
        if mount in exact_aliases:
            raise SystemExit(f"mount blocks CMP namespace transition: {mount}")
        for exact in source_aliases:
            if mount == exact or mount.startswith(exact + os.sep):
                raise SystemExit(f"mount blocks CMP namespace transition: {mount}")

source_lstat = os.lstat(source)
reject_transition_mounts()
source_parent_fd = os.open(source.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                           | getattr(os, "O_CLOEXEC", 0)
                           | getattr(os, "O_NOFOLLOW", 0))
source_fd = -1
target_parent_fd = -1
try:
    source_fd = os.open(source.name, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_CLOEXEC", 0)
                        | getattr(os, "O_NOFOLLOW", 0), dir_fd=source_parent_fd)
    opened = validate_open_dir(source_fd, (source_lstat.st_dev, source_lstat.st_ino))
    # A mount inserted after the first inspection cannot redirect descriptor
    # operations, but it must still stop the pathname rename itself.
    reject_transition_mounts()
    current = os.stat(source.name, dir_fd=source_parent_fd, follow_symlinks=False)
    if ((current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
            or not stat.S_ISDIR(current.st_mode)):
        raise SystemExit("CMP source pathname changed before transition")
    if action == "validate":
        raise SystemExit(0)

    target_parent_fd = os.open(target.parent,
                               os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                               | getattr(os, "O_CLOEXEC", 0)
                               | getattr(os, "O_NOFOLLOW", 0))
    target_parent_st = os.fstat(target_parent_fd)
    if (not stat.S_ISDIR(target_parent_st.st_mode)
            or target_parent_st.st_uid != 0 or target_parent_st.st_gid != 0
            or stat.S_IMODE(target_parent_st.st_mode) & 0o022
            or target_parent_st.st_dev != root_st.st_dev
            or target_parent_st.st_dev != opened.st_dev):
        raise SystemExit("unsafe or cross-device CMP target parent")
    if ((target_parent_st.st_dev, target_parent_st.st_ino) !=
            (target_parent_lstat.st_dev, target_parent_lstat.st_ino)):
        raise SystemExit("CMP target parent changed during descriptor acquisition")
    try:
        os.stat(target.name, dir_fd=target_parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise SystemExit("CMP target already exists")
    # Final pathname and mount rechecks immediately precede the syscall.
    reject_transition_mounts()
    target_parent_current = os.lstat(target.parent)
    if ((target_parent_current.st_dev, target_parent_current.st_ino) !=
            (target_parent_st.st_dev, target_parent_st.st_ino)):
        raise SystemExit("CMP target parent changed before renameat2")
    current = os.stat(source.name, dir_fd=source_parent_fd, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
        raise SystemExit("CMP source changed before renameat2")

    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise SystemExit("renameat2 is unavailable")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                          ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(source_parent_fd, os.fsencode(source.name), target_parent_fd,
                 os.fsencode(target.name), 1) != 0:
        error = ctypes.get_errno()
        if error == errno.EXDEV:
            raise SystemExit("cross-device CMP rename refused")
        if error == errno.EEXIST:
            raise SystemExit("CMP target appeared before rename")
        raise OSError(error, os.strerror(error), target)
    published = os.stat(target.name, dir_fd=target_parent_fd, follow_symlinks=False)
    if ((published.st_dev, published.st_ino) != (opened.st_dev, opened.st_ino)
            or not stat.S_ISDIR(published.st_mode)):
        raise SystemExit("CMP rename did not retain the validated directory identity")
    os.fsync(source_parent_fd)
    if target_parent_fd != source_parent_fd:
        os.fsync(target_parent_fd)
finally:
    if target_parent_fd >= 0:
        os.close(target_parent_fd)
    if source_fd >= 0:
        os.close(source_fd)
    os.close(source_parent_fd)
PY
}

rename_cmp_module_dir_noreplace() {
    cmp_module_namespace move "$1" "$3" "$2" "$4" "$5"
}

validate_cmp_module_dir() {
    local directory="$1"
    local kernel="$2"
    local version_file module_version module_name vermagic srcversion
    local i file payload_hash marker_rc unsafe
    local found=() hashes=()

    cmp_module_namespace validate "${directory}" "${kernel}" || return 1
    version_file="${directory}/driver_version"
    [[ -f "${version_file}" && ! -L "${version_file}" ]] || return 1
    VALIDATED_DRIVER_VERSION="$(tr -d '[:space:]' < "${version_file}")"
    valid_version "${VALIDATED_DRIVER_VERSION}" || return 1

    collect_physical_module_objects "${directory}" found
    [[ ${#found[@]} -eq ${#MODULE_FILES[@]} ]] || return 1
    VALIDATED_CORE_SRC=""
    VALIDATED_PATCHED_HASHES=""
    for i in "${!MODULE_FILES[@]}"; do
        file="${directory}/${MODULE_FILES[$i]}"
        [[ -f "${file}" && ! -L "${file}" ]] || return 1
        module_name="$(modinfo -F name -- "${file}" 2>/dev/null)" || return 1
        [[ "${module_name}" == "${MODULE_INTERNAL[$i]}" ]] || return 1
        module_version="$(modinfo -F version -- "${file}" 2>/dev/null)" || return 1
        [[ "${module_version}" == "${VALIDATED_DRIVER_VERSION}" ]] || return 1
        vermagic="$(modinfo -F vermagic -- "${file}" 2>/dev/null)" || return 1
        [[ "${vermagic}" == "${kernel}" || "${vermagic}" == "${kernel} "* ]] || return 1
        srcversion="$(modinfo -F srcversion -- "${file}" 2>/dev/null)" || return 1
        [[ "${srcversion}" =~ ^[A-Fa-f0-9]+$ ]] || return 1
        payload_hash="$(module_payload_sha256 "${file}")" || return 1
        hashes+=("${payload_hash}")
        if (( i == 0 )); then
            VALIDATED_CORE_SRC="${srcversion}"
            if module_contains_cmp_marker "${file}"; then
                :
            else
                marker_rc=$?
                (( marker_rc == 1 )) && err "Core lacks a cmpunlocker provenance marker: ${file}"
                return 1
            fi
        fi
    done
    VALIDATED_PATCHED_HASHES="$(IFS=:; printf '%s' "${hashes[*]}")"
}

verify_cmp_resolution() {
    local kernel="$1"
    local directory="$2"
    local i resolved canonical expected expected_canonical

    for i in "${!MODULE_QUERIES[@]}"; do
        resolved="$(modinfo -k "${kernel}" -n "${MODULE_QUERIES[$i]}" 2>/dev/null)" || return 1
        [[ -n "${resolved}" && -f "${resolved}" ]] || return 1
        canonical="$(readlink -f -- "${resolved}")" || return 1
        expected="${directory}/${MODULE_FILES[$i]}"
        expected_canonical="$(readlink -f -- "${expected}")" || return 1
        [[ "${canonical}" == "${expected_canonical}" ]] || return 1
    done
}

VERIFIED_STOCK_HASHES=""
verify_stock_module_set() {
    local kernel="$1"
    local expected_version="$2"
    local patched_core_src="$3"
    local patched_hashes="$4"
    local expected_stock_hashes="${5:-pending}"
    local stock_root firmware smi_output smi_version
    local i resolved canonical name version vermagic srcversion marker_rc set_dir="" payload_hash
    local resolved_set=() patched_hash_set=() stock_hash_set=() actual_stock_hashes=()

    VERIFIED_STOCK_HASHES=""

    IFS=: read -r -a patched_hash_set <<< "${patched_hashes}"
    [[ ${#patched_hash_set[@]} -eq ${#MODULE_FILES[@]} ]] || return 1
    if [[ "${expected_stock_hashes}" != "pending" ]]; then
        IFS=: read -r -a stock_hash_set <<< "${expected_stock_hashes}"
        [[ ${#stock_hash_set[@]} -eq ${#MODULE_FILES[@]} ]] || return 1
    fi

    stock_root="$(readlink -f -- "/lib/modules/${kernel}")" || return 1
    firmware="/lib/firmware/nvidia/${expected_version}/gsp_tu10x.bin"
    if [[ -n "${FIRMWARE_STOCK_HASH_BY_VERSION[${expected_version}]+x}" && \
          "${FIRMWARE_STOCK_HASH_BY_VERSION[${expected_version}]}" != "absent" ]]; then
        firmware_namespace_action "${expected_version}" inspect-recorded \
            "${FIRMWARE_STOCK_HASH_BY_VERSION[${expected_version}]}" \
            "${FIRMWARE_PATCHED_HASH_BY_VERSION[${expected_version}]}" none 1 || {
            err "Receipt-bound stock GSP firmware namespace changed: ${firmware}"
            return 1
        }
    elif ! firmware_namespace_action "${expected_version}" inspect; then
        err "Matching safe GSP firmware namespace is missing: ${firmware}"
        return 1
    fi
    if [[ "${FIRMWARE_NAMESPACE_PATCHED_HASH}" != "absent" && \
          "${FIRMWARE_NAMESPACE_MAIN_HASH}" == \
            "${FIRMWARE_NAMESPACE_PATCHED_HASH}" ]]; then
        err "Legacy patched firmware is still active at ${firmware}"
        return 1
    fi

    command -v nvidia-smi &>/dev/null || return 1
    smi_output="$(timeout --signal=TERM --kill-after=2s 10s nvidia-smi --version 2>/dev/null)" || return 1
    smi_version="$(sed -nE 's/^[[:space:]]*NVIDIA-SMI version[[:space:]]*:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' <<< "${smi_output}")"
    [[ "${smi_version}" == "${expected_version}" && "${smi_version}" != *$'\n'* ]] || {
        err "NVIDIA-SMI userspace ${smi_version:-missing} does not match ${expected_version}"
        return 1
    }

    for i in "${!MODULE_QUERIES[@]}"; do
        resolved="$(modinfo -k "${kernel}" -n "${MODULE_QUERIES[$i]}" 2>/dev/null)" || return 1
        [[ -n "${resolved}" && -f "${resolved}" ]] || return 1
        canonical="$(readlink -f -- "${resolved}")" || return 1
        [[ ! -L "${resolved}" ]] || return 1
        case "${canonical}" in
            "${stock_root}"/*) ;;
            *) err "Module escaped ${stock_root}: ${canonical}"; return 1 ;;
        esac
        case "${canonical}" in
            *cmpunlocker*|*.cmpunlocker.remove.*|"${TX_ROOT}"/*)
                err "Refusing transaction/patched path as stock: ${canonical}"
                return 1
                ;;
        esac
        name="$(modinfo -F name -- "${resolved}" 2>/dev/null)" || return 1
        [[ "${name}" == "${MODULE_INTERNAL[$i]}" ]] || return 1
        version="$(modinfo -F version -- "${resolved}" 2>/dev/null)" || return 1
        [[ "${version}" == "${expected_version}" ]] || return 1
        vermagic="$(modinfo -F vermagic -- "${resolved}" 2>/dev/null)" || return 1
        [[ "${vermagic}" == "${kernel}" || "${vermagic}" == "${kernel} "* ]] || return 1
        srcversion="$(modinfo -F srcversion -- "${resolved}" 2>/dev/null)" || return 1
        [[ "${srcversion}" =~ ^[A-Fa-f0-9]+$ ]] || return 1
        payload_hash="$(module_payload_sha256 "${resolved}")" || return 1
        actual_stock_hashes+=("${payload_hash}")
        if [[ "${expected_stock_hashes}" != "pending" ]]; then
            [[ "${payload_hash}" == "${stock_hash_set[$i]}" ]] || {
                err "Resolved ${MODULE_INTERNAL[$i]} changed from its recorded stock payload"
                return 1
            }
        fi
        resolved_set+=("${canonical}")
        if [[ -z "${set_dir}" ]]; then
            set_dir="$(dirname -- "${canonical}")"
        else
            [[ "$(dirname -- "${canonical}")" == "${set_dir}" ]] || return 1
        fi
        if (( i == 0 )); then
            [[ "${payload_hash}" != "${patched_hash_set[$i]}" ]] || {
                err "Resolved core is byte-identical to the held cmpunlocker core"
                return 1
            }
            [[ "${srcversion}" != "${patched_core_src}" ]] || {
                err "Resolved core has the cmpunlocker srcversion ${srcversion}"
                return 1
            }
            if module_contains_cmp_marker "${resolved}"; then
                err "Resolved core contains a cmpunlocker build marker: ${resolved}"
                return 1
            else
                marker_rc=$?
                (( marker_rc == 1 )) || {
                    err "Could not inspect ${resolved} for the cmpunlocker build marker"
                    return 1
                }
            fi
        fi
    done
    validate_stock_physical_directory "${set_dir}" resolved_set || {
        err "Resolved stock directory contains nested, compressed, or symlinked duplicate modules: ${set_dir}"
        return 1
    }
    VERIFIED_STOCK_HASHES="$(IFS=:; printf '%s' "${actual_stock_hashes[*]}")"
    ok "Verified exact stock NVIDIA ${expected_version} five-module set for ${kernel}"
}

CAPTURED_STOCK_HASHES=""
CAPTURED_STOCK_MANIFEST=""
capture_prebarrier_stock_set() {
    local kernel="$1" version="$2" patched_core_src="$3" patched_hashes="$4"
    local excluded="$5" stock_root candidate i module_name module_version vermagic
    local srcversion payload_hash marker_rc relative
    local -a candidates=() ordered=() hashes=() manifest=() patched=()

    CAPTURED_STOCK_HASHES=""
    CAPTURED_STOCK_MANIFEST=""
    IFS=: read -r -a patched <<< "${patched_hashes}"
    (( ${#patched[@]} == ${#MODULE_FILES[@]} )) || return 1
    mapfile -d '' -t candidates < <(python3 - "${kernel}" "${excluded}" <<'PY'
import os
import pathlib
import re
import stat
import sys

kernel, excluded_arg = sys.argv[1:]
if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", kernel) is None:
    raise SystemExit("invalid stock-preflight kernel")
modules_root = pathlib.Path("/lib/modules").resolve(strict=True)
root = pathlib.Path("/lib/modules", kernel).resolve(strict=True)
excluded = pathlib.Path(excluded_arg).resolve(strict=False)
if root.parent != modules_root:
    raise SystemExit("kernel root escapes /lib/modules")
root_st = os.lstat(root)
modules_st = os.lstat(modules_root)
if (not stat.S_ISDIR(root_st.st_mode) or stat.S_ISLNK(root_st.st_mode)
        or root_st.st_uid != 0 or root_st.st_gid != 0
        or stat.S_IMODE(root_st.st_mode) & 0o022
        or root_st.st_dev != modules_st.st_dev):
    raise SystemExit("unsafe stock-preflight kernel root")
try:
    excluded.relative_to(root)
except ValueError:
    raise SystemExit("CMP exclusion escapes kernel root")

def mount_points():
    result = []
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields = left.split(b" ")
            tail = right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not field for field in fields)
                    or any(not field for field in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded = fields[4]
            decoded = bytearray()
            index = 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index])
                    index += 1
                    continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8))
                index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.extend((mount, os.path.normpath(os.path.realpath(mount))))
    return result

root_aliases = {os.path.normpath(os.fspath(root)),
                os.path.normpath(os.fspath(pathlib.Path("/lib/modules", kernel)))}
for mount in mount_points():
    for exact in root_aliases:
        if mount == exact or mount.startswith(exact + os.sep):
            raise SystemExit(f"mount blocks stock preflight: {mount}")

names = re.compile(r"^(nvidia|nvidia-modeset|nvidia-uvm|nvidia-drm|nvidia-peermem)\.ko(?:\.gz|\.xz|\.zst)?$")
candidates = []
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    current_path = pathlib.Path(current)
    cst = os.lstat(current_path)
    if (not stat.S_ISDIR(cst.st_mode) or stat.S_ISLNK(cst.st_mode)
            or cst.st_uid != 0 or cst.st_gid != 0
            or stat.S_IMODE(cst.st_mode) & 0o022 or cst.st_dev != root_st.st_dev):
        raise SystemExit(f"unsafe module-tree directory: {current_path}")
    kept = []
    for dirname in dirs:
        child = current_path / dirname
        if child == excluded or excluded in child.parents:
            continue
        dst = os.lstat(child)
        if stat.S_ISLNK(dst.st_mode):
            continue
        kept.append(dirname)
    dirs[:] = kept
    for filename in files:
        if names.fullmatch(filename) is None:
            continue
        path = current_path / filename
        if path == excluded or excluded in path.parents:
            continue
        fst = os.lstat(path)
        if (not stat.S_ISREG(fst.st_mode) or stat.S_ISLNK(fst.st_mode)
                or fst.st_uid != 0 or fst.st_gid != 0 or fst.st_nlink != 1
                or stat.S_IMODE(fst.st_mode) & 0o022 or fst.st_dev != root_st.st_dev):
            raise SystemExit(f"unsafe stock candidate: {path}")
        candidates.append(path)
if len(candidates) != 5 or len({path.parent for path in candidates}) != 1:
    raise SystemExit("stock preflight requires one unique physical five-module directory")
bases = [re.sub(r"\.ko(?:\.gz|\.xz|\.zst)?$", "", path.name)
         for path in candidates]
if set(bases) != {"nvidia", "nvidia-modeset", "nvidia-uvm", "nvidia-drm", "nvidia-peermem"}:
    raise SystemExit("stock preflight module names are incomplete or duplicated")
for path in sorted(candidates):
    sys.stdout.buffer.write(os.fsencode(path) + b"\0")
PY
    ) || return 1
    (( ${#candidates[@]} == ${#MODULE_FILES[@]} )) || return 1
    stock_root="$(readlink -f -- "/lib/modules/${kernel}")" || return 1
    for i in "${!MODULE_FILES[@]}"; do
        candidate=""
        for relative in "${candidates[@]}"; do
            case "${relative}" in
                */"${MODULE_FILES[$i]}"|*/"${MODULE_FILES[$i]}.gz"|\
                */"${MODULE_FILES[$i]}.xz"|*/"${MODULE_FILES[$i]}.zst")
                    [[ -z "${candidate}" ]] || return 1
                    candidate="${relative}"
                    ;;
            esac
        done
        [[ -n "${candidate}" ]] || return 1
        module_name="$(modinfo -F name -- "${candidate}" 2>/dev/null)" || return 1
        [[ "${module_name}" == "${MODULE_INTERNAL[$i]}" ]] || return 1
        module_version="$(modinfo -F version -- "${candidate}" 2>/dev/null)" || return 1
        [[ "${module_version}" == "${version}" ]] || return 1
        vermagic="$(modinfo -F vermagic -- "${candidate}" 2>/dev/null)" || return 1
        [[ "${vermagic}" == "${kernel}" || "${vermagic}" == "${kernel} "* ]] || return 1
        srcversion="$(modinfo -F srcversion -- "${candidate}" 2>/dev/null)" || return 1
        [[ "${srcversion}" =~ ^[A-Fa-f0-9]+$ ]] || return 1
        payload_hash="$(module_payload_sha256 "${candidate}")" || return 1
        [[ "${payload_hash}" =~ ^[a-f0-9]{64}$ ]] || return 1
        hashes+=("${payload_hash}")
        relative="${candidate#${stock_root}/}"
        [[ "${relative}" != "${candidate}" ]] || return 1
        manifest+=("${relative}@${payload_hash}")
        if (( i == 0 )); then
            [[ "${payload_hash}" != "${patched[$i]}" && \
               "${srcversion}" != "${patched_core_src}" ]] || return 1
            if module_contains_cmp_marker "${candidate}"; then
                return 1
            else
                marker_rc=$?
                (( marker_rc == 1 )) || return 1
            fi
        fi
        ordered+=("${candidate}")
    done
    mapfile -t manifest < <(printf '%s\n' "${manifest[@]}" | LC_ALL=C sort)
    CAPTURED_STOCK_HASHES="$(IFS=:; printf '%s' "${hashes[*]}")"
    CAPTURED_STOCK_MANIFEST="$(IFS=';'; printf '%s' "${manifest[*]}")"
    valid_stock_candidate_manifest "${CAPTURED_STOCK_MANIFEST}"
}

verify_prebarrier_stock_set() {
    local kernel="$1" version="$2" core="$3" patched="$4" excluded="$5"
    local expected_hashes="$6" expected_manifest="$7"
    capture_prebarrier_stock_set "${kernel}" "${version}" "${core}" \
        "${patched}" "${excluded}" && \
        [[ "${CAPTURED_STOCK_HASHES}" == "${expected_hashes}" && \
           "${CAPTURED_STOCK_MANIFEST}" == "${expected_manifest}" ]]
}

declare -A DKMS_DATA=()
DKMS_VERSION=""
DKMS_KERNEL=""
DKMS_ARCH=""
DKMS_PATH=""

parse_dkms_receipt() {
    local kernel="$1"
    local expected_version="${2:-}"
    local receipt="${STATE_DIR}/dkms-removed.${kernel}.receipt"

    DKMS_PATH="${receipt}"
    [[ -e "${receipt}" || -L "${receipt}" ]] || return 2
    read_kv_state "${receipt}" "format,module,version,kernel,arch" DKMS_DATA || return 1
    [[ "${DKMS_DATA[format]:-}" == "1" && "${DKMS_DATA[module]:-}" == "nvidia" ]] || return 1
    valid_version "${DKMS_DATA[version]:-}" || return 1
    [[ "${DKMS_DATA[kernel]:-}" == "${kernel}" ]] || return 1
    [[ "${DKMS_DATA[arch]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1
    [[ -z "${expected_version}" || "${DKMS_DATA[version]}" == "${expected_version}" ]] || return 1
    cmp -s -- "${receipt}" <(printf 'format=1\nmodule=nvidia\nversion=%s\nkernel=%s\narch=%s\n' \
        "${DKMS_DATA[version]}" "${DKMS_DATA[kernel]}" "${DKMS_DATA[arch]}") || return 1
    DKMS_VERSION="${DKMS_DATA[version]}"
    DKMS_KERNEL="${DKMS_DATA[kernel]}"
    DKMS_ARCH="${DKMS_DATA[arch]}"
    dkms_original_residue_absent "${DKMS_KERNEL}" "${DKMS_ARCH}" || return 1
}

DKMS_EXECUTABLE="/usr/bin/dkms"

validate_dkms_executable() {
    python3 - "${DKMS_EXECUTABLE}" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_absolute() or path.resolve(strict=True) != path:
    raise SystemExit("DKMS executable path is not canonical")
current = pathlib.Path(path.root)
for component in path.parts[1:-1]:
    current /= component
    st = os.lstat(current)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022):
        raise SystemExit(f"unsafe DKMS executable ancestor: {current}")
st = os.lstat(path)
if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
        or stat.S_IMODE(st.st_mode) & 0o022 or not os.access(path, os.X_OK)):
    raise SystemExit("unsafe DKMS executable")
PY
}

dkms_sanitized() {
    env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root LC_ALL=C LANG=C \
        "${DKMS_EXECUTABLE}" "$@"
}

dkms_tool_available() {
    local help
    validate_dkms_executable || return 1
    help="$(dkms_sanitized --help 2>&1 || true)"
    [[ "${help}" == *"--no-depmod"* && "${help}" == *"--directive"* && \
       "${help}" == *"--dkmstree"* && \
       "${help}" == *"--installtree"* && "${help}" == *" build "* && \
       "${help}" == *" install "* && "${help}" == *"unbuild"* ]]
}

ensure_dkms_tool() {
    dkms_tool_available || \
        die "A DKMS restoration receipt exists, but exact --no-depmod DKMS operations are unavailable"
}

validate_dkms_tree_configuration() {
    python3 - "${DKMS_TREE}" "${DKMS_INSTALL_TREE}" <<'PY'
import glob
import os
import pathlib
import re
import shlex
import stat
import sys

expected_tree = pathlib.Path(sys.argv[1])
expected_install = pathlib.Path(sys.argv[2])
files = [pathlib.Path("/etc/dkms/framework.conf")]
files.extend(pathlib.Path(p) for p in sorted(glob.glob("/etc/dkms/framework.conf.d/*.conf")))
selected = {
    "dkms_tree": str(expected_tree),
    "install_tree": str(expected_install),
    "symlink_modules": "",
    "modprobe_on_install": "",
    "build_environment": "",
    "post_transaction": "",
    "sign_file": "",
    "mok_signing_key": "",
    "mok_certificate": "",
    "try_sign_modules": "",
}
for path in files:
    try:
        pst = os.lstat(path)
    except FileNotFoundError:
        continue
    if (not stat.S_ISREG(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
            or pst.st_uid != 0 or pst.st_gid != 0
            or stat.S_IMODE(pst.st_mode) & 0o022):
        raise SystemExit(f"unsafe DKMS framework configuration: {path}")
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = raw.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        mentioned = [key for key in selected if re.search(rf"\b{key}\b", raw)]
        if not mentioned:
            continue
        if len(mentioned) != 1:
            raise SystemExit(f"ambiguous DKMS framework setting at {path}:{number}")
        key = mentioned[0]
        match = re.fullmatch(
            rf"\s*(?:export\s+)?{re.escape(key)}\s*=\s*(.*?)\s*(?:#.*)?", raw
        )
        if match is None:
            raise SystemExit(f"unsupported dynamic {key} setting at {path}:{number}")
        if key in ("sign_file", "mok_signing_key", "mok_certificate",
                   "try_sign_modules") and any(
                token in match.group(1) for token in ("$", "`", ";", "(", ")")):
            raise SystemExit(f"dynamic DKMS signing setting at {path}:{number}")
        try:
            values = shlex.split(match.group(1), posix=True)
        except ValueError as error:
            raise SystemExit(f"invalid {key} setting at {path}:{number}: {error}")
        if not values and not match.group(1).strip():
            selected[key] = ""
            continue
        if len(values) != 1:
            raise SystemExit(f"ambiguous {key} setting at {path}:{number}")
        selected[key] = values[0]

addon_config = pathlib.Path("/etc/sysconfig/module-init-tools")
if os.path.lexists(addon_config):
    ast = os.lstat(addon_config)
    if (not stat.S_ISREG(ast.st_mode) or stat.S_ISLNK(ast.st_mode)
            or ast.st_uid != 0 or ast.st_gid != 0
            or stat.S_IMODE(ast.st_mode) & 0o022):
        raise SystemExit(f"unsafe DKMS addon-module configuration: {addon_config}")
    addon = ""
    for number, raw in enumerate(addon_config.read_text(encoding="utf-8").splitlines(), 1):
        stripped = raw.lstrip()
        if not stripped or stripped.startswith("#") or not re.search(r"\bADDON_MODULES_DIR\b", raw):
            continue
        match = re.fullmatch(r"\s*(?:export\s+)?ADDON_MODULES_DIR\s*=\s*(.*?)\s*(?:#.*)?", raw)
        if match is None:
            raise SystemExit(f"unsupported dynamic ADDON_MODULES_DIR at {addon_config}:{number}")
        values = shlex.split(match.group(1), posix=True)
        if len(values) != 1:
            raise SystemExit(f"ambiguous ADDON_MODULES_DIR at {addon_config}:{number}")
        addon = values[0]
    if addon:
        raise SystemExit("custom ADDON_MODULES_DIR is unsupported")

if selected["dkms_tree"] != str(expected_tree):
    raise SystemExit(
        f"custom dkms_tree={selected['dkms_tree']} is unsupported; expected {expected_tree}"
    )
if selected["symlink_modules"]:
    raise SystemExit("symlink_modules is unsupported for an auditable DKMS transaction")
for key in ("modprobe_on_install", "build_environment", "post_transaction"):
    if selected[key]:
        raise SystemExit(f"nonempty DKMS {key} is unsupported for an auditable transaction")
if selected["try_sign_modules"] not in ("", "true", "false", "not_in_chroot"):
    raise SystemExit("unsupported DKMS try_sign_modules policy")
if selected["mok_signing_key"].startswith("pkcs11:"):
    raise SystemExit("PKCS#11 DKMS signing keys are unsupported for this transaction")
if selected["install_tree"] not in ("/lib/modules", "/usr/lib/modules"):
    raise SystemExit(
        f"custom install_tree={selected['install_tree']} is unsupported"
    )
try:
    selected_install = pathlib.Path(selected["install_tree"]).resolve(strict=True)
    canonical_expected = expected_install.resolve(strict=True)
    canonical_modules = pathlib.Path("/lib/modules").resolve(strict=True)
except OSError as error:
    raise SystemExit(f"cannot resolve audited DKMS install tree: {error}")
if selected_install != canonical_expected or selected_install != canonical_modules:
    raise SystemExit("DKMS install_tree is not the canonical /lib/modules tree")

# On RPM/SUSE families DKMS normally removes/adds weak-module links in other
# kernel trees.  The legacy receipt does not journal that cross-kernel set, so
# neither a successful restore nor a hard-cut rollback can reproduce it
# exactly.  Restrict receipt-driven restoration to families where DKMS 3.4 has
# no weak-module helper and keep NO_WEAK_MODULES pinned as a second guard.
os_release = pathlib.Path("/etc/os-release")
if not os.path.lexists(os_release):
    os_release = pathlib.Path("/usr/lib/os-release")
resolved_release = os_release.resolve(strict=True)
ost = os.lstat(resolved_release)
if (not stat.S_ISREG(ost.st_mode) or ost.st_uid != 0 or ost.st_gid != 0
        or stat.S_IMODE(ost.st_mode) & 0o022):
    raise SystemExit("unsafe os-release for DKMS distribution validation")
release = {}
for number, raw in enumerate(resolved_release.read_text(encoding="ascii").splitlines(), 1):
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue
    match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)", stripped)
    if match is None:
        continue
    key, encoded = match.groups()
    if key not in ("ID", "ID_LIKE"):
        continue
    if key in release or any(token in encoded for token in ("$", "`", ";", "(", ")")):
        raise SystemExit(f"dynamic or duplicate {key} in os-release")
    values = shlex.split(encoded, posix=True)
    if len(values) != 1:
        raise SystemExit(f"ambiguous {key} in os-release")
    release[key] = values[0]
identifier = release.get("ID", "")
if identifier != "ubuntu" and release.get("ID_LIKE", ""):
    identifier = release["ID_LIKE"].split()[0]
if not identifier.startswith(("debian", "ubuntu", "arch")):
    raise SystemExit(
        f"DKMS restoration on {identifier or 'unknown'} cannot reproduce weak-module state"
    )
PY
}

DKMS_SIGNING_MODE=""
DKMS_SIGNING_KEY=""
DKMS_SIGNING_CERT=""
DKMS_SIGNING_KEY_HASH=""
DKMS_SIGNING_CERT_HASH=""
DKMS_SIGNING_PROGRAM=""
DKMS_SIGNING_PROGRAM_HASH=""

validate_dkms_signing_preflight() {
    local kernel="$1" output
    local -a values=()

    output="$(python3 - "${kernel}" <<'PY'
import glob
import hashlib
import os
import pathlib
import re
import shlex
import shutil
import stat
import sys

kver = sys.argv[1]
if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", kver) is None:
    raise SystemExit("unsafe signing kernel release")

def digest(path):
    value = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0))
    try:
        with os.fdopen(os.dup(fd), "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
    finally:
        os.close(fd)
    return value.hexdigest()

def trusted_config(path):
    st = os.lstat(path)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022):
        raise SystemExit(f"unsafe DKMS framework configuration: {path}")

def trusted_resolved_file(path, private=False, executable=False, no_symlink=False):
    if not path.is_absolute() or re.fullmatch(r"[A-Za-z0-9._+/-]+", os.fspath(path)) is None:
        raise SystemExit(f"unsafe signing path: {path}")
    resolved = path.resolve(strict=True)
    if no_symlink and resolved != path:
        raise SystemExit(f"symlinked signing credential: {path}")
    current = pathlib.Path(resolved.root)
    for component in resolved.parts[1:-1]:
        current /= component
        cst = os.lstat(current)
        if (not stat.S_ISDIR(cst.st_mode) or stat.S_ISLNK(cst.st_mode)
                or cst.st_uid != 0 or cst.st_gid != 0
                or stat.S_IMODE(cst.st_mode) & 0o022):
            raise SystemExit(f"unsafe signing ancestor: {current}")
    st = os.lstat(resolved)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
            or stat.S_IMODE(st.st_mode) & 0o022
            or (private and stat.S_IMODE(st.st_mode) & 0o077)
            or (executable and not os.access(resolved, os.X_OK))):
        raise SystemExit(f"unsafe signing file: {path}")
    return resolved

selected = {
    "sign_file": "",
    "mok_signing_key": "",
    "mok_certificate": "",
    "try_sign_modules": "",
}
files = [pathlib.Path("/etc/dkms/framework.conf")]
files.extend(pathlib.Path(value) for value in
             sorted(glob.glob("/etc/dkms/framework.conf.d/*.conf")))
for path in files:
    try:
        trusted_config(path)
    except FileNotFoundError:
        continue
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = raw.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        mentioned = [key for key in selected if re.search(rf"\b{key}\b", raw)]
        if not mentioned:
            continue
        if len(mentioned) != 1:
            raise SystemExit(f"ambiguous signing setting at {path}:{number}")
        key = mentioned[0]
        match = re.fullmatch(
            rf"\s*(?:export\s+)?{re.escape(key)}\s*=\s*(.*?)\s*(?:#.*)?", raw
        )
        if match is None or any(token in match.group(1)
                                for token in ("$", "`", ";", "(", ")")):
            raise SystemExit(f"dynamic signing setting at {path}:{number}")
        values = shlex.split(match.group(1), posix=True)
        if not values and not match.group(1).strip():
            selected[key] = ""
        elif len(values) == 1:
            selected[key] = values[0]
        else:
            raise SystemExit(f"ambiguous signing setting at {path}:{number}")

policy = selected["try_sign_modules"]
if policy not in ("", "true", "false", "not_in_chroot"):
    raise SystemExit("unsupported DKMS signing policy")

def disabled():
    print("disabled")
    for _ in range(6):
        print("-")
    raise SystemExit(0)

if policy == "false":
    disabled()

build_link = pathlib.Path("/usr/lib/modules") / kver / "build"
try:
    source = build_link.resolve(strict=True)
except FileNotFoundError:
    raise SystemExit("kernel build tree is missing before DKMS signing preflight")
for candidate in (source / "include/config/auto.conf", source / ".config"):
    if candidate.exists():
        config = candidate
        break
else:
    disabled()
config = trusted_resolved_file(config)
encoded_hashes = [raw for raw in config.read_text(encoding="utf-8").splitlines()
                  if raw.startswith("CONFIG_MODULE_SIG_HASH=")]
if not encoded_hashes:
    disabled()
if len(encoded_hashes) != 1:
    raise SystemExit("ambiguous CONFIG_MODULE_SIG_HASH")
match = re.fullmatch(
    r'CONFIG_MODULE_SIG_HASH=(?:"([A-Za-z0-9_-]+)"|([A-Za-z0-9_-]+))',
    encoded_hashes[0],
)
if match is None:
    raise SystemExit("unsafe CONFIG_MODULE_SIG_HASH")

os_release = pathlib.Path("/etc/os-release")
if not os.path.lexists(os_release):
    os_release = pathlib.Path("/usr/lib/os-release")
release_path = trusted_resolved_file(os_release)
release = {}
for raw in release_path.read_text(encoding="ascii").splitlines():
    match = re.fullmatch(r"(ID|ID_LIKE)=(.*)", raw.strip())
    if not match:
        continue
    key, encoded = match.groups()
    if key in release or any(token in encoded for token in ("$", "`", ";", "(", ")")):
        raise SystemExit("dynamic or duplicate os-release identity")
    values = shlex.split(encoded, posix=True)
    if len(values) != 1:
        raise SystemExit("ambiguous os-release identity")
    release[key] = values[0]
identifier = release.get("ID", "")
if identifier != "ubuntu" and release.get("ID_LIKE", ""):
    identifier = release["ID_LIKE"].split()[0]

if selected["sign_file"]:
    sign_file = pathlib.Path(selected["sign_file"])
elif identifier.startswith("debian"):
    sign_file = pathlib.Path("/usr/lib") / f"linux-kbuild-{kver.rsplit('.', 1)[0]}" / "scripts/sign-file"
elif identifier.startswith("ubuntu"):
    found = shutil.which("kmodsign", path="/usr/bin:/usr/sbin:/bin:/sbin")
    sign_file = pathlib.Path(found) if found else \
        pathlib.Path("/usr/src") / f"linux-headers-{kver}" / "scripts/sign-file"
else:
    sign_file = source / "scripts/sign-file"
if not sign_file.is_file() or not os.access(sign_file, os.X_OK):
    fallback = source / "scripts/sign-file"
    if sign_file != fallback and fallback.is_file() and os.access(fallback, os.X_OK):
        sign_file = fallback
    else:
        disabled()
sign_file = trusted_resolved_file(sign_file, executable=True)

key_value = selected["mok_signing_key"]
cert_value = selected["mok_certificate"]
if not key_value and identifier.startswith("ubuntu"):
    key = pathlib.Path("/var/lib/shim-signed/mok/MOK.priv")
    cert = pathlib.Path("/var/lib/shim-signed/mok/MOK.der")
else:
    if key_value.startswith("pkcs11:"):
        raise SystemExit("PKCS#11 signing keys are unsupported")
    key = pathlib.Path(key_value or "/var/lib/dkms/mok.key")
    cert = pathlib.Path(cert_value or "/var/lib/dkms/mok.pub")
try:
    key = trusted_resolved_file(key, private=True, no_symlink=True)
    cert = trusted_resolved_file(cert, no_symlink=True)
except FileNotFoundError:
    raise SystemExit(
        "effective DKMS signing key/certificate is missing; generate and enroll it explicitly outside removal"
    )

print("active")
print(key)
print(cert)
print(digest(key))
print(digest(cert))
print(sign_file)
print(digest(sign_file))
PY
)" || return 1
    mapfile -t values <<< "${output}"
    (( ${#values[@]} == 7 )) || return 1
    [[ "${values[0]}" == "active" || "${values[0]}" == "disabled" ]] || return 1
    DKMS_SIGNING_MODE="${values[0]}"
    DKMS_SIGNING_KEY="${values[1]}"
    DKMS_SIGNING_CERT="${values[2]}"
    DKMS_SIGNING_KEY_HASH="${values[3]}"
    DKMS_SIGNING_CERT_HASH="${values[4]}"
    DKMS_SIGNING_PROGRAM="${values[5]}"
    DKMS_SIGNING_PROGRAM_HASH="${values[6]}"
}

DKMS_TUPLE_STATE=""
DKMS_GLOBAL_ADDED=0
dkms_original_residue_absent() {
    local kernel="$1" arch="$2"

    python3 - "${DKMS_TREE}" nvidia "${kernel}" "${arch}" <<'PY'
import os
import pathlib
import stat
import sys

tree = pathlib.Path(sys.argv[1])
module, kver, arch = sys.argv[2:5]

def lexists(path):
    return os.path.lexists(path)

def trusted_dir(path, device=None):
    st = os.lstat(path)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022
            or (device is not None and st.st_dev != device)):
        raise SystemExit(f"unsafe DKMS directory: {path}")
    return st

if not lexists(tree) or tree.resolve(strict=False) != tree:
    raise SystemExit("unsafe audited DKMS tree")
tree_st = trusted_dir(tree)
module_dir = tree / module
if not lexists(module_dir):
    raise SystemExit("DKMS module registration is missing")
trusted_dir(module_dir, tree_st.st_dev)
original_root = module_dir / "original_module"
original_kver = original_root / kver
original_arch = original_kver / arch
if lexists(original_root):
    trusted_dir(original_root, tree_st.st_dev)
if lexists(original_kver):
    trusted_dir(original_kver, tree_st.st_dev)
if lexists(original_arch):
    raise SystemExit(f"unexpected DKMS original-module residue: {original_arch}")
PY
}

query_dkms_tuple() {
    local version="$1" kernel="$2" arch="$3"
    local output

    validate_dkms_tree_configuration || return 1
    dkms_original_residue_absent "${kernel}" "${arch}" || return 1
    output="$(dkms_sanitized status -m nvidia -v "${version}" -k "${kernel}" -a "${arch}" \
        --dkmstree "${DKMS_TREE}" --installtree "${DKMS_INSTALL_TREE}" 2>&1)" || {
        err "DKMS status query failed for nvidia/${version}, ${kernel}, ${arch}: ${output}"
        return 1
    }
    DKMS_TUPLE_STATE="$(python3 - "${version}" "${kernel}" "${arch}" "${output}" <<'PY'
import sys

version, kernel, arch, output = sys.argv[1:]
if "\r" in output:
    raise SystemExit("carriage return in DKMS status")
if output == "":
    print("absent-empty")
    raise SystemExit(0)
lines = [line for line in output.split("\n") if line]
if len(lines) != 1:
    raise SystemExit("DKMS status must contain at most one exact line")
line = lines[0]
if line == f"nvidia/{version}: added":
    # DKMS 3.4 reports the module-global source state this way even when the
    # queried kernel/arch tuple does not exist.
    print("absent-added")
    raise SystemExit(0)
prefix = f"nvidia/{version}, {kernel}, {arch}: "
if not line.startswith(prefix):
    raise SystemExit("DKMS status returned a different tuple")
state = line[len(prefix):]
if "Original modules exist" in state:
    raise SystemExit("receipt tuple unexpectedly has original modules")
if state == "installed":
    print("installed")
elif state in ("built", "added",
               "installed (Built modules are missing in the kernel modules folder)",
               "installed (Differences between built and installed modules)",
               "built (Built modules are missing in the kernel modules folder)",
               "built (Differences between built and installed modules)"):
    print("present")
else:
    raise SystemExit("unknown or unsafe DKMS tuple state")
PY
    )" || {
        err "Malformed or ambiguous DKMS status for nvidia/${version}, ${kernel}, ${arch}"
        return 1
    }
    DKMS_GLOBAL_ADDED=0
    case "${DKMS_TUPLE_STATE}" in
        absent-added)
            DKMS_TUPLE_STATE="absent"
            DKMS_GLOBAL_ADDED=1
            ;;
        absent-empty) DKMS_TUPLE_STATE="absent" ;;
        present|installed) ;;
        *) return 1 ;;
    esac
}

dkms_exact_residue_absent() {
    local version="$1" kernel="$2" arch="$3"

    python3 - "${DKMS_TREE}" nvidia "${version}" "${kernel}" "${arch}" <<'PY'
import os
import pathlib
import stat
import sys

tree = pathlib.Path(sys.argv[1])
module, version, kver, arch = sys.argv[2:6]

def lexists(path):
    return os.path.lexists(path)

def trusted_dir(path, device=None):
    st = os.lstat(path)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022
            or (device is not None and st.st_dev != device)):
        raise SystemExit(f"unsafe DKMS directory: {path}")
    return st

if not lexists(tree) or tree.resolve(strict=False) != tree:
    raise SystemExit("unsafe audited DKMS tree")
tree_st = trusted_dir(tree)
module_dir = tree / module
version_dir = module_dir / version
for required in (module_dir, version_dir):
    if not lexists(required):
        raise SystemExit("DKMS source registration is missing")
    trusted_dir(required, tree_st.st_dev)
if lexists(version_dir / "build"):
    raise SystemExit("preexisting shared DKMS build workspace")
kernel_dir = version_dir / kver
base = kernel_dir / arch
if lexists(kernel_dir):
    trusted_dir(kernel_dir, tree_st.st_dev)
    for entry in os.scandir(kernel_dir):
        if entry.name.startswith(f".tmp_{arch}_"):
            raise SystemExit(f"preexisting DKMS build temporary: {entry.path}")
if lexists(base):
    raise SystemExit("exact DKMS tuple base exists")
active = module_dir / f"kernel-{kver}-{arch}"
if lexists(active):
    raise SystemExit("exact DKMS active link exists")
original_root = module_dir / "original_module"
original_kver = original_root / kver
original_arch = original_kver / arch
if lexists(original_root):
    trusted_dir(original_root, tree_st.st_dev)
if lexists(original_kver):
    trusted_dir(original_kver, tree_st.st_dev)
if lexists(original_arch):
    raise SystemExit("exact DKMS original-module residue exists")
PY
}

DETERMINED_DKMS_PRESTATE=""
DETERMINED_DKMS_ARCH="none"
determine_dkms_prestate() {
    local kernel="$1" expected_version="$2" parse_rc

    if parse_dkms_receipt "${kernel}" "${expected_version}"; then
        :
    else
        parse_rc=$?
        if (( parse_rc == 2 )); then
            DETERMINED_DKMS_PRESTATE="none"
            DETERMINED_DKMS_ARCH="none"
            return 0
        fi
        die "Invalid DKMS receipt ${STATE_DIR}/dkms-removed.${kernel}.receipt"
    fi
    ensure_dkms_tool
    DETERMINED_DKMS_ARCH="${DKMS_ARCH}"
    query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
        die "Cannot determine exact DKMS baseline for ${kernel}"
    if [[ "${DKMS_TUPLE_STATE}" == "installed" ]]; then
        DETERMINED_DKMS_PRESTATE="installed"
    elif [[ "${DKMS_TUPLE_STATE}" == "present" ]]; then
        die "DKMS receipt tuple for ${kernel} is present but not installed; baseline is ambiguous"
    else
        [[ "${DKMS_GLOBAL_ADDED}" == "1" ]] && \
            dkms_exact_residue_absent "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
            die "DKMS receipt says absent but exact tuple registration/residue is ambiguous for ${kernel}"
        DETERMINED_DKMS_PRESTATE="absent"
    fi
}

restore_dkms_prestate() {
    local kernel="$1" expected_version="$2" prestate="$3" attempted="$4"
    local install_attempted="$5" built_hashes="$6" preinstall_manifest="$7"
    local persisted_arch="$8" parse_rc version receipt_kernel arch

    # This compatibility helper is deliberately read-only.  Once DKMS build
    # intent is durable, canonical residue is never deleted or rolled back.
    [[ "${attempted}" == "0" && "${install_attempted}" == "0" && \
       "${built_hashes}" == "pending" ]] ||
        return 1
    case "${prestate}" in
        none)
            { [[ "${preinstall_manifest}" == "pending" ]] || \
              valid_stock_candidate_manifest "${preinstall_manifest}"; } && \
            [[ "${persisted_arch}" == "none" && \
               ! -e "${STATE_DIR}/dkms-removed.${kernel}.receipt" && \
               ! -L "${STATE_DIR}/dkms-removed.${kernel}.receipt" ]]
            return
            ;;
        absent)
            [[ "${preinstall_manifest}" == "pending" ]] || return 1
            ;;
        installed)
            [[ "${preinstall_manifest}" == "pending" ]] || \
                valid_stock_candidate_manifest "${preinstall_manifest}" || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "${persisted_arch}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1
    if parse_dkms_receipt "${kernel}" "${expected_version}"; then
        version="${DKMS_VERSION}"
        receipt_kernel="${DKMS_KERNEL}"
        arch="${DKMS_ARCH}"
    else
        parse_rc=$?
        (( parse_rc == 2 )) && err "Required DKMS receipt is missing for ${kernel}"
        return 1
    fi
    [[ "${arch}" == "${persisted_arch}" ]] || return 1
    dkms_tool_available || return 1
    query_dkms_tuple "${version}" "${receipt_kernel}" "${arch}" || return 1
    if [[ "${prestate}" == "installed" ]]; then
        [[ "${DKMS_TUPLE_STATE}" == "installed" ]]
    else
        [[ "${DKMS_TUPLE_STATE}" == "absent" && "${DKMS_GLOBAL_ADDED}" == "1" ]] && \
            dkms_exact_residue_absent "${version}" "${receipt_kernel}" "${arch}"
    fi
}

ensure_stock_dkms_state() {
    local kernel="$1" expected_version="$2" prestate="$3" attempted="$4" receipt_committed="$5"
    local persisted_arch="$6"
    local receipt="${STATE_DIR}/dkms-removed.${kernel}.receipt"

    if [[ "${receipt_committed}" == "1" && ! -e "${receipt}" && ! -L "${receipt}" ]]; then
        if [[ "${prestate}" == "none" ]]; then
            [[ "${persisted_arch}" == "none" ]] || \
                die "Non-DKMS removal state has an unexpected architecture for ${kernel}"
            return 0
        fi
        [[ "${persisted_arch}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
            die "Committed DKMS state has no exact architecture for ${kernel}"
        ensure_dkms_tool
        query_dkms_tuple "${expected_version}" "${kernel}" "${persisted_arch}" && \
            [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
            die "Committed DKMS tuple changed after receipt cleanup for ${kernel}"
        return 0
    fi
    if [[ "${prestate}" == "none" ]]; then
        [[ "${persisted_arch}" == "none" ]] || \
            die "Non-DKMS removal state has an unexpected architecture for ${kernel}"
        [[ ! -e "${receipt}" && ! -L "${receipt}" ]] || \
            die "Unexpected DKMS receipt appeared for ${kernel}"
        return 0
    fi
    if [[ "${prestate}" == "installed" ]]; then
        parse_dkms_receipt "${kernel}" "${expected_version}" || \
            die "Required DKMS receipt is missing or invalid for ${kernel}"
        [[ "${DKMS_ARCH}" == "${persisted_arch}" ]] || \
            die "DKMS receipt architecture changed for ${kernel}"
        ensure_dkms_tool
        query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
            die "Cannot inspect exact DKMS tuple for ${kernel}"
        [[ "${DKMS_TUPLE_STATE}" == "installed" && "${attempted}" == "0" ]] || \
            die "Preinstalled DKMS tuple changed outside the removal transaction for ${kernel}"
        return 0
    fi
    [[ "${prestate}" == "absent" && "${attempted}" == "1" ]] || \
        die "Removal never acquired authority to install DKMS for ${kernel}"
    parse_dkms_receipt "${kernel}" "${expected_version}" || \
        die "Required DKMS receipt is missing or invalid for ${kernel}"
    [[ "${DKMS_ARCH}" == "${persisted_arch}" ]] || \
        die "DKMS receipt architecture changed for ${kernel}"
    ensure_dkms_tool
    query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
        [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
        die "Committed stock DKMS tuple changed outside the removal transaction for ${kernel}"
}

declare -a FIRMWARE_CHANGED_MAIN=()
declare -a FIRMWARE_TOUCHED_VERSIONS=()
declare -A FIRMWARE_STOCK_HASH_BY_VERSION=()
declare -A FIRMWARE_PATCHED_HASH_BY_VERSION=()
declare -A FIRMWARE_PRESTATE_BY_VERSION=()
declare -A FIRMWARE_ATTEMPTED_BY_VERSION=()
REMOVE_TRANSACTION_ACTIVE=0

array_has() {
    local needle="$1"
    shift
    local value
    for value in "$@"; do
        [[ "${value}" == "${needle}" ]] && return 0
    done
    return 1
}

touch_firmware_version() {
    local version="$1"
    array_has "${version}" "${FIRMWARE_TOUCHED_VERSIONS[@]}" || \
        FIRMWARE_TOUCHED_VERSIONS+=("${version}")
}

DETERMINED_FIRMWARE_PRESTATE=""
DETERMINED_FIRMWARE_STOCK_HASH=""
DETERMINED_FIRMWARE_PATCHED_HASH=""
FIRMWARE_NAMESPACE_MAIN_HASH=""
FIRMWARE_NAMESPACE_BACKUP_HASH=""
FIRMWARE_NAMESPACE_PATCHED_HASH=""
FIRMWARE_NAMESPACE_CHANGED="0"
firmware_namespace_action() {
    local version="$1" action="$2" stock_hash="${3:-absent}"
    local patched_hash="${4:-absent}" desired="${5:-none}"
    local allow_partial="${6:-0}" output
    local -a values=()

    output="$(python3 - "${version}" "${action}" "${stock_hash}" \
        "${patched_hash}" "${desired}" "${allow_partial}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

version, action, stock_hash, patched_hash, desired, allow_raw = sys.argv[1:]
if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None:
    raise SystemExit("invalid firmware version")
if action not in ("inspect", "inspect-recorded", "inspect-attempted",
                  "validate-attempted", "restore-stock", "restore-prestate",
                  "cleanup"):
    raise SystemExit("invalid firmware namespace action")
if desired not in ("none", "stock", "patched") or allow_raw not in ("0", "1"):
    raise SystemExit("invalid firmware action authority")
allow_partial = allow_raw == "1"
if action == "inspect":
    if (stock_hash, patched_hash, desired, allow_raw) != ("absent", "absent", "none", "0"):
        raise SystemExit("inspect has mutation authority")
elif action == "inspect-recorded":
    if (desired != "none" or allow_raw != "1"
            or re.fullmatch(r"[a-f0-9]{64}", stock_hash) is None
            or re.fullmatch(r"[a-f0-9]{64}", patched_hash) is None
            or stock_hash == patched_hash):
        raise SystemExit("recorded inspection lacks exact recovery authority")
elif action in ("inspect-attempted", "validate-attempted"):
    if (desired != "none" or allow_raw != "0"
            or re.fullmatch(r"[a-f0-9]{64}", stock_hash) is None
            or re.fullmatch(r"[a-f0-9]{64}", patched_hash) is None
            or stock_hash == patched_hash):
        raise SystemExit("attempted inspection lacks exact recovery authority")
else:
    if (re.fullmatch(r"[a-f0-9]{64}", stock_hash) is None
            or re.fullmatch(r"[a-f0-9]{64}", patched_hash) is None
            or stock_hash == patched_hash):
        if not (action == "cleanup" and stock_hash == patched_hash == "absent"):
            raise SystemExit("invalid firmware hash authority")
if action in ("restore-stock", "restore-prestate") and desired not in ("stock", "patched"):
    raise SystemExit("firmware rollback has no desired identity")
if action not in ("restore-stock", "restore-prestate") and desired != "none":
    raise SystemExit("unexpected firmware desired identity")

logical_firmware_root = pathlib.Path("/lib/firmware")
canonical_firmware_root = logical_firmware_root.resolve(strict=True)
logical_root = logical_firmware_root / "nvidia"
canonical_root = canonical_firmware_root / "nvidia"
version_dir = logical_root / version
canonical_version = canonical_root / version

def trusted_dir(path, device=None):
    st = os.lstat(path)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022
            or (device is not None and st.st_dev != device)):
        raise SystemExit(f"unsafe firmware directory: {path}")
    return st

current = pathlib.Path(canonical_firmware_root.root)
for component in canonical_firmware_root.parts[1:]:
    current /= component
    trusted_dir(current)
firmware_st = trusted_dir(canonical_firmware_root)
dir_flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
             | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
firmware_fd = os.open(canonical_firmware_root, dir_flags)
logical_firmware_st = os.lstat(logical_firmware_root)
opened_firmware_st = os.fstat(firmware_fd)
if (stat.S_ISLNK(logical_firmware_st.st_mode)
        or not stat.S_ISDIR(logical_firmware_st.st_mode)
        or (logical_firmware_st.st_dev, logical_firmware_st.st_ino) !=
           (opened_firmware_st.st_dev, opened_firmware_st.st_ino)
        or (firmware_st.st_dev, firmware_st.st_ino) !=
           (opened_firmware_st.st_dev, opened_firmware_st.st_ino)
        or opened_firmware_st.st_uid != firmware_st.st_uid
        or opened_firmware_st.st_gid != firmware_st.st_gid
        or stat.S_IMODE(opened_firmware_st.st_mode) !=
           stat.S_IMODE(firmware_st.st_mode)):
    raise SystemExit("logical firmware root is not the canonical directory")
root_lst = os.stat("nvidia", dir_fd=firmware_fd, follow_symlinks=False)
nvidia_fd = os.open("nvidia", dir_flags, dir_fd=firmware_fd)
root_st = os.fstat(nvidia_fd)
if ((root_st.st_dev, root_st.st_ino) != (root_lst.st_dev, root_lst.st_ino)
        or not stat.S_ISDIR(root_st.st_mode) or root_st.st_uid != 0
        or root_st.st_gid != 0 or stat.S_IMODE(root_st.st_mode) & 0o022
        or root_st.st_dev != firmware_st.st_dev):
    raise SystemExit("unsafe literal NVIDIA firmware directory")
version_lst = os.stat(version, dir_fd=nvidia_fd, follow_symlinks=False)
dfd = os.open(version, dir_flags, dir_fd=nvidia_fd)
version_st = os.fstat(dfd)
if ((version_st.st_dev, version_st.st_ino) !=
        (version_lst.st_dev, version_lst.st_ino)
        or not stat.S_ISDIR(version_st.st_mode) or version_st.st_uid != 0
        or version_st.st_gid != 0 or stat.S_IMODE(version_st.st_mode) & 0o022
        or version_st.st_dev != root_st.st_dev):
    raise SystemExit("unsafe firmware version directory")

def verify_ancestry():
    canonical_firmware = os.lstat(canonical_firmware_root)
    logical_firmware = os.lstat(logical_firmware_root)
    opened_firmware = os.fstat(firmware_fd)
    current_root = os.stat("nvidia", dir_fd=firmware_fd, follow_symlinks=False)
    opened_root = os.fstat(nvidia_fd)
    current_version = os.stat(version, dir_fd=nvidia_fd, follow_symlinks=False)
    opened_version = os.fstat(dfd)
    snapshots = ((canonical_firmware, firmware_st),
                 (logical_firmware, firmware_st),
                 (opened_firmware, firmware_st),
                 (current_root, root_st), (opened_root, root_st),
                 (current_version, version_st), (opened_version, version_st))
    if any((not stat.S_ISDIR(current.st_mode)
            or stat.S_ISLNK(current.st_mode)
            or (current.st_dev, current.st_ino) !=
               (expected.st_dev, expected.st_ino)
            or current.st_uid != expected.st_uid
            or current.st_gid != expected.st_gid
            or stat.S_IMODE(current.st_mode) != stat.S_IMODE(expected.st_mode))
           for current, expected in snapshots):
        raise SystemExit("firmware directory ancestry or metadata changed")
    if ((current_root.st_dev, current_root.st_ino) !=
            (root_st.st_dev, root_st.st_ino)
            or (opened_root.st_dev, opened_root.st_ino) !=
               (root_st.st_dev, root_st.st_ino)
            or (current_version.st_dev, current_version.st_ino) !=
               (version_st.st_dev, version_st.st_ino)
            or (opened_version.st_dev, opened_version.st_ino) !=
               (version_st.st_dev, version_st.st_ino)):
        raise SystemExit("firmware directory ancestry changed")

def strict_mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

logical_prefix = os.path.normpath(os.fspath(version_dir)) + os.sep
canonical_prefix = os.path.normpath(os.fspath(canonical_version)) + os.sep
version_aliases = {os.path.normpath(os.fspath(version_dir)),
                   os.path.normpath(os.fspath(canonical_version))}
root_aliases = {os.path.normpath(os.fspath(logical_root)),
                os.path.normpath(os.fspath(canonical_root))}

def reject_mounts():
    for mount in strict_mounts():
        if (mount in root_aliases or mount in version_aliases
                or mount.startswith(logical_prefix)
                or mount.startswith(canonical_prefix)):
            raise SystemExit(f"mount blocks firmware transaction: {mount}")

reject_mounts()
verify_ancestry()
fds = {}
leaf_xattrs = {}
temp_fd = new_fd = -1
temp_name = None
temp_st = None
temp_identity = None
temp_expected_xattrs = None
temp_expected_hash = None
published_main_st = None
names = {
    "main": "gsp_tu10x.bin",
    "backup": "gsp_tu10x.bin.cmpunlocker.bak",
    "patched": "gsp_tu10x.bin.cmpunlocker.patched",
}

def digest(fd):
    value = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        value.update(block)
    return value.hexdigest()

def xattrs(fd):
    return tuple((name, os.getxattr(fd, name))
                 for name in sorted(os.listxattr(fd)))

def install_xattrs(fd, expected):
    wanted = dict(expected)
    for name in os.listxattr(fd):
        if name not in wanted:
            os.removexattr(fd, name)
    for name, value in expected:
        os.setxattr(fd, name, value)
    if xattrs(fd) != expected:
        raise SystemExit("firmware replacement xattrs did not round-trip")

def exact_stat(current, expected):
    return (stat.S_ISREG(current.st_mode)
            and stat.S_ISREG(expected.st_mode)
            and (current.st_dev, current.st_ino) ==
               (expected.st_dev, expected.st_ino)
            and current.st_uid == expected.st_uid
            and current.st_gid == expected.st_gid
            and current.st_nlink == expected.st_nlink
            and stat.S_IMODE(current.st_mode) == stat.S_IMODE(expected.st_mode)
            and current.st_size == expected.st_size
            and current.st_mtime_ns == expected.st_mtime_ns
            and current.st_ctime_ns == expected.st_ctime_ns)

def open_leaf(label, required):
    name = names[label]
    try:
        lst = os.stat(name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        if required:
            raise SystemExit(f"missing firmware leaf: {name}")
        return None
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    st = os.fstat(fd)
    if ((st.st_dev, st.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
            or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) & 0o022
            or st.st_dev != version_st.st_dev or st.st_size <= 0):
        os.close(fd)
        raise SystemExit(f"unsafe firmware leaf: {name}")
    fds[label] = (fd, st)
    leaf_xattrs[label] = xattrs(fd)
    return digest(fd)

def identity_matches(label):
    fd, opened = fds[label]
    current = os.stat(names[label], dir_fd=dfd, follow_symlinks=False)
    held = os.fstat(fd)
    return (exact_stat(current, opened) and exact_stat(held, opened)
            and opened.st_nlink == 1
            and digest(fd) == hashes[label]
            and xattrs(fd) == leaf_xattrs[label])

def publish_from(label, expected_hash):
    global temp_fd, new_fd, temp_name, temp_st, temp_identity
    global temp_expected_xattrs, temp_expected_hash, published_main_st
    source_fd, source_st = fds[label]
    main_fd, main_st = fds["main"]
    metadata_xattrs = xattrs(main_fd)
    if hashes["main"] == expected_hash:
        reject_mounts(); verify_ancestry()
        current = os.stat(names["main"], dir_fd=dfd, follow_symlinks=False)
        if ((current.st_dev, current.st_ino) != (main_st.st_dev, main_st.st_ino)
                or current.st_uid != main_st.st_uid
                or current.st_gid != main_st.st_gid
                or stat.S_IMODE(current.st_mode) != stat.S_IMODE(main_st.st_mode)
                or not identity_matches("main")
                or xattrs(main_fd) != metadata_xattrs):
            raise SystemExit("existing firmware content or metadata changed")
        os.fsync(main_fd); os.fsync(dfd)
        return False
    # The receipt binds this deterministic reserved name through expected_hash.
    # A hard cut at any byte count can therefore reclaim the exact pathname;
    # an unjournaled caller must still prove it absent before acquiring intent.
    candidate_name = f".cmpunlocker-remove.gsp_tu10x.bin.tmp.{expected_hash}"
    temp_fd = os.open(candidate_name, os.O_RDWR | os.O_CREAT | os.O_EXCL
                      | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                      stat.S_IMODE(main_st.st_mode), dir_fd=dfd)
    temp_name = candidate_name
    created_temp = os.fstat(temp_fd)
    temp_identity = (created_temp.st_dev, created_temp.st_ino)
    os.lseek(source_fd, 0, os.SEEK_SET)
    while True:
        block = os.read(source_fd, 1024 * 1024)
        if not block:
            break
        view = memoryview(block)
        while view:
            view = view[os.write(temp_fd, view):]
    os.fchown(temp_fd, main_st.st_uid, main_st.st_gid)
    os.fchmod(temp_fd, stat.S_IMODE(main_st.st_mode))
    install_xattrs(temp_fd, metadata_xattrs)
    os.fsync(temp_fd)
    temp_st = os.fstat(temp_fd)
    temp_expected_xattrs = metadata_xattrs
    temp_expected_hash = expected_hash
    if (not stat.S_ISREG(temp_st.st_mode)
            or temp_st.st_uid != main_st.st_uid
            or temp_st.st_gid != main_st.st_gid or temp_st.st_nlink != 1
            or stat.S_IMODE(temp_st.st_mode) != stat.S_IMODE(main_st.st_mode)
            or temp_st.st_dev != version_st.st_dev
            or digest(temp_fd) != expected_hash
            or xattrs(temp_fd) != metadata_xattrs):
        raise SystemExit("firmware temp copy content or metadata mismatch")
    reject_mounts(); verify_ancestry()
    opened_parent = os.fstat(dfd)
    current_temp = os.stat(temp_name, dir_fd=dfd, follow_symlinks=False)
    if ((opened_parent.st_dev, opened_parent.st_ino) !=
            (version_st.st_dev, version_st.st_ino)
            or opened_parent.st_uid != version_st.st_uid
            or opened_parent.st_gid != version_st.st_gid
            or stat.S_IMODE(opened_parent.st_mode) !=
               stat.S_IMODE(version_st.st_mode)
            or (current_temp.st_dev, current_temp.st_ino) !=
               (temp_st.st_dev, temp_st.st_ino)
            or not stat.S_ISREG(current_temp.st_mode)
            or current_temp.st_uid != temp_st.st_uid
            or current_temp.st_gid != temp_st.st_gid
            or current_temp.st_nlink != temp_st.st_nlink
            or stat.S_IMODE(current_temp.st_mode) !=
               stat.S_IMODE(temp_st.st_mode)
            or current_temp.st_size != temp_st.st_size
            or digest(temp_fd) != expected_hash
            or xattrs(temp_fd) != metadata_xattrs
            or not identity_matches(label) or not identity_matches("main")
            or xattrs(main_fd) != metadata_xattrs):
        raise SystemExit("firmware namespace changed before atomic restore")
    os.replace(temp_name, names["main"], src_dir_fd=dfd, dst_dir_fd=dfd)
    temp_name = None
    new_fd = os.open(names["main"], os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                     | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    new_path_st = os.stat(names["main"], dir_fd=dfd, follow_symlinks=False)
    new_st = os.fstat(new_fd)
    published_temp_st = os.fstat(temp_fd)
    if (not exact_stat(new_path_st, new_st)
            or not exact_stat(new_st, published_temp_st)
            or (new_st.st_dev, new_st.st_ino) != temp_identity
            or (temp_st.st_dev, temp_st.st_ino) != temp_identity
            or new_st.st_uid != temp_st.st_uid
            or new_st.st_gid != temp_st.st_gid
            or new_st.st_nlink != temp_st.st_nlink
            or new_st.st_nlink != 1
            or stat.S_IMODE(new_st.st_mode) != stat.S_IMODE(temp_st.st_mode)
            or new_st.st_size != temp_st.st_size
            or new_st.st_mtime_ns != temp_st.st_mtime_ns
            or digest(new_fd) != expected_hash
            or digest(temp_fd) != expected_hash
            or xattrs(new_fd) != metadata_xattrs
            or xattrs(temp_fd) != metadata_xattrs):
        raise SystemExit("published firmware content or metadata mismatch")
    published_main_st = published_temp_st
    os.fsync(new_fd); os.fsync(dfd)
    return True

def verify_final_namespace():
    reject_mounts(); verify_ancestry()
    for label in ("main", "backup", "patched"):
        if hashes[label] is None:
            try:
                os.stat(names[label], dir_fd=dfd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise SystemExit(f"absent firmware leaf reappeared: {names[label]}")
        if label == "main" and new_fd >= 0:
            fd, opened = new_fd, published_main_st
        else:
            fd, opened = fds[label]
        if opened is None:
            raise SystemExit(f"firmware leaf lacks a retained snapshot: {names[label]}")
        current = os.stat(names[label], dir_fd=dfd, follow_symlinks=False)
        held = os.fstat(fd)
        if (not exact_stat(current, opened)
                or not exact_stat(held, opened)
                or opened.st_nlink != 1
                or digest(fd) != hashes[label]
                or xattrs(fd) != leaf_xattrs[label]):
            raise SystemExit(f"firmware leaf changed before final publication proof: {names[label]}")
    remaining_interrupted = sorted(
        entry.name for entry in os.scandir(dfd)
        if entry.name.startswith(".cmpunlocker-remove.")
    )
    if action == "validate-attempted":
        if remaining_interrupted != sorted(name for name, unused_fd, unused_st in interrupted):
            raise SystemExit("interrupted firmware namespace changed before final proof")
        for name, fd, opened in interrupted:
            current = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            held = os.fstat(fd)
            if (not exact_stat(current, opened) or not exact_stat(held, opened)):
                raise SystemExit("interrupted firmware artifact changed before final proof")
    elif remaining_interrupted:
        raise SystemExit("interrupted firmware artifact appeared before final publication proof")
    reject_mounts(); verify_ancestry()

try:
    verify_ancestry()
    opened_parent = os.fstat(dfd)
    if ((opened_parent.st_dev, opened_parent.st_ino) !=
            (version_st.st_dev, version_st.st_ino)):
        raise SystemExit("firmware version directory changed while opening")
    interrupted = []
    for entry in os.scandir(dfd):
        if not entry.name.startswith(".cmpunlocker-remove."):
            continue
        if re.fullmatch(r"\.cmpunlocker-remove\.gsp_tu10x\.bin\.tmp\.[a-f0-9]{64}",
                        entry.name) is None:
            raise SystemExit(f"unrecognized firmware transaction artifact: {entry.name}")
        fd = os.open(entry.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                     | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
                or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) & 0o022
                or st.st_dev != version_st.st_dev):
            os.close(fd)
            raise SystemExit(f"unsafe interrupted firmware artifact: {entry.name}")
        interrupted.append((entry.name, fd, st))
    if interrupted and (action not in ("inspect-attempted", "validate-attempted")
                        or stock_hash == "absent"):
        raise SystemExit("unowned interrupted firmware artifact requires manual reconciliation")
    for extra in ("gsp_tu10x.bin.cmpunlocker.tmp",
                  "gsp_tu10x.bin.cmpunlocker.cleanup",
                  "gsp_tu10x.bin.cmpunlocker.pat"):
        try:
            os.stat(extra, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        raise SystemExit(f"ambiguous legacy firmware artifact: {extra}")
    hashes = {"main": open_leaf("main", True),
              "backup": open_leaf("backup", False),
              "patched": open_leaf("patched", False)}
    if (hashes["backup"] is None) != (hashes["patched"] is None):
        if action == "inspect" or not allow_partial:
            raise SystemExit("incomplete legacy firmware sidecar pair")

    def inspect_interrupted(expected_hash, remove):
        if not interrupted:
            return
        if len(interrupted) != 1:
            raise SystemExit("multiple interrupted firmware artifacts are not uniquely owned")
        expected_name = f".cmpunlocker-remove.gsp_tu10x.bin.tmp.{expected_hash}"
        if interrupted[0][0] != expected_name:
            raise SystemExit("interrupted firmware artifact is not bound to this receipt")
        if (hashes["backup"] != stock_hash
                or hashes["patched"] != patched_hash
                or hashes["main"] not in (stock_hash, patched_hash)):
            raise SystemExit("interrupted firmware artifact lacks complete receipt-bound namespace")
        main_fd, main_st = fds["main"]
        for name, fd, opened in interrupted:
            held = os.fstat(fd)
            if (not stat.S_ISREG(held.st_mode)
                    or (held.st_dev, held.st_ino) != (opened.st_dev, opened.st_ino)
                    or held.st_uid != main_st.st_uid
                    or held.st_gid != main_st.st_gid
                    or held.st_nlink != 1
                    or stat.S_IMODE(held.st_mode) & 0o022
                    or held.st_dev != version_st.st_dev
                    or held.st_size < 0):
                raise SystemExit("interrupted firmware artifact is not an owned partial copy")
        for name, fd, opened in interrupted:
            reject_mounts(); verify_ancestry()
            current = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            held = os.fstat(fd)
            if ((current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
                    or (held.st_dev, held.st_ino) != (opened.st_dev, opened.st_ino)
                    or not stat.S_ISREG(current.st_mode)
                    or current.st_uid != held.st_uid or held.st_uid != 0
                    or current.st_gid != held.st_gid or held.st_gid != 0
                    or current.st_nlink != held.st_nlink
                    or stat.S_IMODE(current.st_mode) != stat.S_IMODE(held.st_mode)
                    or current.st_size != held.st_size
                    or current.st_mtime_ns != held.st_mtime_ns
                    or current.st_ctime_ns != held.st_ctime_ns
                    or not identity_matches("main")
                    or not identity_matches("backup")
                    or not identity_matches("patched")):
                raise SystemExit("interrupted firmware artifact changed before cleanup")
            if remove:
                os.unlink(name, dir_fd=dfd)
                os.fsync(dfd)

    if action == "inspect-attempted":
        inspect_interrupted(stock_hash, True)
    elif action == "validate-attempted":
        inspect_interrupted(stock_hash, False)
    changed = False
    if action == "inspect":
        if hashes["backup"] is not None:
            if (hashes["backup"] == hashes["patched"]
                    or hashes["main"] not in (hashes["backup"], hashes["patched"])):
                raise SystemExit("ambiguous legacy firmware byte identities")
    elif action == "inspect-recorded":
        if hashes["main"] != stock_hash:
            raise SystemExit("recorded firmware main is not exact stock")
        if hashes["backup"] is not None and hashes["backup"] != stock_hash:
            raise SystemExit("recorded stock firmware sidecar changed")
        if hashes["patched"] is not None and hashes["patched"] != patched_hash:
            raise SystemExit("recorded patched firmware sidecar changed")
    elif action in ("inspect-attempted", "validate-attempted"):
        if (hashes["backup"] != stock_hash
                or hashes["patched"] != patched_hash
                or hashes["main"] not in (stock_hash, patched_hash)):
            raise SystemExit("attempted firmware recovery namespace changed")
    elif action == "restore-stock":
        if hashes["backup"] is not None and hashes["backup"] != stock_hash:
            raise SystemExit("stock firmware sidecar changed")
        if hashes["patched"] is not None and hashes["patched"] != patched_hash:
            raise SystemExit("patched firmware sidecar changed")
        if hashes["main"] not in (stock_hash, patched_hash):
            raise SystemExit("firmware main matches neither receipt identity")
        if desired == "stock" and hashes["main"] != stock_hash:
            raise SystemExit("stock firmware baseline changed without copy authority")
        if hashes["main"] == patched_hash:
            if hashes["backup"] != stock_hash or hashes["patched"] != patched_hash:
                raise SystemExit("cannot restore stock without the complete exact pair")
            changed = publish_from("backup", stock_hash)
            hashes["main"] = stock_hash
        elif ((hashes["backup"] is None) != (hashes["patched"] is None)
              and not allow_partial):
            raise SystemExit("partial firmware cleanup is not authorized")
    elif action == "restore-prestate":
        if hashes["backup"] != stock_hash or hashes["patched"] != patched_hash:
            raise SystemExit("firmware rollback sidecars changed")
        if hashes["main"] not in (stock_hash, patched_hash):
            raise SystemExit("firmware main changed before rollback")
        desired_hash = stock_hash if desired == "stock" else patched_hash
        label = "backup" if desired == "stock" else "patched"
        if hashes["main"] != desired_hash:
            changed = publish_from(label, desired_hash)
            hashes["main"] = desired_hash
    else:
        if stock_hash == "absent":
            if hashes["backup"] is not None or hashes["patched"] is not None:
                raise SystemExit("unrecorded firmware sidecar appeared")
        else:
            if hashes["main"] != stock_hash:
                raise SystemExit("firmware main is not exact recorded stock")
            if hashes["backup"] is not None and hashes["backup"] != stock_hash:
                raise SystemExit("stock firmware sidecar changed")
            if hashes["patched"] is not None and hashes["patched"] != patched_hash:
                raise SystemExit("patched firmware sidecar changed")
            for label in ("patched", "backup"):
                if hashes[label] is None:
                    continue
                reject_mounts(); verify_ancestry()
                if (not identity_matches("main")
                        or hashes["main"] != stock_hash
                        or not identity_matches(label)):
                    raise SystemExit("firmware sidecar changed before deletion")
                os.unlink(names[label], dir_fd=dfd)
                os.fsync(dfd)
                hashes[label] = None
    verify_final_namespace()
    print(hashes["main"])
    print(hashes["backup"] if hashes["backup"] is not None else "absent")
    print(hashes["patched"] if hashes["patched"] is not None else "absent")
    print("1" if changed else "0")
finally:
    for unused_name, fd, unused_st in locals().get("interrupted", []):
        os.close(fd)
    if new_fd >= 0:
        os.close(new_fd)
    if temp_name is not None:
        try:
            reject_mounts(); verify_ancestry()
            if temp_fd < 0 or temp_identity is None:
                raise SystemExit("firmware temp name was never bound to an owned descriptor")
            cleanup_snapshot = os.fstat(temp_fd)
            cleanup_path = os.stat(temp_name, dir_fd=dfd, follow_symlinks=False)
            if (not exact_stat(cleanup_path, cleanup_snapshot)
                    or (cleanup_snapshot.st_dev, cleanup_snapshot.st_ino) != temp_identity
                    or cleanup_snapshot.st_uid != 0 or cleanup_snapshot.st_gid != 0
                    or cleanup_snapshot.st_nlink != 1
                    or stat.S_IMODE(cleanup_snapshot.st_mode) & 0o022
                    or cleanup_snapshot.st_dev != version_st.st_dev):
                raise SystemExit("refusing to remove a changed firmware temp name")
            cleanup_hash = digest(temp_fd)
            cleanup_xattrs = xattrs(temp_fd)
            cleanup_held = os.fstat(temp_fd)
            cleanup_current = os.stat(temp_name, dir_fd=dfd, follow_symlinks=False)
            if (not exact_stat(cleanup_held, cleanup_snapshot)
                    or not exact_stat(cleanup_current, cleanup_snapshot)
                    or digest(temp_fd) != cleanup_hash
                    or xattrs(temp_fd) != cleanup_xattrs):
                raise SystemExit("refusing to remove a firmware temp changed during cleanup proof")
            cleanup_final_held = os.fstat(temp_fd)
            cleanup_final_path = os.stat(temp_name, dir_fd=dfd, follow_symlinks=False)
            if (not exact_stat(cleanup_final_held, cleanup_snapshot)
                    or not exact_stat(cleanup_final_path, cleanup_snapshot)):
                raise SystemExit("refusing to remove a firmware temp changed after cleanup proof")
            if temp_st is not None:
                if (temp_expected_xattrs is None or temp_expected_hash is None
                        or not exact_stat(cleanup_snapshot, temp_st)
                        or (temp_st.st_dev, temp_st.st_ino) != temp_identity
                        or cleanup_hash != temp_expected_hash
                        or cleanup_xattrs != temp_expected_xattrs):
                    raise SystemExit("refusing to remove a changed complete firmware temp")
            os.unlink(temp_name, dir_fd=dfd)
            os.fsync(dfd)
        except FileNotFoundError:
            pass
    if temp_fd >= 0:
        os.close(temp_fd)
    for fd, unused in fds.values():
        os.close(fd)
    os.close(dfd)
    os.close(nvidia_fd)
    os.close(firmware_fd)
PY
    )" || return 1
    mapfile -t values <<< "${output}"
    (( ${#values[@]} == 4 )) || return 1
    [[ "${values[0]}" =~ ^[a-f0-9]{64}$ && \
       "${values[1]}" =~ ^(absent|[a-f0-9]{64})$ && \
       "${values[2]}" =~ ^(absent|[a-f0-9]{64})$ && \
       "${values[3]}" =~ ^[01]$ ]] || return 1
    FIRMWARE_NAMESPACE_MAIN_HASH="${values[0]}"
    FIRMWARE_NAMESPACE_BACKUP_HASH="${values[1]}"
    FIRMWARE_NAMESPACE_PATCHED_HASH="${values[2]}"
    FIRMWARE_NAMESPACE_CHANGED="${values[3]}"
}

determine_firmware_prestate() {
    local version="$1"

    firmware_namespace_action "${version}" inspect || \
        die "Unsafe or ambiguous firmware namespace for ${version}"
    if [[ "${FIRMWARE_NAMESPACE_BACKUP_HASH}" == "absent" ]]; then
        [[ "${FIRMWARE_NAMESPACE_PATCHED_HASH}" == "absent" ]] || \
            die "Incomplete legacy firmware pair for ${version}"
        DETERMINED_FIRMWARE_PRESTATE="none"
        DETERMINED_FIRMWARE_STOCK_HASH="absent"
        DETERMINED_FIRMWARE_PATCHED_HASH="absent"
        return 0
    fi
    DETERMINED_FIRMWARE_STOCK_HASH="${FIRMWARE_NAMESPACE_BACKUP_HASH}"
    DETERMINED_FIRMWARE_PATCHED_HASH="${FIRMWARE_NAMESPACE_PATCHED_HASH}"
    if [[ "${FIRMWARE_NAMESPACE_MAIN_HASH}" == \
          "${DETERMINED_FIRMWARE_PATCHED_HASH}" ]]; then
        DETERMINED_FIRMWARE_PRESTATE="patched"
    elif [[ "${FIRMWARE_NAMESPACE_MAIN_HASH}" == \
            "${DETERMINED_FIRMWARE_STOCK_HASH}" ]]; then
        DETERMINED_FIRMWARE_PRESTATE="stock"
    else
        die "Firmware main for ${version} matches neither exact sidecar"
    fi
}

infer_orphan_firmware_prestate() {
    local version="$1"

    determine_firmware_prestate "${version}"
    if [[ "${DETERMINED_FIRMWARE_PRESTATE}" == "stock" ]]; then
        die "Cannot infer whether orphan recovery should retain stock or restore patched firmware for ${version}"
    fi
}

prepare_stock_firmware() {
    local version="$1"
    local allow_partial_stock="${2:-0}"
    local expected_stock_hash="${3:-absent}"
    local expected_patched_hash="${4:-absent}"
    local prestate="$5"
    local attempted="$6"
    local main="/lib/firmware/nvidia/${version}/gsp_tu10x.bin"

    touch_firmware_version "${version}"
    [[ "${prestate}" =~ ^(none|stock|patched)$ && "${attempted}" =~ ^[01]$ ]] || \
        die "Invalid firmware transaction authority for ${version}"
    [[ "${attempted}" == "0" || "${prestate}" == "patched" ]] || \
        die "Invalid firmware copy intent for ${version}"
    if [[ "${expected_stock_hash}" == "absent" || "${expected_patched_hash}" == "absent" ]]; then
        [[ "${expected_stock_hash}" == "absent" && \
           "${expected_patched_hash}" == "absent" ]] || \
            die "Incomplete firmware hash proof for ${version}"
    else
        [[ "${expected_stock_hash}" =~ ^[a-f0-9]{64}$ && \
           "${expected_patched_hash}" =~ ^[a-f0-9]{64}$ && \
           "${expected_stock_hash}" != "${expected_patched_hash}" ]] || \
            die "Invalid firmware hash proof for ${version}"
    fi
    if [[ -n "${FIRMWARE_STOCK_HASH_BY_VERSION[${version}]+x}" ]]; then
        [[ "${FIRMWARE_STOCK_HASH_BY_VERSION[${version}]}" == "${expected_stock_hash}" && \
           "${FIRMWARE_PATCHED_HASH_BY_VERSION[${version}]}" == "${expected_patched_hash}" && \
           "${FIRMWARE_PRESTATE_BY_VERSION[${version}]}" == "${prestate}" && \
           "${FIRMWARE_ATTEMPTED_BY_VERSION[${version}]}" == "${attempted}" ]] || \
            die "Conflicting firmware proofs for ${version}"
    else
        FIRMWARE_STOCK_HASH_BY_VERSION["${version}"]="${expected_stock_hash}"
        FIRMWARE_PATCHED_HASH_BY_VERSION["${version}"]="${expected_patched_hash}"
        FIRMWARE_PRESTATE_BY_VERSION["${version}"]="${prestate}"
        FIRMWARE_ATTEMPTED_BY_VERSION["${version}"]="${attempted}"
    fi
    if [[ "${expected_stock_hash}" == "absent" ]]; then
        [[ "${prestate}" == "none" && "${attempted}" == "0" ]] || \
            die "Firmware state without sidecars has invalid authority for ${version}"
        firmware_namespace_action "${version}" inspect || \
            die "Unsafe firmware namespace for ${version}"
        [[ "${FIRMWARE_NAMESPACE_BACKUP_HASH}" == "absent" && \
           "${FIRMWARE_NAMESPACE_PATCHED_HASH}" == "absent" ]] || \
            die "Unrecorded legacy firmware sidecars appeared for ${version}"
        return 0
    fi
    case "${prestate}:${attempted}" in
        stock:0|patched:1) ;;
        *) die "Firmware receipt lacks exact copy authority for ${version}" ;;
    esac
    firmware_namespace_action "${version}" restore-stock \
        "${expected_stock_hash}" "${expected_patched_hash}" "${prestate}" \
        "${allow_partial_stock}" || \
        die "Exact retained-dirfd stock firmware restoration failed for ${version}"
    [[ "${FIRMWARE_NAMESPACE_MAIN_HASH}" == "${expected_stock_hash}" ]] || \
        die "Stock firmware copy did not verify for ${version}"
    if [[ "${FIRMWARE_NAMESPACE_CHANGED}" == "1" ]]; then
        if (( REMOVE_TRANSACTION_ACTIVE == 1 )); then
            array_has "${main}" "${FIRMWARE_CHANGED_MAIN[@]}" || \
                FIRMWARE_CHANGED_MAIN+=("${main}")
        fi
        ok "Restored legacy stock firmware ${main} before initramfs generation"
    else
        info "Legacy firmware ${main} is already exact stock"
    fi
}

restore_pre_remove_firmware() {
    local version="$1" prestate="$2" attempted="$3" stock_hash="$4" patched_hash="$5"
    local desired_hash

    if [[ "${prestate}" == "none" ]]; then
        [[ "${attempted}" == "0" && "${stock_hash}" == "absent" && \
           "${patched_hash}" == "absent" ]] || return 1
        firmware_namespace_action "${version}" inspect || return 1
        [[ "${FIRMWARE_NAMESPACE_BACKUP_HASH}" == "absent" && \
           "${FIRMWARE_NAMESPACE_PATCHED_HASH}" == "absent" ]]
        return
    fi
    [[ "${prestate}" == "stock" || "${prestate}" == "patched" ]] || return 1
    [[ "${attempted}" == "0" || \
       ( "${attempted}" == "1" && "${prestate}" == "patched" ) ]] || return 1
    [[ "${stock_hash}" =~ ^[a-f0-9]{64}$ && \
       "${patched_hash}" =~ ^[a-f0-9]{64}$ && \
       "${stock_hash}" != "${patched_hash}" ]] || return 1
    desired_hash="${stock_hash}"
    [[ "${prestate}" == "patched" ]] && desired_hash="${patched_hash}"
    if [[ "${attempted}" == "0" ]]; then
        firmware_namespace_action "${version}" inspect || return 1
        [[ "${FIRMWARE_NAMESPACE_BACKUP_HASH}" == "${stock_hash}" && \
           "${FIRMWARE_NAMESPACE_PATCHED_HASH}" == "${patched_hash}" && \
           "${FIRMWARE_NAMESPACE_MAIN_HASH}" == "${desired_hash}" ]]
        return
    fi
    firmware_namespace_action "${version}" restore-prestate "${stock_hash}" \
        "${patched_hash}" "${prestate}" 0 && \
        [[ "${FIRMWARE_NAMESPACE_MAIN_HASH}" == "${desired_hash}" ]]
}

cleanup_firmware_sidecars() {
    local version stock_hash patched_hash

    for version in "${FIRMWARE_TOUCHED_VERSIONS[@]}"; do
        stock_hash="${FIRMWARE_STOCK_HASH_BY_VERSION[${version}]}"
        patched_hash="${FIRMWARE_PATCHED_HASH_BY_VERSION[${version}]}"
        if [[ "${stock_hash}" == "absent" ]]; then
            [[ "${patched_hash}" == "absent" ]] || \
                die "Incomplete absent firmware authority for ${version}"
            firmware_namespace_action "${version}" cleanup absent absent none 1 || \
                die "Unrecorded firmware sidecar state for ${version}"
            continue
        fi
        firmware_namespace_action "${version}" cleanup "${stock_hash}" \
            "${patched_hash}" none 1 || \
            die "Retained-dirfd firmware sidecar cleanup failed for ${version}"
        [[ "${FIRMWARE_NAMESPACE_MAIN_HASH}" == "${stock_hash}" && \
           "${FIRMWARE_NAMESPACE_BACKUP_HASH}" == "absent" && \
           "${FIRMWARE_NAMESPACE_PATCHED_HASH}" == "absent" ]] || \
            die "Firmware cleanup did not converge for ${version}"
    done
}

declare -A REMOVE_DATA=()
REMOVE_PHASE=""
REMOVE_KERNEL=""
REMOVE_VERSION=""
REMOVE_PATCHED_SRC=""
REMOVE_PATCHED_HASHES=""
REMOVE_STOCK_HASHES=""
REMOVE_BACKUP=""
REMOVE_DKMS_PRESTATE=""
REMOVE_DKMS_ATTEMPTED=""
REMOVE_DKMS_ARCH=""
REMOVE_DKMS_INSTALL_ATTEMPTED=""
REMOVE_DKMS_BUILT_HASHES=""
REMOVE_DKMS_PREINSTALL_MANIFEST=""
REMOVE_FIRMWARE_PRESTATE=""
REMOVE_FIRMWARE_ATTEMPTED=""
REMOVE_FIRMWARE_STOCK_HASH=""
REMOVE_FIRMWARE_PATCHED_HASH=""
REMOVE_DKMS_RECEIPT_COMMITTED=""

remove_state_path() {
    printf '%s/remove.%s.state\n' "${STATE_DIR}" "$1"
}

valid_dkms_preinstall_manifest() {
    local manifest="$1" entry path hash component
    local -A seen=()
    local -a entries=() components=()

    [[ "${manifest}" != "pending" ]] || return 1
    [[ "${manifest}" != "none" ]] || return 0
    [[ -n "${manifest}" && ${#manifest} -le 900000 ]] || return 1
    IFS=';' read -r -a entries <<< "${manifest}"
    (( ${#entries[@]} > 0 )) || return 1
    for entry in "${entries[@]}"; do
        [[ "${entry}" =~ ^([A-Za-z0-9._+/-]+)@(absent|[a-f0-9]{64})$ ]] || return 1
        path="${BASH_REMATCH[1]}"
        hash="${BASH_REMATCH[2]}"
        [[ "${path}" != /* && "${path}" != */ && "${path}" != *//* ]] || return 1
        IFS='/' read -r -a components <<< "${path}"
        for component in "${components[@]}"; do
            [[ -n "${component}" && "${component}" != "." && "${component}" != ".." ]] || return 1
        done
        [[ "${path##*/}" =~ ^(nvidia|nvidia-modeset|nvidia-uvm|nvidia-drm|nvidia-peermem)\.ko(\.gz|\.xz|\.zst)?$ ]] || return 1
        [[ -z "${seen[${path}]+x}" ]] || return 1
        seen["${path}"]="${hash}"
    done
}

valid_dkms_install_target_manifest() {
    local manifest="$1" entry path marker name
    local -A seen=()
    local -a entries=()

    valid_dkms_preinstall_manifest "${manifest}" || return 1
    [[ "${manifest}" != "none" ]] || return 1
    IFS=';' read -r -a entries <<< "${manifest}"
    (( ${#entries[@]} == ${#MODULE_FILES[@]} )) || return 1
    for entry in "${entries[@]}"; do
        path="${entry%@*}"
        marker="${entry##*@}"
        [[ "${marker}" == "absent" ]] || return 1
        name="${path##*/}"
        [[ "${name}" =~ ^(nvidia|nvidia-modeset|nvidia-uvm|nvidia-drm|nvidia-peermem)\.ko(\.gz|\.xz|\.zst)?$ ]] || return 1
        [[ -z "${seen[${name%%.ko*}]+x}" ]] || return 1
        seen["${name%%.ko*}"]=1
    done
    (( ${#seen[@]} == ${#MODULE_FILES[@]} ))
}

valid_stock_candidate_manifest() {
    local manifest="$1" entry path hash name stem
    local -A seen=()
    local -a entries=()

    valid_dkms_preinstall_manifest "${manifest}" || return 1
    [[ "${manifest}" != "none" ]] || return 1
    IFS=';' read -r -a entries <<< "${manifest}"
    (( ${#entries[@]} == ${#MODULE_FILES[@]} )) || return 1
    for entry in "${entries[@]}"; do
        path="${entry%@*}"
        hash="${entry##*@}"
        [[ "${hash}" =~ ^[a-f0-9]{64}$ && \
           "${path}" != *cmpunlocker* ]] || return 1
        name="${path##*/}"
        stem="${name%%.ko*}"
        [[ "${stem}" =~ ^(nvidia|nvidia-modeset|nvidia-uvm|nvidia-drm|nvidia-peermem)$ && \
           -z "${seen[${stem}]+x}" ]] || return 1
        seen["${stem}"]=1
    done
    (( ${#seen[@]} == ${#MODULE_FILES[@]} ))
}

parse_remove_state() {
    local path="$1"
    local nonce

    read_kv_state "${path}" \
        "format,phase,kernel,version,patched_srcversion,patched_sha256s,stock_sha256s,backup,dkms_prestate,dkms_attempted,dkms_arch,dkms_install_attempted,dkms_built_sha256s,dkms_preinstall_manifest,firmware_prestate,firmware_attempted,firmware_stock_sha256,firmware_patched_sha256,dkms_receipt_committed" \
        REMOVE_DATA || return 1
    [[ "${REMOVE_DATA[format]:-}" == "3" ]] || return 1
    [[ "${REMOVE_DATA[phase]:-}" == "removing" || "${REMOVE_DATA[phase]:-}" == "stock-ready" ]] || return 1
    valid_kernel "${REMOVE_DATA[kernel]:-}" || return 1
    valid_version "${REMOVE_DATA[version]:-}" || return 1
    [[ "${REMOVE_DATA[patched_srcversion]:-}" =~ ^[A-Fa-f0-9]+$ ]] || return 1
    [[ "${REMOVE_DATA[patched_sha256s]:-}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ ]] || return 1
    [[ "${REMOVE_DATA[stock_sha256s]:-}" == "pending" || \
       "${REMOVE_DATA[stock_sha256s]:-}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ ]] || return 1
    [[ "${REMOVE_DATA[dkms_prestate]:-}" =~ ^(none|absent|installed)$ && \
       "${REMOVE_DATA[dkms_attempted]:-}" =~ ^[01]$ && \
       "${REMOVE_DATA[dkms_install_attempted]:-}" =~ ^[01]$ ]] || return 1
    [[ "${REMOVE_DATA[dkms_arch]:-}" == "none" || \
       "${REMOVE_DATA[dkms_arch]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1
    [[ "${REMOVE_DATA[dkms_built_sha256s]:-}" == "pending" || \
       "${REMOVE_DATA[dkms_built_sha256s]:-}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ ]] || return 1
    [[ "${REMOVE_DATA[dkms_preinstall_manifest]:-}" == "pending" ]] || \
        valid_dkms_preinstall_manifest "${REMOVE_DATA[dkms_preinstall_manifest]:-}" || return 1
    [[ "${REMOVE_DATA[firmware_prestate]:-}" =~ ^(none|stock|patched)$ && \
       "${REMOVE_DATA[firmware_attempted]:-}" =~ ^[01]$ && \
       "${REMOVE_DATA[dkms_receipt_committed]:-}" =~ ^[01]$ ]] || return 1
    [[ "${REMOVE_DATA[firmware_attempted]}" == "0" || \
       "${REMOVE_DATA[firmware_prestate]}" == "patched" ]] || return 1
    [[ "${REMOVE_DATA[firmware_stock_sha256]:-}" =~ ^(absent|[a-f0-9]{64})$ && \
       "${REMOVE_DATA[firmware_patched_sha256]:-}" =~ ^(absent|[a-f0-9]{64})$ ]] || return 1
    if [[ "${REMOVE_DATA[firmware_prestate]}" == "none" ]]; then
        [[ "${REMOVE_DATA[firmware_stock_sha256]}" == "absent" && \
           "${REMOVE_DATA[firmware_patched_sha256]}" == "absent" ]] || return 1
    else
        [[ "${REMOVE_DATA[firmware_stock_sha256]}" != "absent" && \
           "${REMOVE_DATA[firmware_patched_sha256]}" != "absent" && \
           "${REMOVE_DATA[firmware_stock_sha256]}" != \
           "${REMOVE_DATA[firmware_patched_sha256]}" ]] || return 1
    fi
    [[ "${REMOVE_DATA[dkms_attempted]}" == "0" || \
       "${REMOVE_DATA[dkms_prestate]}" == "absent" ]] || return 1
    if [[ "${REMOVE_DATA[dkms_attempted]}" == "0" ]]; then
        [[ "${REMOVE_DATA[dkms_install_attempted]}" == "0" && \
           "${REMOVE_DATA[dkms_built_sha256s]}" == "pending" ]] || return 1
        if [[ "${REMOVE_DATA[dkms_prestate]}" == "absent" ]]; then
            [[ "${REMOVE_DATA[dkms_preinstall_manifest]}" == "pending" && \
               "${REMOVE_DATA[stock_sha256s]}" == "pending" ]] || return 1
        else
            if [[ "${REMOVE_DATA[dkms_preinstall_manifest]}" == "pending" ]]; then
                [[ "${REMOVE_DATA[stock_sha256s]}" == "pending" ]] || return 1
            else
                [[ "${REMOVE_DATA[stock_sha256s]}" != "pending" ]] && \
                    valid_stock_candidate_manifest \
                        "${REMOVE_DATA[dkms_preinstall_manifest]}" || return 1
            fi
        fi
    fi
    if [[ "${REMOVE_DATA[dkms_install_attempted]}" == "1" ]]; then
        [[ "${REMOVE_DATA[dkms_attempted]}" == "1" && \
           "${REMOVE_DATA[dkms_built_sha256s]}" != "pending" && \
           "${REMOVE_DATA[dkms_preinstall_manifest]}" != "pending" ]] && \
            valid_dkms_install_target_manifest \
                "${REMOVE_DATA[dkms_preinstall_manifest]}" || return 1
    fi
    if [[ "${REMOVE_DATA[dkms_attempted]}" == "1" && \
          "${REMOVE_DATA[dkms_install_attempted]}" == "0" ]]; then
        if [[ "${REMOVE_DATA[dkms_built_sha256s]}" == "pending" ]]; then
            [[ "${REMOVE_DATA[dkms_preinstall_manifest]}" == "pending" ]] || return 1
        else
            [[ "${REMOVE_DATA[dkms_preinstall_manifest]}" != "pending" ]] && \
                valid_dkms_install_target_manifest \
                    "${REMOVE_DATA[dkms_preinstall_manifest]}" || return 1
        fi
    fi
    if [[ "${REMOVE_DATA[dkms_attempted]}" == "1" && \
          "${REMOVE_DATA[dkms_built_sha256s]}" != "pending" ]]; then
        [[ "${REMOVE_DATA[stock_sha256s]}" != "pending" ]] || return 1
    fi
    if [[ "${REMOVE_DATA[dkms_prestate]}" != "absent" ]]; then
        [[ "${REMOVE_DATA[dkms_attempted]}" == "0" && \
           "${REMOVE_DATA[dkms_install_attempted]}" == "0" ]] || return 1
    fi
    if [[ "${REMOVE_DATA[dkms_prestate]}" == "none" ]]; then
        [[ "${REMOVE_DATA[dkms_arch]}" == "none" ]] || return 1
    else
        [[ "${REMOVE_DATA[dkms_arch]}" != "none" ]] || return 1
    fi
    [[ "${REMOVE_DATA[phase]}" == "stock-ready" || \
       "${REMOVE_DATA[dkms_receipt_committed]}" == "0" ]] || return 1
    if [[ "${REMOVE_DATA[phase]}" == "stock-ready" && \
          "${REMOVE_DATA[dkms_prestate]}" == "absent" ]]; then
        [[ "${REMOVE_DATA[dkms_attempted]}" == "1" && \
           "${REMOVE_DATA[dkms_install_attempted]}" == "1" ]] || return 1
    fi
    if [[ "${REMOVE_DATA[phase]}" == "stock-ready" && \
          "${REMOVE_DATA[firmware_prestate]}" == "patched" ]]; then
        [[ "${REMOVE_DATA[firmware_attempted]}" == "1" ]] || return 1
    fi
    if [[ "${REMOVE_DATA[phase]}" == "stock-ready" ]]; then
        [[ "${REMOVE_DATA[stock_sha256s]}" != "pending" ]] || return 1
    fi
    case "${REMOVE_DATA[backup]:-}" in
        "/lib/modules/.cmpunlocker.remove.${REMOVE_DATA[kernel]}."*) ;;
        *) return 1 ;;
    esac
    nonce="${REMOVE_DATA[backup]##*.}"
    [[ "${nonce}" =~ ^[A-Za-z0-9]{6}$ ]] || return 1
    REMOVE_PHASE="${REMOVE_DATA[phase]}"
    REMOVE_KERNEL="${REMOVE_DATA[kernel]}"
    REMOVE_VERSION="${REMOVE_DATA[version]}"
    REMOVE_PATCHED_SRC="${REMOVE_DATA[patched_srcversion]}"
    REMOVE_PATCHED_HASHES="${REMOVE_DATA[patched_sha256s]}"
    REMOVE_STOCK_HASHES="${REMOVE_DATA[stock_sha256s]}"
    REMOVE_BACKUP="${REMOVE_DATA[backup]}"
    REMOVE_DKMS_PRESTATE="${REMOVE_DATA[dkms_prestate]}"
    REMOVE_DKMS_ATTEMPTED="${REMOVE_DATA[dkms_attempted]}"
    REMOVE_DKMS_ARCH="${REMOVE_DATA[dkms_arch]}"
    REMOVE_DKMS_INSTALL_ATTEMPTED="${REMOVE_DATA[dkms_install_attempted]}"
    REMOVE_DKMS_BUILT_HASHES="${REMOVE_DATA[dkms_built_sha256s]}"
    REMOVE_DKMS_PREINSTALL_MANIFEST="${REMOVE_DATA[dkms_preinstall_manifest]}"
    REMOVE_FIRMWARE_PRESTATE="${REMOVE_DATA[firmware_prestate]}"
    REMOVE_FIRMWARE_ATTEMPTED="${REMOVE_DATA[firmware_attempted]}"
    REMOVE_FIRMWARE_STOCK_HASH="${REMOVE_DATA[firmware_stock_sha256]}"
    REMOVE_FIRMWARE_PATCHED_HASH="${REMOVE_DATA[firmware_patched_sha256]}"
    REMOVE_DKMS_RECEIPT_COMMITTED="${REMOVE_DATA[dkms_receipt_committed]}"
    [[ "${path}" == "$(remove_state_path "${REMOVE_KERNEL}")" ]]
}

write_remove_state() {
    local phase="$1" kernel="$2" version="$3" patched_src="$4" patched_hashes="$5" \
          backup="$6" dkms_prestate="$7" dkms_attempted="$8" \
          firmware_prestate="$9" firmware_attempted="${10}" \
          firmware_stock_hash="${11}" firmware_patched_hash="${12}" \
          dkms_receipt_committed="${13}" stock_hashes="${14}" \
          dkms_install_attempted="${15}" dkms_built_hashes="${16}" \
          dkms_preinstall_manifest="${17}" dkms_arch="${18}"
    durable_write_state "$(remove_state_path "${kernel}")" \
        "format=3" "phase=${phase}" "kernel=${kernel}" "version=${version}" \
        "patched_srcversion=${patched_src}" "patched_sha256s=${patched_hashes}" \
        "stock_sha256s=${stock_hashes}" "backup=${backup}" \
        "dkms_prestate=${dkms_prestate}" "dkms_attempted=${dkms_attempted}" \
        "dkms_arch=${dkms_arch}" \
        "dkms_install_attempted=${dkms_install_attempted}" \
        "dkms_built_sha256s=${dkms_built_hashes}" \
        "dkms_preinstall_manifest=${dkms_preinstall_manifest}" \
        "firmware_prestate=${firmware_prestate}" \
        "firmware_attempted=${firmware_attempted}" \
        "firmware_stock_sha256=${firmware_stock_hash}" \
        "firmware_patched_sha256=${firmware_patched_hash}" \
        "dkms_receipt_committed=${dkms_receipt_committed}" || \
        die "Could not durably write removal state for ${kernel}"
}

declare -A REMOVE_FORWARD_DATA=()
declare -a REMOVE_FORWARD_KERNELS=()
declare -a REMOVE_FORWARD_BACKUPS=()
declare -a DEFERRED_SCOPE_KERNELS=()
declare -a DEFERRED_SCOPE_VERSIONS=()
declare -a DEFERRED_FORWARD_FIRMWARE_TEMPS=()
REMOVE_FORWARD_PRESENT=0
DEFERRED_FORWARD_RECOVERY=0

parse_remove_forward() {
    local kernels backups i state_path nonce
    local -A seen=()

    read_kv_state "${REMOVE_FORWARD}" "format,kernels,backups" \
        REMOVE_FORWARD_DATA || return 1
    [[ "${REMOVE_FORWARD_DATA[format]:-}" == "1" ]] || return 1
    kernels="${REMOVE_FORWARD_DATA[kernels]:-}"
    backups="${REMOVE_FORWARD_DATA[backups]:-}"
    IFS=: read -r -a REMOVE_FORWARD_KERNELS <<< "${kernels}"
    IFS=: read -r -a REMOVE_FORWARD_BACKUPS <<< "${backups}"
    (( ${#REMOVE_FORWARD_KERNELS[@]} > 0 && \
       ${#REMOVE_FORWARD_KERNELS[@]} == ${#REMOVE_FORWARD_BACKUPS[@]} )) || return 1
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        valid_kernel "${REMOVE_FORWARD_KERNELS[$i]}" || return 1
        [[ -z "${seen[${REMOVE_FORWARD_KERNELS[$i]}]+x}" ]] || return 1
        seen["${REMOVE_FORWARD_KERNELS[$i]}"]=1
        case "${REMOVE_FORWARD_BACKUPS[$i]}" in
            "/lib/modules/.cmpunlocker.remove.${REMOVE_FORWARD_KERNELS[$i]}."*) ;;
            *) return 1 ;;
        esac
        nonce="${REMOVE_FORWARD_BACKUPS[$i]##*.}"
        [[ "${nonce}" =~ ^[A-Za-z0-9]{6}$ ]] || return 1
        state_path="$(remove_state_path "${REMOVE_FORWARD_KERNELS[$i]}")"
        parse_remove_state "${state_path}" || return 1
        [[ "${REMOVE_BACKUP}" == "${REMOVE_FORWARD_BACKUPS[$i]}" && \
           "${REMOVE_DKMS_RECEIPT_COMMITTED}" == "0" ]] || return 1
        case "${REMOVE_DKMS_PRESTATE}" in
            absent)
                [[ "${REMOVE_DKMS_ATTEMPTED}" == "1" && \
                   "${REMOVE_DKMS_BUILT_HASHES}" != "pending" && \
                   "${REMOVE_DKMS_PREINSTALL_MANIFEST}" != "pending" ]] && \
                    valid_dkms_install_target_manifest \
                        "${REMOVE_DKMS_PREINSTALL_MANIFEST}" || return 1
                ;;
            none|installed)
                [[ "${REMOVE_DKMS_ATTEMPTED}" == "0" && \
                   "${REMOVE_DKMS_INSTALL_ATTEMPTED}" == "0" && \
                   "${REMOVE_DKMS_BUILT_HASHES}" == "pending" && \
                   "${REMOVE_STOCK_HASHES}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ && \
                   "${REMOVE_DKMS_PREINSTALL_MANIFEST}" != "pending" ]] && \
                    valid_stock_candidate_manifest \
                        "${REMOVE_DKMS_PREINSTALL_MANIFEST}" || return 1
                ;;
            *) return 1 ;;
        esac
    done
    REMOVE_FORWARD_PRESENT=1
}

remove_forward_includes() {
    local kernel="$1" backup="$2" i
    (( REMOVE_FORWARD_PRESENT == 1 )) || return 1
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        [[ "${REMOVE_FORWARD_KERNELS[$i]}" == "${kernel}" && \
           "${REMOVE_FORWARD_BACKUPS[$i]}" == "${backup}" ]] && return 0
    done
    return 1
}

write_remove_forward() {
    local kernels backups i state_path

    (( ${#KERNELS[@]} > 0 && ${#KERNELS[@]} == ${#MODULE_BACKUPS[@]} )) || \
        die "Cannot bind forward removal to its kernel backups"
    [[ ! -e "${REMOVE_FORWARD}" && ! -L "${REMOVE_FORWARD}" ]] || \
        die "Forward removal marker already exists"
    for i in "${!KERNELS[@]}"; do
        state_path="$(remove_state_path "${KERNELS[$i]}")"
        parse_remove_state "${state_path}" && \
            [[ "${REMOVE_PHASE}" == "removing" && \
               "${REMOVE_BACKUP}" == "${MODULE_BACKUPS[$i]}" && \
               "${REMOVE_FIRMWARE_ATTEMPTED}" == "0" && \
               "${REMOVE_DKMS_INSTALL_ATTEMPTED}" == "0" && \
               "${REMOVE_DKMS_RECEIPT_COMMITTED}" == "0" && \
               "${REMOVE_STOCK_HASHES}" != "pending" && \
               -d "${MODULE_DIRS[$i]}" && ! -L "${MODULE_DIRS[$i]}" && \
               ! -e "${MODULE_BACKUPS[$i]}" && ! -L "${MODULE_BACKUPS[$i]}" ]] || \
            die "Removal state is not ready for the global forward barrier: ${state_path}"
        if [[ "${REMOVE_DKMS_PRESTATE}" == "absent" ]]; then
            [[ "${REMOVE_DKMS_ATTEMPTED}" == "1" && \
               "${REMOVE_DKMS_BUILT_HASHES}" != "pending" && \
               "${REMOVE_DKMS_PREINSTALL_MANIFEST}" != "pending" ]] && \
                valid_dkms_install_target_manifest \
                    "${REMOVE_DKMS_PREINSTALL_MANIFEST}" || \
                die "DKMS build is not durable before the forward barrier for ${KERNELS[$i]}"
        else
            [[ "${REMOVE_DKMS_ATTEMPTED}" == "0" ]] && \
                valid_stock_candidate_manifest \
                    "${REMOVE_DKMS_PREINSTALL_MANIFEST}" || \
                die "Unexpected DKMS mutation before the forward barrier for ${KERNELS[$i]}"
        fi
    done
    kernels="$(IFS=:; printf '%s' "${KERNELS[*]}")"
    backups="$(IFS=:; printf '%s' "${MODULE_BACKUPS[*]}")"
    durable_write_state_noreplace "${REMOVE_FORWARD}" \
        "format=1" "kernels=${kernels}" "backups=${backups}" || \
        die "Could not publish durable forward-only removal barrier"
    parse_remove_forward || die "Forward-only removal barrier failed read-back validation"
}

declare -A REMOVE_COMMIT_DATA=()
declare -a REMOVE_COMMIT_KERNELS=()
declare -a REMOVE_COMMIT_BACKUPS=()
REMOVE_COMMIT_PRESENT=0

parse_remove_commit() {
    local kernels backups i state_path nonce
    local -A seen=()

    read_kv_state "${REMOVE_COMMIT}" "format,kernels,backups" REMOVE_COMMIT_DATA || return 1
    [[ "${REMOVE_COMMIT_DATA[format]:-}" == "1" ]] || return 1
    kernels="${REMOVE_COMMIT_DATA[kernels]:-}"
    backups="${REMOVE_COMMIT_DATA[backups]:-}"
    IFS=: read -r -a REMOVE_COMMIT_KERNELS <<< "${kernels}"
    IFS=: read -r -a REMOVE_COMMIT_BACKUPS <<< "${backups}"
    (( ${#REMOVE_COMMIT_KERNELS[@]} > 0 && \
       ${#REMOVE_COMMIT_KERNELS[@]} == ${#REMOVE_COMMIT_BACKUPS[@]} )) || return 1
    for i in "${!REMOVE_COMMIT_KERNELS[@]}"; do
        valid_kernel "${REMOVE_COMMIT_KERNELS[$i]}" || return 1
        [[ -z "${seen[${REMOVE_COMMIT_KERNELS[$i]}]+x}" ]] || return 1
        seen["${REMOVE_COMMIT_KERNELS[$i]}"]=1
        case "${REMOVE_COMMIT_BACKUPS[$i]}" in
            "/lib/modules/.cmpunlocker.remove.${REMOVE_COMMIT_KERNELS[$i]}."*) ;;
            *) return 1 ;;
        esac
        nonce="${REMOVE_COMMIT_BACKUPS[$i]##*.}"
        [[ "${nonce}" =~ ^[A-Za-z0-9]{6}$ ]] || return 1
        state_path="$(remove_state_path "${REMOVE_COMMIT_KERNELS[$i]}")"
        parse_remove_state "${state_path}" || return 1
        [[ "${REMOVE_BACKUP}" == "${REMOVE_COMMIT_BACKUPS[$i]}" && \
           "${REMOVE_STOCK_HASHES}" != "pending" ]] || return 1
    done
    REMOVE_COMMIT_PRESENT=1
}

remove_commit_includes() {
    local kernel="$1" backup="$2" i
    (( REMOVE_COMMIT_PRESENT == 1 )) || return 1
    for i in "${!REMOVE_COMMIT_KERNELS[@]}"; do
        [[ "${REMOVE_COMMIT_KERNELS[$i]}" == "${kernel}" && \
           "${REMOVE_COMMIT_BACKUPS[$i]}" == "${backup}" ]] && return 0
    done
    return 1
}

write_remove_commit() {
    local kernels backups i state_path
    (( ${#KERNELS[@]} > 0 && ${#KERNELS[@]} == ${#MODULE_BACKUPS[@]} )) || \
        die "Cannot bind removal commit to its kernel backups"
    for i in "${!KERNELS[@]}"; do
        [[ "${STOCK_HASH_SETS[$i]}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ ]] || \
            die "Cannot commit an unbound stock payload set for ${KERNELS[$i]}"
        state_path="$(remove_state_path "${KERNELS[$i]}")"
        parse_remove_state "${state_path}" && \
            [[ "${REMOVE_PHASE}" == "removing" && \
               "${REMOVE_BACKUP}" == "${MODULE_BACKUPS[$i]}" && \
               "${REMOVE_STOCK_HASHES}" == "${STOCK_HASH_SETS[$i]}" ]] || \
            die "Removal state is not ready for global stock commit: ${state_path}"
    done
    kernels="$(IFS=:; printf '%s' "${KERNELS[*]}")"
    backups="$(IFS=:; printf '%s' "${MODULE_BACKUPS[*]}")"
    durable_write_state "${REMOVE_COMMIT}" \
        "format=1" "kernels=${kernels}" "backups=${backups}" || \
        die "Could not publish durable multi-kernel stock commit"
}

finalize_remove_commit_recovery() {
    local i state_path
    (( REMOVE_COMMIT_PRESENT == 1 )) || return 0
    for i in "${!REMOVE_COMMIT_KERNELS[@]}"; do
        [[ ! -e "${REMOVE_COMMIT_BACKUPS[$i]}" && \
           ! -L "${REMOVE_COMMIT_BACKUPS[$i]}" ]] || \
            die "Committed rollback backup was not cleaned: ${REMOVE_COMMIT_BACKUPS[$i]}"
        state_path="$(remove_state_path "${REMOVE_COMMIT_KERNELS[$i]}")"
        parse_remove_state "${state_path}" || die "Invalid committed removal state ${state_path}"
        [[ "${REMOVE_PHASE}" == "stock-ready" && \
           "${REMOVE_BACKUP}" == "${REMOVE_COMMIT_BACKUPS[$i]}" ]] || \
            die "Multi-kernel stock commit did not converge for ${REMOVE_COMMIT_KERNELS[$i]}"
    done
    durable_remove_file "${REMOVE_COMMIT}" || die "Could not finalize multi-kernel stock commit"
    REMOVE_COMMIT_PRESENT=0
}

ensure_recovery_tools() {
    [[ -n "${INITRAMFS_TOOL}" ]] || select_initramfs_tool || \
        die "No supported initramfs tool found; refusing an on-disk driver transition"
}

validate_forward_firmware() {
    local version="$1" prestate="$2" attempted="$3" stock_hash="$4" patched_hash="$5"
    local main="/lib/firmware/nvidia/${version}/gsp_tu10x.bin"
    local backup="${main}.cmpunlocker.bak" patched="${main}.cmpunlocker.patched"
    local main_hash

    [[ -s "${main}" && ! -L "${main}" ]] || return 1
    main_hash="$(sha256_regular "${main}")" || return 1
    case "${prestate}" in
        none)
            [[ "${attempted}" == "0" && "${stock_hash}" == "absent" && \
               "${patched_hash}" == "absent" && \
               ! -e "${backup}" && ! -L "${backup}" && \
               ! -e "${patched}" && ! -L "${patched}" ]]
            ;;
        stock)
            [[ "${attempted}" == "0" && "${stock_hash}" =~ ^[a-f0-9]{64}$ && \
               "${patched_hash}" =~ ^[a-f0-9]{64}$ && \
               "${stock_hash}" != "${patched_hash}" && \
               -s "${backup}" && ! -L "${backup}" && \
               -s "${patched}" && ! -L "${patched}" && \
               "$(sha256_regular "${backup}")" == "${stock_hash}" && \
               "$(sha256_regular "${patched}")" == "${patched_hash}" && \
               "${main_hash}" == "${stock_hash}" ]]
            ;;
        patched)
            [[ "${attempted}" =~ ^[01]$ && "${stock_hash}" =~ ^[a-f0-9]{64}$ && \
               "${patched_hash}" =~ ^[a-f0-9]{64}$ && \
               "${stock_hash}" != "${patched_hash}" && \
               -s "${backup}" && ! -L "${backup}" && \
               -s "${patched}" && ! -L "${patched}" && \
               "$(sha256_regular "${backup}")" == "${stock_hash}" && \
               "$(sha256_regular "${patched}")" == "${patched_hash}" ]] || return 1
            [[ "${main_hash}" == "${patched_hash}" || \
               ( "${attempted}" == "1" && "${main_hash}" == "${stock_hash}" ) ]]
            ;;
        *) return 1 ;;
    esac
}

forward_dkms_tuple() {
    local mode="$1" version="$2" kernel="$3" arch="$4" built_hashes="$5"
    local manifest="$6" live_cmp="$7" backup="$8" nonce

    [[ "${mode}" == "validate" || "${mode}" == "preflight" || \
       "${mode}" == "publish" ]] || return 1
    [[ "${built_hashes}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ ]] || return 1
    valid_dkms_install_target_manifest "${manifest}" || return 1
    nonce="${backup##*.}"
    [[ "${nonce}" =~ ^[A-Za-z0-9]{6}$ ]] || return 1
    python3 - "${mode}" "${DKMS_TREE}" "/lib/modules/${kernel}" nvidia \
        "${version}" "${kernel}" "${arch}" "${built_hashes}" "${manifest}" \
        "${live_cmp}" "${nonce}" "${MODULE_FILES[@]}" <<'PY'
import ctypes
import errno
import hashlib
import os
import pathlib
import re
import stat
import sys

mode, tree_arg, root_arg, module, version, kver, arch = sys.argv[1:8]
built_hashes = sys.argv[8].split(":")
encoded_manifest, excluded_arg, nonce = sys.argv[9:12]
module_files = sys.argv[12:]
suffixes = ("", ".gz", ".xz", ".zst")
if (mode not in ("validate", "preflight", "publish") or module != "nvidia"
        or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", kver) is None
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", arch) is None
        or re.fullmatch(r"[A-Za-z0-9]{6}", nonce) is None
        or len(module_files) != 5 or len(built_hashes) != len(module_files)
        or any(re.fullmatch(r"[a-f0-9]{64}", value) is None for value in built_hashes)):
    raise SystemExit("invalid forward DKMS authority")

def lexists(path):
    return os.path.lexists(path)

def digest_path(path):
    value = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0))
    try:
        with os.fdopen(os.dup(fd), "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
    finally:
        os.close(fd)
    return value.hexdigest()

def digest_at(dfd, name):
    value = hashlib.sha256()
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    try:
        with os.fdopen(os.dup(fd), "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
    finally:
        os.close(fd)
    return value.hexdigest()

def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                 | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def trusted_dir(path, device=None):
    st = os.lstat(path)
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022
            or (device is not None and st.st_dev != device)):
        raise SystemExit(f"unsafe DKMS directory: {path}")
    return st

def trusted_regular(path, device, expected_hash):
    st = os.lstat(path)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
            or stat.S_IMODE(st.st_mode) & 0o022 or st.st_dev != device
            or digest_path(path) != expected_hash):
        raise SystemExit(f"changed DKMS module payload: {path}")

def module_index(filename):
    for index, name in enumerate(module_files):
        if any(filename == name + suffix for suffix in suffixes):
            return index
    return None

def mount_points():
    points = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            fields = raw.rstrip(b"\n").split(b" ")
            if len(fields) < 5:
                raise SystemExit("malformed mountinfo")
            decoded = re.sub(rb"\\([0-7]{3})",
                             lambda match: bytes((int(match.group(1), 8),)),
                             fields[4])
            points.add(os.path.normpath(os.fsdecode(decoded)))
    return points

tree = pathlib.Path(tree_arg)
root_lexical = pathlib.Path(root_arg)
if not lexists(tree) or tree.resolve(strict=False) != tree:
    raise SystemExit("unsafe audited DKMS tree")
tree_st = trusted_dir(tree)
root = root_lexical.resolve(strict=True)
root_st = trusted_dir(root)
try:
    excluded_relative = pathlib.Path(excluded_arg).relative_to(root_lexical)
except ValueError:
    raise SystemExit("CMP exclusion escapes the kernel tree")
if ".." in excluded_relative.parts:
    raise SystemExit("CMP exclusion escapes the kernel tree")
excluded = root.joinpath(*excluded_relative.parts)

module_dir = tree / module
version_dir = module_dir / version
kernel_dir = version_dir / kver
base = kernel_dir / arch
built_dir = base / "module"
for required in (module_dir, version_dir, kernel_dir, base, built_dir):
    if not lexists(required):
        raise SystemExit(f"durable DKMS build disappeared: {required}")
    trusted_dir(required, tree_st.st_dev)
if lexists(version_dir / "build"):
    raise SystemExit("shared DKMS build workspace exists after a completed build")
temp_pattern = re.compile(rf"\.tmp_{re.escape(arch)}_[A-Za-z0-9]{{6}}")
for entry in os.scandir(kernel_dir):
    if entry.name.startswith(f".tmp_{arch}_"):
        if temp_pattern.fullmatch(entry.name) is None:
            raise SystemExit(f"unsafe DKMS build temporary: {entry.path}")
        raise SystemExit(f"DKMS build temporary remains after completed build: {entry.path}")

expected = {}
records = encoded_manifest.split(";")
if len(records) != len(module_files):
    raise SystemExit("target manifest is not an exact five-module set")
for record in records:
    try:
        relative, marker = record.rsplit("@", 1)
    except ValueError:
        raise SystemExit("malformed DKMS target manifest")
    pure = pathlib.PurePosixPath(relative)
    if (marker != "absent" or pure.is_absolute() or ".." in pure.parts
            or "." in pure.parts or pure.parent.parts != ("updates", "dkms")):
        raise SystemExit("DKMS target manifest escaped its exact destination")
    index = module_index(pure.name)
    if index is None or index in expected:
        raise SystemExit("DKMS target manifest has an ambiguous module mapping")
    expected[index] = pure
if set(expected) != set(range(len(module_files))):
    raise SystemExit("DKMS target manifest is incomplete")

expected_names = set()
built_paths = {}
for index, expected_hash in enumerate(built_hashes):
    filename = expected[index].name
    path = built_dir / filename
    if not lexists(path):
        raise SystemExit(f"built DKMS payload disappeared: {path}")
    trusted_regular(path, tree_st.st_dev, expected_hash)
    built_paths[index] = path
    expected_names.add(filename)
for entry in os.scandir(built_dir):
    path = pathlib.Path(entry.path)
    if entry.name in expected_names:
        continue
    if entry.name != "Module.symvers":
        raise SystemExit(f"unexpected object in durable DKMS build: {path}")
    st = os.lstat(path)
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
            or stat.S_IMODE(st.st_mode) & 0o022 or st.st_dev != tree_st.st_dev):
        raise SystemExit("unsafe durable DKMS Module.symvers")

original_root = module_dir / "original_module"
original_kver = original_root / kver
original_arch = original_kver / arch
if lexists(original_root):
    trusted_dir(original_root, tree_st.st_dev)
if lexists(original_kver):
    trusted_dir(original_kver, tree_st.st_dev)
if lexists(original_arch):
    raise SystemExit(f"unexpected DKMS original-module residue: {original_arch}")

mounted = mount_points()
target_parent = root / "updates" / "dkms"
current = root
parent_missing = False
for component in ("updates", "dkms"):
    current /= component
    if parent_missing or not lexists(current):
        parent_missing = True
        continue
    trusted_dir(current, root_st.st_dev)
    if os.path.normpath(os.fspath(current)) in mounted:
        raise SystemExit(f"nested mount at DKMS target parent: {current}")

allowed_names = {name + suffix for name in module_files for suffix in suffixes}
seen = set()
for current_name, dirs, files in os.walk(root, topdown=True, followlinks=False):
    current_path = pathlib.Path(current_name)
    cst = trusted_dir(current_path, root_st.st_dev)
    if current_path != root and os.path.normpath(os.fspath(current_path)) in mounted:
        raise SystemExit(f"nested mount in kernel module tree: {current_path}")
    kept = []
    for dirname in dirs:
        child = current_path / dirname
        if child == excluded:
            continue
        if dirname in allowed_names:
            raise SystemExit(f"unexpected NVIDIA directory object: {child}")
        dst = os.lstat(child)
        if stat.S_ISLNK(dst.st_mode):
            continue
        if (not stat.S_ISDIR(dst.st_mode) or dst.st_uid != 0 or dst.st_gid != 0
                or stat.S_IMODE(dst.st_mode) & 0o022 or dst.st_dev != root_st.st_dev
                or os.path.normpath(os.fspath(child)) in mounted):
            raise SystemExit(f"unsafe directory in kernel module tree: {child}")
        kept.append(dirname)
    dirs[:] = kept
    for filename in files:
        index = module_index(filename)
        if index is None:
            continue
        path = current_path / filename
        wanted = root.joinpath(*expected[index].parts)
        st = os.lstat(path)
        if (path != wanted or index in seen or not stat.S_ISREG(st.st_mode)
                or stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
                or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) & 0o022
                or st.st_dev != root_st.st_dev
                or digest_path(path) != built_hashes[index]):
            raise SystemExit(f"unowned NVIDIA module object: {path}")
        seen.add(index)

active = module_dir / f"kernel-{kver}-{arch}"
active_target = f"{version}/{kver}/{arch}"
if lexists(active):
    ast = os.lstat(active)
    if (not stat.S_ISLNK(ast.st_mode) or ast.st_uid != 0 or ast.st_gid != 0
            or ast.st_nlink != 1 or os.readlink(active) != active_target):
        raise SystemExit(f"unsafe DKMS active link: {active}")

temp_names = {f".cmpunlocker-forward.{nonce}.{expected[i].name}.tmp": i
              for i in expected}
found_temps = False
if lexists(target_parent):
    for entry in os.scandir(target_parent):
        if not entry.name.startswith(".cmpunlocker-forward."):
            continue
        if entry.name not in temp_names:
            raise SystemExit(f"unbound forward-install temporary: {entry.path}")
        found_temps = True
        index = temp_names[entry.name]
        tst = os.lstat(entry.path)
        bst = os.lstat(built_paths[index])
        if (not stat.S_ISREG(tst.st_mode) or stat.S_ISLNK(tst.st_mode)
                or tst.st_uid != 0 or tst.st_gid != 0 or tst.st_nlink != 1
                or stat.S_IMODE(tst.st_mode) not in (0o600, 0o644)
                or tst.st_dev != root_st.st_dev or tst.st_size > bst.st_size):
            raise SystemExit(f"unsafe forward-install temporary: {entry.path}")
        with open(entry.path, "rb") as left, open(built_paths[index], "rb") as right:
            remaining = tst.st_size
            while remaining:
                count = min(1024 * 1024, remaining)
                if left.read(count) != right.read(count):
                    raise SystemExit(f"changed forward-install temporary: {entry.path}")
                remaining -= count

if mode == "validate":
    if seen or lexists(active) or found_temps:
        raise SystemExit("DKMS tuple publication began before install intent")
    for path in built_paths.values():
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    symvers = built_dir / "Module.symvers"
    if lexists(symvers):
        fd = os.open(symvers, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    for directory in (built_dir, base, kernel_dir, version_dir, module_dir, tree):
        fsync_dir(directory)
    raise SystemExit(0)
if mode == "preflight":
    raise SystemExit(0)

libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    raise SystemExit("renameat2 is required for no-overwrite DKMS publication")
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                      ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
RENAME_NOREPLACE = 1

# Create only the exact stock destination after the durable global forward
# barrier.  Missing directories are now part of the desired final state and
# are never rolled back.
parent_fd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
try:
    for component in ("updates", "dkms"):
        created = False
        try:
            child_fd = os.open(component, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                               | getattr(os, "O_CLOEXEC", 0)
                               | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        except FileNotFoundError:
            old_umask = os.umask(0)
            try:
                os.mkdir(component, 0o755, dir_fd=parent_fd)
            finally:
                os.umask(old_umask)
            created = True
            os.fsync(parent_fd)
            child_fd = os.open(component, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                               | getattr(os, "O_CLOEXEC", 0)
                               | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        cst = os.fstat(child_fd)
        if (not stat.S_ISDIR(cst.st_mode) or cst.st_uid != 0 or cst.st_gid != 0
                or stat.S_IMODE(cst.st_mode) & 0o022 or cst.st_dev != root_st.st_dev):
            os.close(child_fd)
            raise SystemExit(f"unsafe created DKMS target directory: {component}")
        if created and stat.S_IMODE(cst.st_mode) != 0o755:
            os.close(child_fd)
            raise SystemExit(f"DKMS target directory mode is not 0755: {component}")
        os.close(parent_fd)
        parent_fd = child_fd

    # A cut can leave only our exact, marker-bound prefix copy.  Validate it
    # above, discard it durably, and restart that one file.
    for temp_name in temp_names:
        try:
            os.unlink(temp_name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
    os.fsync(parent_fd)

    def validate_target(index):
        filename = expected[index].name
        try:
            st = os.stat(filename, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return False
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
                or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) & 0o022
                or st.st_dev != root_st.st_dev
                or digest_at(parent_fd, filename) != built_hashes[index]):
            raise SystemExit(f"changed DKMS target: {target_parent / filename}")
        return True

    for index in range(len(module_files)):
        if validate_target(index):
            continue
        filename = expected[index].name
        temp_name = f".cmpunlocker-forward.{nonce}.{filename}.tmp"
        source_fd = os.open(built_paths[index], os.O_RDONLY
                            | getattr(os, "O_CLOEXEC", 0)
                            | getattr(os, "O_NOFOLLOW", 0))
        temp_fd = -1
        try:
            source_st = os.fstat(source_fd)
            if (not stat.S_ISREG(source_st.st_mode) or source_st.st_uid != 0
                    or source_st.st_gid != 0 or source_st.st_nlink != 1
                    or source_st.st_dev != tree_st.st_dev):
                raise SystemExit("built DKMS payload changed before copy")
            temp_fd = os.open(temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                              | getattr(os, "O_CLOEXEC", 0)
                              | getattr(os, "O_NOFOLLOW", 0), 0o600,
                              dir_fd=parent_fd)
            os.fchown(temp_fd, 0, 0)
            while True:
                block = os.read(source_fd, 1024 * 1024)
                if not block:
                    break
                view = memoryview(block)
                while view:
                    written = os.write(temp_fd, view)
                    view = view[written:]
            os.fchmod(temp_fd, 0o644)
            os.fsync(temp_fd)
        finally:
            os.close(source_fd)
            if temp_fd >= 0:
                os.close(temp_fd)
        result = renameat2(parent_fd, os.fsencode(temp_name), parent_fd,
                           os.fsencode(filename), RENAME_NOREPLACE)
        if result != 0:
            error = ctypes.get_errno()
            if error != errno.EEXIST:
                raise OSError(error, os.strerror(error), filename)
            if not validate_target(index):
                raise SystemExit(f"DKMS target collision: {target_parent / filename}")
            os.unlink(temp_name, dir_fd=parent_fd)
        os.fsync(parent_fd)
        if not validate_target(index):
            raise SystemExit(f"DKMS target publication failed: {target_parent / filename}")
finally:
    os.close(parent_fd)

if not lexists(active):
    module_fd = os.open(module_dir, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        try:
            os.symlink(active_target, active.name, dir_fd=module_fd)
        except FileExistsError:
            pass
        os.fsync(module_fd)
    finally:
        os.close(module_fd)
ast = os.lstat(active)
if (not stat.S_ISLNK(ast.st_mode) or ast.st_uid != 0 or ast.st_gid != 0
        or ast.st_nlink != 1 or os.readlink(active) != active_target):
    raise SystemExit("DKMS active-link publication failed")
for index in range(len(module_files)):
    target = root.joinpath(*expected[index].parts)
    trusted_regular(target, root_st.st_dev, built_hashes[index])
fsync_dir(module_dir)
PY
}

verify_dkms_built_payload_hashes() {
    local version="$1" kernel="$2" arch="$3" expected="$4"
    local directory="${DKMS_TREE}/nvidia/${version}/${kernel}/${arch}/module"
    local i suffix candidate payload
    local -a matches=() hashes=()

    [[ "${expected}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ && \
       -d "${directory}" && ! -L "${directory}" ]] || return 1
    for i in "${!MODULE_FILES[@]}"; do
        matches=()
        for suffix in '' .gz .xz .zst; do
            candidate="${directory}/${MODULE_FILES[$i]}${suffix}"
            [[ -e "${candidate}" || -L "${candidate}" ]] && matches+=("${candidate}")
        done
        (( ${#matches[@]} == 1 )) || return 1
        candidate="${matches[0]}"
        [[ -f "${candidate}" && ! -L "${candidate}" && \
           "$(stat -c '%u:%g:%h' -- "${candidate}" 2>/dev/null)" == "0:0:1" ]] || \
            return 1
        payload="$(module_payload_sha256 "${candidate}")" || return 1
        [[ "${payload}" =~ ^[a-f0-9]{64}$ ]] || return 1
        hashes+=("${payload}")
    done
    [[ "$(IFS=:; printf '%s' "${hashes[*]}")" == "${expected}" ]]
}

DKMS_BUILT_SIGNATURE_MODE=""
DKMS_BUILT_SIGNATURE_IDENTITY=""
module_signature_identity() {
    local module="$1" sig_id signer sig_key sig_hashalgo value

    sig_id="$(modinfo -F sig_id -- "${module}" 2>/dev/null)" || return 1
    signer="$(modinfo -F signer -- "${module}" 2>/dev/null)" || return 1
    sig_key="$(modinfo -F sig_key -- "${module}" 2>/dev/null)" || return 1
    sig_hashalgo="$(modinfo -F sig_hashalgo -- "${module}" 2>/dev/null)" || return 1
    for value in "${sig_id}" "${signer}" "${sig_key}" "${sig_hashalgo}"; do
        [[ "${value}" != *$'\n'* && "${value}" != *'|'* && \
           "${value}" != *$'\r'* ]] || return 1
    done
    if [[ -z "${sig_id}${signer}${sig_key}${sig_hashalgo}" ]]; then
        printf 'unsigned|\n'
    elif [[ -n "${sig_id}" && -n "${signer}" && -n "${sig_key}" && \
            -n "${sig_hashalgo}" && "${sig_id}" == "PKCS#7" && \
            "${sig_key}" =~ ^[A-Fa-f0-9:]+$ && \
            "${sig_hashalgo}" =~ ^[A-Za-z0-9_-]+$ ]]; then
        printf 'signed|%s|%s|%s|%s\n' \
            "${sig_id}" "${signer}" "${sig_key}" "${sig_hashalgo}"
    else
        return 1
    fi
}

capture_dkms_built_signature_identity() {
    local version="$1" kernel="$2" arch="$3"
    local directory="${DKMS_TREE}/nvidia/${version}/${kernel}/${arch}/module"
    local i suffix candidate identity common=""
    local -a matches=()

    DKMS_BUILT_SIGNATURE_MODE=""
    DKMS_BUILT_SIGNATURE_IDENTITY=""
    [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
    for i in "${!MODULE_FILES[@]}"; do
        matches=()
        for suffix in '' .gz .xz .zst; do
            candidate="${directory}/${MODULE_FILES[$i]}${suffix}"
            [[ -e "${candidate}" || -L "${candidate}" ]] && matches+=("${candidate}")
        done
        (( ${#matches[@]} == 1 )) || return 1
        identity="$(module_signature_identity "${matches[0]}")" || return 1
        if [[ -z "${common}" ]]; then
            common="${identity}"
        else
            [[ "${identity}" == "${common}" ]] || return 1
        fi
    done
    case "${common}" in
        unsigned\|)
            DKMS_BUILT_SIGNATURE_MODE=unsigned
            DKMS_BUILT_SIGNATURE_IDENTITY="${common}"
            ;;
        signed\|*)
            DKMS_BUILT_SIGNATURE_MODE=signed
            DKMS_BUILT_SIGNATURE_IDENTITY="${common}"
            ;;
        *) return 1 ;;
    esac
}

validate_dkms_built_signature_policy() {
    local version="$1" kernel="$2" arch="$3"

    capture_dkms_built_signature_identity "${version}" "${kernel}" "${arch}" || return 1
    if [[ "${DKMS_BUILT_SIGNATURE_MODE}" == "unsigned" ]]; then
        validate_dkms_signing_preflight "${kernel}" && \
            [[ "${DKMS_SIGNING_MODE}" == "disabled" ]] || return 1
    fi
}

verify_published_dkms_signature_identity() {
    local kernel="$1" manifest="$2" expected_mode="$3" expected_identity="$4"
    local i entry path marker candidate identity
    local -a entries=() matches=()

    [[ "${expected_mode}" == "signed" || "${expected_mode}" == "unsigned" ]] || return 1
    valid_dkms_install_target_manifest "${manifest}" || return 1
    IFS=';' read -r -a entries <<< "${manifest}"
    for i in "${!MODULE_FILES[@]}"; do
        matches=()
        for entry in "${entries[@]}"; do
            path="${entry%@*}"
            marker="${entry##*@}"
            [[ "${marker}" == "absent" ]] || return 1
            case "${path##*/}" in
                "${MODULE_FILES[$i]}"|"${MODULE_FILES[$i]}.gz"|\
                "${MODULE_FILES[$i]}.xz"|"${MODULE_FILES[$i]}.zst")
                    matches+=("/lib/modules/${kernel}/${path}")
                    ;;
            esac
        done
        (( ${#matches[@]} == 1 )) || return 1
        candidate="${matches[0]}"
        [[ -f "${candidate}" && ! -L "${candidate}" ]] || return 1
        identity="$(module_signature_identity "${candidate}")" || return 1
        [[ "${identity}" == "${expected_identity}" ]] || return 1
    done
}

safe_remove_backup() {
    local path="$1" kernel="$2" version="$3" patched_hashes="$4"
    local action="${5:-remove}" nonce
    case "${path}" in
        "/lib/modules/.cmpunlocker.remove.${kernel}."*) ;;
        *) return 1 ;;
    esac
    nonce="${path##*.}"
    [[ "${action}" == "validate" || "${action}" == "remove" ]] || return 1
    [[ "${nonce}" =~ ^[A-Za-z0-9]{6}$ && \
       "${patched_hashes}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ ]] || return 1
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        return 0
    fi
    [[ -d "${path}" && ! -L "${path}" ]] || return 1
    python3 - "${path}" "${version}" "${patched_hashes}" "${action}" \
        "${MODULE_FILES[@]}" <<'PY' || return 1
import hashlib
import os
import pathlib
import re
import stat
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
hashes = sys.argv[3].split(":")
action = sys.argv[4]
module_files = sys.argv[5:]
if (re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None
        or action not in ("validate", "remove")
        or len(module_files) != 5 or len(hashes) != len(module_files)
        or any(re.fullmatch(r"[a-f0-9]{64}", value) is None for value in hashes)):
    raise SystemExit("invalid backup cleanup authority")
root = pathlib.Path("/lib/modules").resolve(strict=True)
resolved = path.resolve(strict=True)
try:
    relative = resolved.relative_to(root)
except ValueError:
    raise SystemExit("backup escapes /lib/modules")
if len(relative.parts) != 1 or resolved.name != path.name:
    raise SystemExit("backup is not a direct /lib/modules child")
rst = os.lstat(root)
st = os.lstat(resolved)
if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != 0 or st.st_gid != 0
        or stat.S_IMODE(st.st_mode) & 0o022 or st.st_dev != rst.st_dev):
    raise SystemExit("unsafe removal backup")

def reject_mounts():
    exact = os.path.normpath(os.fspath(resolved))
    prefix = exact + os.sep
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            fields = raw.rstrip(b"\n").split(b" ")
            if len(fields) < 5:
                raise SystemExit("malformed mountinfo")
            decoded = re.sub(rb"\\([0-7]{3})",
                             lambda match: bytes((int(match.group(1), 8),)),
                             fields[4])
            mount = os.path.normpath(os.fsdecode(decoded))
            if mount == exact or mount.startswith(prefix):
                raise SystemExit(f"nested mount blocks backup cleanup: {mount}")

def digest_at(dfd, name):
    value = hashlib.sha256()
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    try:
        with os.fdopen(os.dup(fd), "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
    finally:
        os.close(fd)
    return value.hexdigest()

reject_mounts()
expected = {name: value for name, value in zip(module_files, hashes)}
allowed = set(expected) | {"driver_version"}
dfd = os.open(resolved, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
              | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
try:
    opened = os.fstat(dfd)
    if ((opened.st_dev, opened.st_ino) != (st.st_dev, st.st_ino)
            or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != 0
            or opened.st_gid != 0 or stat.S_IMODE(opened.st_mode) & 0o022):
        raise SystemExit("removal backup changed before descriptor acquisition")
    # Once dfd is open, a later mount over the pathname cannot redirect any
    # unlinkat below.  Re-read mountinfo after acquisition and validate every
    # remaining leaf through that same descriptor.
    reject_mounts()
    names = sorted(entry.name for entry in os.scandir(dfd))
    for name in names:
        if name not in allowed:
            raise SystemExit(f"unowned object in removal backup: {resolved / name}")
        est = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if (not stat.S_ISREG(est.st_mode) or est.st_uid != 0 or est.st_gid != 0
                or est.st_nlink != 1 or stat.S_IMODE(est.st_mode) & 0o022
                or est.st_dev != rst.st_dev):
            raise SystemExit(f"unsafe object in removal backup: {resolved / name}")
        if name == "driver_version":
            fd = os.open(name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                         | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
            try:
                fst = os.fstat(fd)
                if fst.st_size > 4096:
                    raise SystemExit("oversized removal-backup driver version")
                raw = os.read(fd, 4097)
            finally:
                os.close(fd)
            try:
                recorded = raw.decode("ascii").strip()
            except UnicodeDecodeError:
                raise SystemExit("invalid removal-backup driver version")
            if recorded != version:
                raise SystemExit("changed removal-backup driver version")
        elif digest_at(dfd, name) != expected[name]:
            raise SystemExit(f"changed module in removal backup: {resolved / name}")

    # The backup is a flat, exact six-object namespace.  Unlinking the
    # validated remainder one leaf at a time makes a hard cut retryable.
    if action == "validate":
        raise SystemExit(0)
    for name in names:
        os.unlink(name, dir_fd=dfd)
        os.fsync(dfd)
finally:
    os.close(dfd)
rfd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
              | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
try:
    reject_mounts()
    final = os.stat(resolved.name, dir_fd=rfd, follow_symlinks=False)
    if ((final.st_dev, final.st_ino) != (st.st_dev, st.st_ino)
            or not stat.S_ISDIR(final.st_mode)):
        raise SystemExit("removal backup path changed before directory removal")
    os.rmdir(resolved.name, dir_fd=rfd)
    os.fsync(rfd)
finally:
    os.close(rfd)
PY
    [[ "${action}" == "validate" ]] && return 0
    [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
}

recover_forward_transaction() {
    local action="${1:-recover}"
    local i kernel state_path live backup parse_rc mode current_hash phase_to_write
    local all_firmware_attempted
    local -a versions=() cores=() patched_hashes=() stock_hashes=()
    local -a dkms_prestates=() dkms_attempted=() dkms_arches=()
    local -a dkms_install_attempted=() dkms_built_hashes=() dkms_manifests=()
    local -a firmware_prestates=() firmware_attempted=() firmware_stock_hashes=()
    local -a firmware_patched_hashes=() receipt_committed=() phases=()
    local -A bound=() firmware_proofs=() handled_versions=() scope_seen=()

    [[ "${action}" == "recover" || "${action}" == "validate" ]] || \
        die "Invalid forward recovery action ${action}"
    if [[ "${action}" == "validate" ]]; then
        DEFERRED_SCOPE_KERNELS=()
        DEFERRED_SCOPE_VERSIONS=()
        DEFERRED_FORWARD_FIRMWARE_TEMPS=()
    fi

    parse_remove_forward || die "Invalid forward-only removal marker ${REMOVE_FORWARD}"
    [[ ! -e "${REMOVE_COMMIT}" && ! -L "${REMOVE_COMMIT}" ]] || \
        die "Forward and legacy removal commit markers coexist; preserving both for review"
    ensure_recovery_tools

    # Snapshot every marker-bound state before any mutation.  Later writes are
    # monotonic updates to these exact records; the global marker never changes.
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        kernel="${REMOVE_FORWARD_KERNELS[$i]}"
        backup="${REMOVE_FORWARD_BACKUPS[$i]}"
        bound["${kernel}"]="${backup}"
        state_path="$(remove_state_path "${kernel}")"
        parse_remove_state "${state_path}" || die "Invalid forward removal state ${state_path}"
        [[ "${REMOVE_BACKUP}" == "${backup}" ]] || \
            die "Forward marker no longer binds ${state_path}"
        phases[$i]="${REMOVE_PHASE}"
        versions[$i]="${REMOVE_VERSION}"
        cores[$i]="${REMOVE_PATCHED_SRC}"
        patched_hashes[$i]="${REMOVE_PATCHED_HASHES}"
        stock_hashes[$i]="${REMOVE_STOCK_HASHES}"
        dkms_prestates[$i]="${REMOVE_DKMS_PRESTATE}"
        dkms_attempted[$i]="${REMOVE_DKMS_ATTEMPTED}"
        dkms_arches[$i]="${REMOVE_DKMS_ARCH}"
        dkms_install_attempted[$i]="${REMOVE_DKMS_INSTALL_ATTEMPTED}"
        dkms_built_hashes[$i]="${REMOVE_DKMS_BUILT_HASHES}"
        dkms_manifests[$i]="${REMOVE_DKMS_PREINSTALL_MANIFEST}"
        firmware_prestates[$i]="${REMOVE_FIRMWARE_PRESTATE}"
        firmware_attempted[$i]="${REMOVE_FIRMWARE_ATTEMPTED}"
        firmware_stock_hashes[$i]="${REMOVE_FIRMWARE_STOCK_HASH}"
        firmware_patched_hashes[$i]="${REMOVE_FIRMWARE_PATCHED_HASH}"
        receipt_committed[$i]="${REMOVE_DKMS_RECEIPT_COMMITTED}"
        if [[ "${action}" == "validate" ]]; then
            DEFERRED_SCOPE_KERNELS+=("${kernel}")
            DEFERRED_SCOPE_VERSIONS+=("${REMOVE_VERSION}")
            scope_seen["${kernel}"]=1
        fi
    done

    # The marker must own every unfinished module/state object.  Completed
    # stock-ready states from an older transaction may coexist, but no second
    # removing state, live CMP set, or rollback backup may escape this set.
    for backup in /lib/modules/.cmpunlocker.remove.*; do
        kernel="${backup##*/}"
        kernel="${kernel#.cmpunlocker.remove.}"
        kernel="${kernel%.*}"
        [[ -n "${bound[${kernel}]+x}" && "${bound[${kernel}]}" == "${backup}" ]] || \
            die "Unbound rollback backup exists during forward recovery: ${backup}"
    done
    for live in /lib/modules/*/updates/cmpunlocker; do
        kernel="${live#/lib/modules/}"
        kernel="${kernel%%/*}"
        [[ -n "${bound[${kernel}]+x}" ]] || \
            die "Unbound live CMP set exists during forward recovery: ${live}"
    done
    for state_path in "${STATE_DIR}"/remove.*.state; do
        parse_remove_state "${state_path}" || die "Invalid removal state ${state_path}"
        if [[ "${REMOVE_PHASE}" == "removing" ]]; then
            [[ -n "${bound[${REMOVE_KERNEL}]+x}" && \
               "${bound[${REMOVE_KERNEL}]}" == "${REMOVE_BACKUP}" ]] || \
                die "Unbound removing state exists during forward recovery: ${state_path}"
        elif [[ "${action}" == "validate" && \
                -z "${scope_seen[${REMOVE_KERNEL}]+x}" ]]; then
            DEFERRED_SCOPE_KERNELS+=("${REMOVE_KERNEL}")
            DEFERRED_SCOPE_VERSIONS+=("${REMOVE_VERSION}")
            scope_seen["${REMOVE_KERNEL}"]=1
        fi
    done

    # Complete read-only preflight across every kernel before copying firmware,
    # moving CMP, or publishing a stock module leaf.
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        kernel="${REMOVE_FORWARD_KERNELS[$i]}"
        backup="${REMOVE_FORWARD_BACKUPS[$i]}"
        live="/lib/modules/${kernel}/updates/cmpunlocker"
        case "${phases[$i]}" in
            removing)
                if [[ -d "${live}" && ! -L "${live}" && \
                      ! -e "${backup}" && ! -L "${backup}" ]]; then
                    validate_cmp_module_dir "${live}" "${kernel}" && \
                        [[ "${VALIDATED_DRIVER_VERSION}" == "${versions[$i]}" && \
                           "${VALIDATED_CORE_SRC}" == "${cores[$i]}" && \
                           "${VALIDATED_PATCHED_HASHES}" == "${patched_hashes[$i]}" ]] || \
                        die "Live CMP set changed before forward recovery for ${kernel}"
                elif [[ ! -e "${live}" && ! -L "${live}" && \
                        -d "${backup}" && ! -L "${backup}" ]]; then
                    validate_cmp_module_dir "${backup}" "${kernel}" && \
                        [[ "${VALIDATED_DRIVER_VERSION}" == "${versions[$i]}" && \
                           "${VALIDATED_CORE_SRC}" == "${cores[$i]}" && \
                           "${VALIDATED_PATCHED_HASHES}" == "${patched_hashes[$i]}" ]] || \
                        die "Rollback CMP set changed during forward recovery for ${kernel}"
                else
                    die "Forward recovery has an ambiguous live/backup pair for ${kernel}"
                fi
                ;;
            stock-ready)
                [[ ! -e "${live}" && ! -L "${live}" ]] || \
                    die "Stock-ready forward state has a live CMP set for ${kernel}"
                safe_remove_backup "${backup}" "${kernel}" "${versions[$i]}" \
                    "${patched_hashes[$i]}" validate || \
                    die "Unsafe partial backup cleanup for ${kernel}"
                ;;
            *) die "Invalid forward phase for ${kernel}" ;;
        esac

        validate_forward_firmware "${versions[$i]}" "${firmware_prestates[$i]}" \
            "${firmware_attempted[$i]}" "${firmware_stock_hashes[$i]}" \
            "${firmware_patched_hashes[$i]}" || \
            die "Firmware proof changed during forward recovery for ${versions[$i]}"
        if [[ -n "${firmware_proofs[${versions[$i]}]+x}" ]]; then
            [[ "${firmware_proofs[${versions[$i]}]}" == \
               "${firmware_prestates[$i]}:${firmware_stock_hashes[$i]}:${firmware_patched_hashes[$i]}" ]] || \
                die "Conflicting firmware states share ${versions[$i]}"
        else
            firmware_proofs["${versions[$i]}"]="${firmware_prestates[$i]}:${firmware_stock_hashes[$i]}:${firmware_patched_hashes[$i]}"
        fi

        case "${dkms_prestates[$i]}" in
            none)
                [[ ! -e "${STATE_DIR}/dkms-removed.${kernel}.receipt" && \
                   ! -L "${STATE_DIR}/dkms-removed.${kernel}.receipt" ]] || \
                    die "Unexpected DKMS receipt appeared for ${kernel}"
                verify_prebarrier_stock_set "${kernel}" "${versions[$i]}" \
                    "${cores[$i]}" "${patched_hashes[$i]}" "${live}" \
                    "${stock_hashes[$i]}" "${dkms_manifests[$i]}" || \
                    die "Forward stock candidate changed for ${kernel}"
                ;;
            installed)
                parse_dkms_receipt "${kernel}" "${versions[$i]}" || \
                    die "Required DKMS receipt changed for ${kernel}"
                [[ "${DKMS_ARCH}" == "${dkms_arches[$i]}" ]] || \
                    die "DKMS receipt architecture changed for ${kernel}"
                ensure_dkms_tool
                query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
                    [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
                    die "Preinstalled DKMS tuple changed for ${kernel}"
                verify_prebarrier_stock_set "${kernel}" "${versions[$i]}" \
                    "${cores[$i]}" "${patched_hashes[$i]}" "${live}" \
                    "${stock_hashes[$i]}" "${dkms_manifests[$i]}" || \
                    die "Preinstalled stock candidate changed for ${kernel}"
                ;;
            absent)
                parse_dkms_receipt "${kernel}" "${versions[$i]}" || \
                    die "Required DKMS receipt changed for ${kernel}"
                [[ "${DKMS_ARCH}" == "${dkms_arches[$i]}" ]] || \
                    die "DKMS receipt architecture changed for ${kernel}"
                ensure_dkms_tool
                query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
                    die "Cannot inspect forward DKMS tuple for ${kernel}"
                [[ "${DKMS_TUPLE_STATE}" == "present" || \
                   "${DKMS_TUPLE_STATE}" == "installed" ]] || \
                    die "Durable forward DKMS build disappeared for ${kernel}"
                verify_dkms_built_payload_hashes "${versions[$i]}" "${kernel}" \
                    "${dkms_arches[$i]}" "${stock_hashes[$i]}" || \
                    die "Durable forward DKMS stock payload changed for ${kernel}"
                validate_dkms_built_signature_policy "${versions[$i]}" "${kernel}" \
                    "${dkms_arches[$i]}" || \
                    die "Durable forward DKMS signature identity changed for ${kernel}"
                mode=preflight
                [[ "${dkms_install_attempted[$i]}" == "1" ]] || mode=validate
                forward_dkms_tuple "${mode}" "${versions[$i]}" "${kernel}" \
                    "${dkms_arches[$i]}" "${dkms_built_hashes[$i]}" \
                    "${dkms_manifests[$i]}" "${live}" "${backup}" || \
                    die "Forward DKMS proof changed for ${kernel}"
                ;;
            *) die "Invalid DKMS forward state for ${kernel}" ;;
        esac
    done

    if [[ "${action}" == "validate" ]]; then
        # A receipt-owned copy temp can be present at any byte count after a
        # hard cut.  Validate its entire retained namespace without reclaiming
        # it, then let the global residual gate recognize only that exact name.
        handled_versions=()
        for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
            [[ "${firmware_prestates[$i]}" == "patched" ]] || continue
            [[ -z "${handled_versions[${versions[$i]}]+x}" ]] || continue
            handled_versions["${versions[$i]}"]=1
            all_firmware_attempted=1
            for kernel in "${!REMOVE_FORWARD_KERNELS[@]}"; do
                [[ "${versions[$kernel]}" == "${versions[$i]}" ]] || continue
                [[ "${firmware_attempted[$kernel]}" == "1" ]] || \
                    all_firmware_attempted=0
            done
            if (( all_firmware_attempted == 1 )); then
                firmware_namespace_action "${versions[$i]}" validate-attempted \
                    "${firmware_stock_hashes[$i]}" \
                    "${firmware_patched_hashes[$i]}" none 0 || \
                    die "Forward firmware temp proof changed for ${versions[$i]}"
                DEFERRED_FORWARD_FIRMWARE_TEMPS+=(
                    "/lib/firmware/nvidia/${versions[$i]}/.cmpunlocker-remove.gsp_tu10x.bin.tmp.${firmware_stock_hashes[$i]}"
                )
            else
                firmware_namespace_action "${versions[$i]}" inspect || \
                    die "Forward firmware namespace changed for ${versions[$i]}"
            fi
        done
        return 0
    fi

    # Acquire firmware copy authority for every kernel sharing a version before
    # the first byte is changed.  A cut among these state writes leaves main
    # firmware patched and is safely completed by the next pass.
    handled_versions=()
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        [[ "${firmware_prestates[$i]}" == "patched" ]] || continue
        [[ -z "${handled_versions[${versions[$i]}]+x}" ]] || continue
        handled_versions["${versions[$i]}"]=1
        all_firmware_attempted=1
        for kernel in "${!REMOVE_FORWARD_KERNELS[@]}"; do
            [[ "${versions[$kernel]}" == "${versions[$i]}" ]] || continue
            [[ "${firmware_attempted[$kernel]}" == "1" ]] || \
                all_firmware_attempted=0
        done
        if (( all_firmware_attempted == 1 )); then
            firmware_namespace_action "${versions[$i]}" inspect-attempted \
                "${firmware_stock_hashes[$i]}" \
                "${firmware_patched_hashes[$i]}" none 0 || \
                die "Could not reclaim exact receipt-owned firmware temp for ${versions[$i]}"
        else
            firmware_namespace_action "${versions[$i]}" inspect || \
                die "Could not recheck firmware for ${versions[$i]}"
        fi
        current_hash="${FIRMWARE_NAMESPACE_MAIN_HASH}"
        for kernel in "${!REMOVE_FORWARD_KERNELS[@]}"; do
            [[ "${versions[$kernel]}" == "${versions[$i]}" ]] || continue
            if [[ "${firmware_attempted[$kernel]}" == "0" ]]; then
                [[ "${current_hash}" == "${firmware_patched_hashes[$kernel]}" ]] || \
                    die "Firmware changed before forward copy intent for ${versions[$i]}"
                firmware_attempted[$kernel]=1
                write_remove_state "${phases[$kernel]}" \
                    "${REMOVE_FORWARD_KERNELS[$kernel]}" "${versions[$kernel]}" \
                    "${cores[$kernel]}" "${patched_hashes[$kernel]}" \
                    "${REMOVE_FORWARD_BACKUPS[$kernel]}" "${dkms_prestates[$kernel]}" \
                    "${dkms_attempted[$kernel]}" "${firmware_prestates[$kernel]}" "1" \
                    "${firmware_stock_hashes[$kernel]}" \
                    "${firmware_patched_hashes[$kernel]}" "${receipt_committed[$kernel]}" \
                    "${stock_hashes[$kernel]}" "${dkms_install_attempted[$kernel]}" \
                    "${dkms_built_hashes[$kernel]}" "${dkms_manifests[$kernel]}" \
                    "${dkms_arches[$kernel]}"
            fi
        done
    done
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        prepare_stock_firmware "${versions[$i]}" 0 \
            "${firmware_stock_hashes[$i]}" "${firmware_patched_hashes[$i]}" \
            "${firmware_prestates[$i]}" "${firmware_attempted[$i]}"
    done

    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        [[ "${phases[$i]}" == "removing" ]] || continue
        kernel="${REMOVE_FORWARD_KERNELS[$i]}"
        backup="${REMOVE_FORWARD_BACKUPS[$i]}"
        live="/lib/modules/${kernel}/updates/cmpunlocker"
        if [[ -d "${live}" && ! -L "${live}" ]]; then
            rename_cmp_module_dir_noreplace "${live}" "${backup}" "${kernel}" \
                "${versions[$i]}" "${patched_hashes[$i]}" || \
                die "Could not continue CMP removal for ${kernel}"
        fi
        validate_cmp_module_dir "${backup}" "${kernel}" && \
            [[ "${VALIDATED_DRIVER_VERSION}" == "${versions[$i]}" && \
               "${VALIDATED_CORE_SRC}" == "${cores[$i]}" && \
               "${VALIDATED_PATCHED_HASHES}" == "${patched_hashes[$i]}" ]] || \
            die "CMP backup changed after forward move for ${kernel}"
    done

    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        kernel="${REMOVE_FORWARD_KERNELS[$i]}"
        [[ "${dkms_prestates[$i]}" == "absent" ]] || continue
        validate_dkms_built_signature_policy "${versions[$i]}" "${kernel}" \
            "${dkms_arches[$i]}" || \
            die "Forward DKMS signature identity changed before publication for ${kernel}"
        mode="${DKMS_BUILT_SIGNATURE_MODE}"
        current_hash="${DKMS_BUILT_SIGNATURE_IDENTITY}"
        if [[ "${dkms_install_attempted[$i]}" == "0" ]]; then
            dkms_install_attempted[$i]=1
            write_remove_state "${phases[$i]}" "${kernel}" "${versions[$i]}" \
                "${cores[$i]}" "${patched_hashes[$i]}" "${REMOVE_FORWARD_BACKUPS[$i]}" \
                "${dkms_prestates[$i]}" "${dkms_attempted[$i]}" \
                "${firmware_prestates[$i]}" "${firmware_attempted[$i]}" \
                "${firmware_stock_hashes[$i]}" "${firmware_patched_hashes[$i]}" \
                "${receipt_committed[$i]}" "${stock_hashes[$i]}" "1" \
                "${dkms_built_hashes[$i]}" "${dkms_manifests[$i]}" \
                "${dkms_arches[$i]}"
        fi
        forward_dkms_tuple publish "${versions[$i]}" "${kernel}" \
            "${dkms_arches[$i]}" "${dkms_built_hashes[$i]}" \
            "${dkms_manifests[$i]}" "/lib/modules/${kernel}/updates/cmpunlocker" \
            "${REMOVE_FORWARD_BACKUPS[$i]}" || \
            die "Could not complete exact forward DKMS publication for ${kernel}"
        verify_published_dkms_signature_identity "${kernel}" "${dkms_manifests[$i]}" \
            "${mode}" "${current_hash}" || \
            die "Forward-published DKMS signatures differ from the built payloads for ${kernel}"
        query_dkms_tuple "${versions[$i]}" "${kernel}" "${dkms_arches[$i]}" && \
            [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
            die "Forward-published DKMS tuple is not installed for ${kernel}"
    done

    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        kernel="${REMOVE_FORWARD_KERNELS[$i]}"
        depmod -a "${kernel}" || die "depmod failed during forward recovery for ${kernel}"
        verify_stock_module_set "${kernel}" "${versions[$i]}" "${cores[$i]}" \
            "${patched_hashes[$i]}" "${stock_hashes[$i]}" || \
            die "Stock proof failed during forward recovery for ${kernel}"
        stock_hashes[$i]="${VERIFIED_STOCK_HASHES}"
        phase_to_write="${phases[$i]}"
        write_remove_state "${phase_to_write}" "${kernel}" "${versions[$i]}" \
            "${cores[$i]}" "${patched_hashes[$i]}" "${REMOVE_FORWARD_BACKUPS[$i]}" \
            "${dkms_prestates[$i]}" "${dkms_attempted[$i]}" \
            "${firmware_prestates[$i]}" "${firmware_attempted[$i]}" \
            "${firmware_stock_hashes[$i]}" "${firmware_patched_hashes[$i]}" \
            "${receipt_committed[$i]}" "${stock_hashes[$i]}" \
            "${dkms_install_attempted[$i]}" "${dkms_built_hashes[$i]}" \
            "${dkms_manifests[$i]}" "${dkms_arches[$i]}"
    done
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        verify_stock_module_set "${REMOVE_FORWARD_KERNELS[$i]}" "${versions[$i]}" \
            "${cores[$i]}" "${patched_hashes[$i]}" "${stock_hashes[$i]}" || \
            die "Recorded stock set changed before initramfs for ${REMOVE_FORWARD_KERNELS[$i]}"
    done
    for kernel in "${REMOVE_FORWARD_KERNELS[@]}"; do
        rebuild_kernel_initramfs "${kernel}" || \
            die "Stock initramfs rebuild failed during forward recovery for ${kernel}"
    done
    sync || die "Could not persist the recovered stock module state"
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        write_remove_state "stock-ready" "${REMOVE_FORWARD_KERNELS[$i]}" \
            "${versions[$i]}" "${cores[$i]}" "${patched_hashes[$i]}" \
            "${REMOVE_FORWARD_BACKUPS[$i]}" "${dkms_prestates[$i]}" \
            "${dkms_attempted[$i]}" "${firmware_prestates[$i]}" \
            "${firmware_attempted[$i]}" "${firmware_stock_hashes[$i]}" \
            "${firmware_patched_hashes[$i]}" "${receipt_committed[$i]}" \
            "${stock_hashes[$i]}" "${dkms_install_attempted[$i]}" \
            "${dkms_built_hashes[$i]}" "${dkms_manifests[$i]}" \
            "${dkms_arches[$i]}"
        phases[$i]=stock-ready
    done

    # Validate every remaining partial backup first, then consume them.  Thus
    # an unsafe late collision cannot cause only a subset of backups to vanish.
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        safe_remove_backup "${REMOVE_FORWARD_BACKUPS[$i]}" \
            "${REMOVE_FORWARD_KERNELS[$i]}" "${versions[$i]}" \
            "${patched_hashes[$i]}" validate || \
            die "Backup cleanup proof failed for ${REMOVE_FORWARD_KERNELS[$i]}"
    done
    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        safe_remove_backup "${REMOVE_FORWARD_BACKUPS[$i]}" \
            "${REMOVE_FORWARD_KERNELS[$i]}" "${versions[$i]}" \
            "${patched_hashes[$i]}" || \
            die "Could not finish backup cleanup for ${REMOVE_FORWARD_KERNELS[$i]}"
    done
    durable_remove_file "${REMOVE_FORWARD}" || \
        die "Could not finalize the forward-only removal barrier"
    REMOVE_FORWARD_PRESENT=0
    ok "Recovered ${#REMOVE_FORWARD_KERNELS[@]} forward-only stock transition(s)"
}

recover_orphan_transactions() {
    local orphan base payload kernel nonce owner state_path
    local -A seen=()
    local orphans=(/lib/modules/.cmpunlocker.remove.*)

    if [[ -e "${REMOVE_FORWARD}" || -L "${REMOVE_FORWARD}" ]]; then
        DEFERRED_FORWARD_RECOVERY=1
        recover_forward_transaction validate
        return 0
    fi
    if [[ -e "${REMOVE_COMMIT}" || -L "${REMOVE_COMMIT}" ]]; then
        parse_remove_commit || die "Invalid multi-kernel removal commit ${REMOVE_COMMIT}"
    fi
    if (( ${#orphans[@]} == 0 )); then
        finalize_remove_commit_recovery
        return 0
    fi
    ensure_recovery_tools
    for orphan in "${orphans[@]}"; do
        [[ -d "${orphan}" && ! -L "${orphan}" ]] || \
            die "Unsafe orphaned transaction object ${orphan}"
        owner="$(stat -c %u -- "${orphan}")"
        [[ "${owner}" == "0" ]] || die "Orphan ${orphan} is not root-owned"
        base="${orphan##*/}"
        payload="${base#.cmpunlocker.remove.}"
        kernel="${payload%.*}"
        nonce="${payload##*.}"
        valid_kernel "${kernel}" && [[ "${nonce}" =~ ^[A-Za-z0-9]{6}$ ]] || \
            die "Unsafe orphan transaction name ${orphan}"
        [[ -z "${seen[${kernel}]+x}" ]] || \
            die "Multiple orphan transactions exist for ${kernel}"
        seen["${kernel}"]="${orphan}"
        lock_kernel "${kernel}"
    done
    warn "Found interrupted CMP module rollback object(s) without a durable forward-only marker"
    warn "Automatic per-kernel rollback is disabled because all kernels sharing firmware and DKMS state must be reconciled as one set"
    while IFS= read -r kernel; do
        state_path="$(remove_state_path "${kernel}")"
        if [[ -e "${state_path}" || -L "${state_path}" ]]; then
            warn "Manual reconciliation set: ${seen[${kernel}]} <-> ${state_path}"
        else
            warn "Manual reconciliation set: ${seen[${kernel}]} <-> no durable remove.${kernel}.state"
        fi
    done < <(printf '%s\n' "${!seen[@]}" | LC_ALL=C sort)
    die "Preserving every orphan, removal state, firmware object, and DKMS object; do not rename or delete one kernel independently. Reconcile the complete set above, then rerun remove.sh"
}

step "Recovering transactions and validating installed module sets"
prelock_all_kernels
recover_orphan_transactions

declare -a MODULE_DIRS=()
declare -a KERNELS=()
declare -a EXPECTED_VERSIONS=()
declare -a PATCHED_CORE_SRCS=()
declare -a PATCHED_HASH_SETS=()
declare -a STOCK_HASH_SETS=()
declare -a MODULE_BACKUPS=()
declare -a DKMS_PRESTATES=()
declare -a DKMS_ATTEMPTED_FLAGS=()
declare -a DKMS_ARCHES=()
declare -a DKMS_INSTALL_ATTEMPTED_FLAGS=()
declare -a DKMS_BUILT_HASH_SETS=()
declare -a DKMS_PREINSTALL_MANIFESTS=()
declare -a FIRMWARE_PRESTATES=()
declare -a FIRMWARE_ATTEMPTED_FLAGS=()
declare -a FIRMWARE_STOCK_HASHES=()
declare -a FIRMWARE_PATCHED_HASHES=()
declare -a DKMS_RECEIPT_COMMITTED_FLAGS=()
declare -a LIVE_STATE_PRESENT_FLAGS=()
declare -a RESUME_KERNELS=()
declare -a RESUME_VERSIONS=()
declare -a RESUME_PATCHED_SRCS=()
declare -a RESUME_PATCHED_HASH_SETS=()
declare -a RESUME_STOCK_HASH_SETS=()
declare -a RESUME_DKMS_PRESTATES=()
declare -a RESUME_DKMS_ATTEMPTED_FLAGS=()
declare -a RESUME_DKMS_ARCHES=()
declare -a RESUME_DKMS_INSTALL_ATTEMPTED_FLAGS=()
declare -a RESUME_DKMS_BUILT_HASH_SETS=()
declare -a RESUME_DKMS_PREINSTALL_MANIFESTS=()
declare -a RESUME_FIRMWARE_PRESTATES=()
declare -a RESUME_FIRMWARE_ATTEMPTED_FLAGS=()
declare -a RESUME_FIRMWARE_STOCK_HASHES=()
declare -a RESUME_FIRMWARE_PATCHED_HASHES=()
declare -a RESUME_DKMS_RECEIPT_COMMITTED_FLAGS=()
declare -a RESUME_STOCK_ALREADY_PUBLISHED_FLAGS=()
declare -a CLEANUP_STATE_PATHS=()
declare -a RESET_PRE_FORWARD_STATE_PATHS=()

append_parsed_stock_ready_state() {
    local state_path="$1"
    local stock_already_published="${2:-0}"
    local live="/lib/modules/${REMOVE_KERNEL}/updates/cmpunlocker"

    [[ "${stock_already_published}" =~ ^[01]$ ]] || \
        die "Invalid recovered-stock publication flag for ${state_path}"
    [[ "${REMOVE_PHASE}" == "stock-ready" ]] || \
        die "${state_path} is removing, but neither live nor rollback modules exist"
    [[ ! -e "${live}" && ! -L "${live}" ]] || \
        die "Stock-ready state still has a live CMP set: ${live}"
    [[ ! -e "${REMOVE_BACKUP}" && ! -L "${REMOVE_BACKUP}" ]] || \
        die "Unrecovered rollback directory still exists: ${REMOVE_BACKUP}"
    if array_has "${REMOVE_KERNEL}" "${RESUME_KERNELS[@]}"; then
        die "Duplicate stock-ready removal state for ${REMOVE_KERNEL}"
    fi
    RESUME_KERNELS+=("${REMOVE_KERNEL}")
    RESUME_VERSIONS+=("${REMOVE_VERSION}")
    RESUME_PATCHED_SRCS+=("${REMOVE_PATCHED_SRC}")
    RESUME_PATCHED_HASH_SETS+=("${REMOVE_PATCHED_HASHES}")
    RESUME_STOCK_HASH_SETS+=("${REMOVE_STOCK_HASHES}")
    RESUME_DKMS_PRESTATES+=("${REMOVE_DKMS_PRESTATE}")
    RESUME_DKMS_ATTEMPTED_FLAGS+=("${REMOVE_DKMS_ATTEMPTED}")
    RESUME_DKMS_ARCHES+=("${REMOVE_DKMS_ARCH}")
    RESUME_DKMS_INSTALL_ATTEMPTED_FLAGS+=("${REMOVE_DKMS_INSTALL_ATTEMPTED}")
    RESUME_DKMS_BUILT_HASH_SETS+=("${REMOVE_DKMS_BUILT_HASHES}")
    RESUME_DKMS_PREINSTALL_MANIFESTS+=("${REMOVE_DKMS_PREINSTALL_MANIFEST}")
    RESUME_FIRMWARE_PRESTATES+=("${REMOVE_FIRMWARE_PRESTATE}")
    RESUME_FIRMWARE_ATTEMPTED_FLAGS+=("${REMOVE_FIRMWARE_ATTEMPTED}")
    RESUME_FIRMWARE_STOCK_HASHES+=("${REMOVE_FIRMWARE_STOCK_HASH}")
    RESUME_FIRMWARE_PATCHED_HASHES+=("${REMOVE_FIRMWARE_PATCHED_HASH}")
    RESUME_DKMS_RECEIPT_COMMITTED_FLAGS+=("${REMOVE_DKMS_RECEIPT_COMMITTED}")
    RESUME_STOCK_ALREADY_PUBLISHED_FLAGS+=("${stock_already_published}")
    CLEANUP_STATE_PATHS+=("${state_path}")
}

validate_deferred_firmware_domain_preflight() {
    local i state_path version prestate attempted stock_hash patched_hash proof bit
    local -A forward_proof_by_version=() forward_attempt_mask_by_version=()

    (( DEFERRED_FORWARD_RECOVERY == 1 )) || return 0

    for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
        state_path="$(remove_state_path "${REMOVE_FORWARD_KERNELS[$i]}")"
        parse_remove_state "${state_path}" || \
            die "Invalid deferred forward firmware state ${state_path}"
        version="${REMOVE_VERSION}"
        prestate="${REMOVE_FIRMWARE_PRESTATE}"
        attempted="${REMOVE_FIRMWARE_ATTEMPTED}"
        stock_hash="${REMOVE_FIRMWARE_STOCK_HASH}"
        patched_hash="${REMOVE_FIRMWARE_PATCHED_HASH}"
        validate_forward_firmware "${version}" "${prestate}" "${attempted}" \
            "${stock_hash}" "${patched_hash}" || \
            die "Deferred forward firmware proof changed before the global barrier for ${version}"
        proof="${prestate}:${stock_hash}:${patched_hash}"
        if [[ -n "${forward_proof_by_version[${version}]+x}" && \
              "${forward_proof_by_version[${version}]}" != "${proof}" ]]; then
            die "Conflicting deferred forward firmware proofs share ${version}"
        fi
        forward_proof_by_version["${version}"]="${proof}"
        bit=$((1 << 10#${attempted}))
        forward_attempt_mask_by_version["${version}"]=$((
            ${forward_attempt_mask_by_version[${version}]:-0} | bit
        ))
    done

    for i in "${!RESUME_KERNELS[@]}"; do
        version="${RESUME_VERSIONS[$i]}"
        prestate="${RESUME_FIRMWARE_PRESTATES[$i]}"
        attempted="${RESUME_FIRMWARE_ATTEMPTED_FLAGS[$i]}"
        stock_hash="${RESUME_FIRMWARE_STOCK_HASHES[$i]}"
        patched_hash="${RESUME_FIRMWARE_PATCHED_HASHES[$i]}"
        validate_forward_firmware "${version}" "${prestate}" "${attempted}" \
            "${stock_hash}" "${patched_hash}" || \
            die "Resumable firmware proof changed before deferred forward recovery for ${version}"
        [[ -n "${forward_proof_by_version[${version}]+x}" ]] || continue
        proof="${prestate}:${stock_hash}:${patched_hash}"
        bit=$((1 << 10#${attempted}))
        [[ "${forward_proof_by_version[${version}]}" == "${proof}" && \
           "${forward_attempt_mask_by_version[${version}]}" == "${bit}" ]] || \
            die "Deferred forward firmware proof conflicts with resumable authority for ${version}"
    done

    for i in "${!KERNELS[@]}"; do
        [[ "${LIVE_STATE_PRESENT_FLAGS[$i]:-0}" == "1" ]] || continue
        version="${EXPECTED_VERSIONS[$i]}"
        prestate="${FIRMWARE_PRESTATES[$i]}"
        attempted="${FIRMWARE_ATTEMPTED_FLAGS[$i]}"
        stock_hash="${FIRMWARE_STOCK_HASHES[$i]}"
        patched_hash="${FIRMWARE_PATCHED_HASHES[$i]}"
        validate_forward_firmware "${version}" "${prestate}" "${attempted}" \
            "${stock_hash}" "${patched_hash}" || \
            die "Live firmware proof changed before deferred forward recovery for ${version}"
        [[ -n "${forward_proof_by_version[${version}]+x}" ]] || continue
        proof="${prestate}:${stock_hash}:${patched_hash}"
        bit=$((1 << 10#${attempted}))
        [[ "${forward_proof_by_version[${version}]}" == "${proof}" && \
           "${forward_attempt_mask_by_version[${version}]}" == "${bit}" ]] || \
            die "Deferred forward firmware proof conflicts with live authority for ${version}"
    done
}

for module_dir in /lib/modules/*/updates/cmpunlocker; do
    [[ -d "${module_dir}" && ! -L "${module_dir}" ]] || \
        die "Unsafe cmpunlocker module object ${module_dir}"
    kernel="$(basename "$(dirname "$(dirname "${module_dir}")")")"
    valid_kernel "${kernel}" || die "Unsafe kernel name from ${module_dir}"
    lock_kernel "${kernel}"
    if (( DEFERRED_FORWARD_RECOVERY == 1 )) && \
       array_has "${kernel}" "${REMOVE_FORWARD_KERNELS[@]}"; then
        continue
    fi
    validate_cmp_module_dir "${module_dir}" "${kernel}" || \
        die "Incomplete or invalid patched five-module set at ${module_dir}"
    MODULE_DIRS+=("${module_dir}")
    KERNELS+=("${kernel}")
    EXPECTED_VERSIONS+=("${VALIDATED_DRIVER_VERSION}")
    PATCHED_CORE_SRCS+=("${VALIDATED_CORE_SRC}")
    PATCHED_HASH_SETS+=("${VALIDATED_PATCHED_HASHES}")
done

live_index_for_kernel() {
    local want="$1" i
    for i in "${!KERNELS[@]}"; do
        if [[ "${KERNELS[$i]}" == "${want}" ]]; then
            printf '%s\n' "${i}"
            return 0
        fi
    done
    return 1
}

for state_path in "${STATE_DIR}"/remove.*.state; do
    parse_remove_state "${state_path}" || die "Invalid removal state ${state_path}"
    lock_kernel "${REMOVE_KERNEL}"
    if (( DEFERRED_FORWARD_RECOVERY == 1 )) && \
       remove_forward_includes "${REMOVE_KERNEL}" "${REMOVE_BACKUP}"; then
        continue
    fi
    if live_index="$(live_index_for_kernel "${REMOVE_KERNEL}")"; then
        [[ "${REMOVE_PHASE}" == "removing" ]] || \
            die "${state_path} says stock-ready while patched modules still exist"
        [[ "${EXPECTED_VERSIONS[$live_index]}" == "${REMOVE_VERSION}" && \
           "${PATCHED_CORE_SRCS[$live_index]}" == "${REMOVE_PATCHED_SRC}" && \
           "${PATCHED_HASH_SETS[$live_index]}" == "${REMOVE_PATCHED_HASHES}" ]] || \
            die "${state_path} does not match the live patched set"
        [[ ! -e "${REMOVE_BACKUP}" && ! -L "${REMOVE_BACKUP}" ]] || \
            die "Live and rollback directories both exist for ${REMOVE_KERNEL}"
        validate_forward_firmware "${REMOVE_VERSION}" "${REMOVE_FIRMWARE_PRESTATE}" \
            "${REMOVE_FIRMWARE_ATTEMPTED}" "${REMOVE_FIRMWARE_STOCK_HASH}" \
            "${REMOVE_FIRMWARE_PATCHED_HASH}" || \
            die "Pre-forward firmware proof changed for ${REMOVE_VERSION}"
        [[ "${REMOVE_FIRMWARE_ATTEMPTED}" == "0" && \
           "${REMOVE_DKMS_INSTALL_ATTEMPTED}" == "0" && \
           "${REMOVE_DKMS_RECEIPT_COMMITTED}" == "0" ]] || \
            die "Removal state for ${REMOVE_KERNEL} crossed an old mutation boundary without a forward marker; preserving it for manual reconciliation"
        if [[ "${REMOVE_DKMS_ATTEMPTED}" == "0" ]]; then
            case "${REMOVE_DKMS_PRESTATE}" in
                absent)
                    [[ "${REMOVE_STOCK_HASHES}" == "pending" && \
                       "${REMOVE_DKMS_PREINSTALL_MANIFEST}" == "pending" ]] || \
                        die "Absent DKMS baseline has unexpected pre-barrier stock authority for ${REMOVE_KERNEL}"
                    ;;
                none|installed)
                    [[ "${REMOVE_STOCK_HASHES}" =~ ^([a-f0-9]{64}:){4}[a-f0-9]{64}$ && \
                       "${REMOVE_DKMS_PREINSTALL_MANIFEST}" != "pending" ]] && \
                        valid_stock_candidate_manifest \
                            "${REMOVE_DKMS_PREINSTALL_MANIFEST}" || \
                        die "Incomplete pre-barrier stock authority for ${REMOVE_KERNEL}"
                    verify_prebarrier_stock_set "${REMOVE_KERNEL}" \
                        "${REMOVE_VERSION}" "${REMOVE_PATCHED_SRC}" \
                        "${REMOVE_PATCHED_HASHES}" \
                        "${MODULE_DIRS[$live_index]}" \
                        "${REMOVE_STOCK_HASHES}" \
                        "${REMOVE_DKMS_PREINSTALL_MANIFEST}" || \
                        die "Pre-barrier stock candidate changed for ${REMOVE_KERNEL}"
                    ;;
                *) die "Invalid pre-forward DKMS baseline for ${REMOVE_KERNEL}" ;;
            esac
            restore_dkms_prestate "${REMOVE_KERNEL}" "${REMOVE_VERSION}" \
                "${REMOVE_DKMS_PRESTATE}" "0" "0" pending \
                "${REMOVE_DKMS_PREINSTALL_MANIFEST}" \
                "${REMOVE_DKMS_ARCH}" || \
                die "Pre-forward DKMS baseline changed for ${REMOVE_KERNEL}"
            RESET_PRE_FORWARD_STATE_PATHS+=("${state_path}")
        elif [[ "${REMOVE_DKMS_BUILT_HASHES}" == "pending" ]]; then
            [[ "${REMOVE_DKMS_PRESTATE}" == "absent" ]] || \
                die "Invalid pending DKMS build authority for ${REMOVE_KERNEL}"
            parse_dkms_receipt "${REMOVE_KERNEL}" "${REMOVE_VERSION}" || \
                die "Required DKMS receipt changed for ${REMOVE_KERNEL}"
            [[ "${DKMS_ARCH}" == "${REMOVE_DKMS_ARCH}" ]] || \
                die "DKMS receipt architecture changed for ${REMOVE_KERNEL}"
            ensure_dkms_tool
            if query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
               [[ "${DKMS_TUPLE_STATE}" == "absent" && \
                  "${DKMS_GLOBAL_ADDED}" == "1" ]] && \
               dkms_exact_residue_absent "${DKMS_VERSION}" "${DKMS_KERNEL}" \
                    "${DKMS_ARCH}"; then
                RESET_PRE_FORWARD_STATE_PATHS+=("${state_path}")
            else
                die "DKMS build for ${REMOVE_KERNEL} was interrupted before its durable payload journal; preserving CMP, firmware, state, and all canonical DKMS residue for manual reconciliation"
            fi
        else
            [[ "${REMOVE_DKMS_PRESTATE}" == "absent" && \
               "${REMOVE_DKMS_PREINSTALL_MANIFEST}" != "pending" ]] || \
                die "Incomplete durable DKMS build state for ${REMOVE_KERNEL}"
            parse_dkms_receipt "${REMOVE_KERNEL}" "${REMOVE_VERSION}" || \
                die "Required DKMS receipt changed for ${REMOVE_KERNEL}"
            [[ "${DKMS_ARCH}" == "${REMOVE_DKMS_ARCH}" ]] || \
                die "DKMS receipt architecture changed for ${REMOVE_KERNEL}"
            ensure_dkms_tool
            query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
                [[ "${DKMS_TUPLE_STATE}" == "present" ]] || \
                die "Completed pre-forward DKMS build changed for ${REMOVE_KERNEL}"
            forward_dkms_tuple validate "${REMOVE_VERSION}" "${REMOVE_KERNEL}" \
                "${REMOVE_DKMS_ARCH}" "${REMOVE_DKMS_BUILT_HASHES}" \
                "${REMOVE_DKMS_PREINSTALL_MANIFEST}" "${MODULE_DIRS[$live_index]}" \
                "${REMOVE_BACKUP}" || \
                die "Completed DKMS build proof changed for ${REMOVE_KERNEL}"
            LIVE_STATE_PRESENT_FLAGS[$live_index]=1
            MODULE_BACKUPS[$live_index]="${REMOVE_BACKUP}"
            DKMS_PRESTATES[$live_index]="${REMOVE_DKMS_PRESTATE}"
            DKMS_ATTEMPTED_FLAGS[$live_index]="${REMOVE_DKMS_ATTEMPTED}"
            DKMS_ARCHES[$live_index]="${REMOVE_DKMS_ARCH}"
            DKMS_INSTALL_ATTEMPTED_FLAGS[$live_index]="${REMOVE_DKMS_INSTALL_ATTEMPTED}"
            DKMS_BUILT_HASH_SETS[$live_index]="${REMOVE_DKMS_BUILT_HASHES}"
            DKMS_PREINSTALL_MANIFESTS[$live_index]="${REMOVE_DKMS_PREINSTALL_MANIFEST}"
            FIRMWARE_PRESTATES[$live_index]="${REMOVE_FIRMWARE_PRESTATE}"
            FIRMWARE_ATTEMPTED_FLAGS[$live_index]="${REMOVE_FIRMWARE_ATTEMPTED}"
            FIRMWARE_STOCK_HASHES[$live_index]="${REMOVE_FIRMWARE_STOCK_HASH}"
            FIRMWARE_PATCHED_HASHES[$live_index]="${REMOVE_FIRMWARE_PATCHED_HASH}"
            DKMS_RECEIPT_COMMITTED_FLAGS[$live_index]="${REMOVE_DKMS_RECEIPT_COMMITTED}"
            STOCK_HASH_SETS[$live_index]="${REMOVE_STOCK_HASHES}"
        fi
    else
        append_parsed_stock_ready_state "${state_path}"
    fi
done

# A deferred forward domain may share its firmware version with live or
# stock-ready removal authority only when the complete proof and attempted
# bit agree.  Run this after complete classification but before any reset or
# receipt-owned temporary cleanup mutates the namespace.
validate_deferred_firmware_domain_preflight

# Classification above is deliberately complete before this first mutation:
# an ambiguous sibling kernel must leave every otherwise-resettable state as
# evidence.  Only states proven to precede all external side effects are reset.
for state_path in "${RESET_PRE_FORWARD_STATE_PATHS[@]}"; do
    durable_remove_file "${state_path}" || die "Could not reset ${state_path}"
done

for i in "${!KERNELS[@]}"; do
    for resume_i in "${!RESUME_KERNELS[@]}"; do
        [[ "${EXPECTED_VERSIONS[$i]}" != "${RESUME_VERSIONS[$resume_i]}" ]] || \
            die "Live ${KERNELS[$i]} and stock-ready ${RESUME_KERNELS[$resume_i]} share firmware ${EXPECTED_VERSIONS[$i]}; refusing an unsafe mixed rollback domain"
    done
done

# A stock-ready receipt is the only authority that may reclaim its exact
# deterministic firmware temp.  Do this after complete state classification
# and mixed-domain rejection, but before the global residual namespace gate.
for i in "${!RESUME_KERNELS[@]}"; do
    resume_firmware_temp="/lib/firmware/nvidia/${RESUME_VERSIONS[$i]}/.cmpunlocker-remove.gsp_tu10x.bin.tmp.${RESUME_FIRMWARE_STOCK_HASHES[$i]}"
    if [[ "${RESUME_FIRMWARE_PRESTATES[$i]}" == "patched" && \
          "${RESUME_FIRMWARE_ATTEMPTED_FLAGS[$i]}" == "1" && \
          ( -e "${resume_firmware_temp}" || -L "${resume_firmware_temp}" ) ]]; then
        firmware_namespace_action "${RESUME_VERSIONS[$i]}" inspect-attempted \
            "${RESUME_FIRMWARE_STOCK_HASHES[$i]}" \
            "${RESUME_FIRMWARE_PATCHED_HASHES[$i]}" none 0 || \
            die "Could not reclaim exact receipt-owned firmware temp while resuming ${RESUME_VERSIONS[$i]}"
    fi
done

ok "Validated ${#MODULE_DIRS[@]} live and ${#RESUME_KERNELS[@]} resumable stock transition(s)"

declare -A IOMMU_DATA=()
IOMMU_BACKEND=""
IOMMU_SOURCE=""
IOMMU_BASE_HASH=""
IOMMU_EXPECTED_HASH=""
IOMMU_GENERATOR=""
IOMMU_TARGET=""
IOMMU_KEY=""
IOMMU_LEGACY_GRUB_BACKUP_HASH="absent"
IOMMU_LEGACY_GRUB_PENDING_HASH="absent"
IOMMU_LEGACY_CMDLINE_BACKUP_HASH="absent"
IOMMU_LEGACY_CMDLINE_PENDING_HASH="absent"
IOMMU_BOOT_TARGET="absent"
IOMMU_BOOT_TARGET_HASH="absent"
IOMMU_BOOT_CANDIDATE_HASH="absent"
IOMMU_BOOT_STAGE="absent"
IOMMU_BOOT_STAGE_NEW="absent"
IOMMU_BOOT_GENERATOR_ATTEMPTED="0"
IOMMU_BOOT_PARENT_DEV="absent"
IOMMU_BOOT_PARENT_INO="absent"
IOMMU_SOURCE_PARENT_DEV="absent"
IOMMU_SOURCE_PARENT_INO="absent"

set_iommu_legacy_absent_authority() {
    IOMMU_LEGACY_GRUB_BACKUP_HASH=absent
    IOMMU_LEGACY_GRUB_PENDING_HASH=absent
    IOMMU_LEGACY_CMDLINE_BACKUP_HASH=absent
    IOMMU_LEGACY_CMDLINE_PENDING_HASH=absent
}

set_iommu_extended_boot_absent_authority() {
    IOMMU_BOOT_STAGE_NEW=absent
    IOMMU_BOOT_GENERATOR_ATTEMPTED=0
    IOMMU_SOURCE_PARENT_DEV=absent
    IOMMU_SOURCE_PARENT_INO=absent
}

valid_iommu_legacy_hash() {
    [[ "$1" == "absent" || "$1" =~ ^[a-f0-9]{64}$ ]]
}

valid_iommu_boot_namespace_names() {
    local target="$1" stage="$2" vendor

    case "${target}" in
        /boot/grub/grub.cfg|/boot/grub2/grub.cfg) ;;
        /boot/efi/EFI/*/grub.cfg)
            [[ "${target}" =~ ^/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg$ ]] || return 1
            vendor="$(basename -- "$(dirname -- "${target}")")"
            [[ "${vendor}" != "." && "${vendor}" != ".." ]] || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "${stage}" == "$(dirname -- "${target}")/.cmpunlocker-remove.$(basename -- "${target}").boot."* && \
       "${stage}" =~ ^/boot/[A-Za-z0-9._+/-]+/\.cmpunlocker-remove\.grub\.cfg\.boot\.[a-f0-9]{6}$ && \
       "$(dirname -- "${target}")" == "$(dirname -- "${stage}")" ]]
}

IOMMU_SOURCE_NAMESPACE_HASH=""
IOMMU_SOURCE_NAMESPACE_PARENT_DEV=""
IOMMU_SOURCE_NAMESPACE_PARENT_INO=""
inspect_iommu_source_namespace() {
    local target="$1" output
    local -a values=()

    output="$(python3 - "${target}" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

target = pathlib.Path(sys.argv[1])
if target not in (pathlib.Path("/etc/default/grub"),
                  pathlib.Path("/etc/kernel/cmdline")):
    raise SystemExit("invalid literal IOMMU source")

def mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

mounted = mounts()
for ancestor in (pathlib.Path("/"), pathlib.Path("/etc"), target.parent):
    normalized = os.path.normpath(os.fspath(ancestor))
    if normalized in mounted and normalized not in {"/", "/etc"}:
        raise SystemExit(f"mount redirects IOMMU source ancestor: {ancestor}")
aliases = {os.path.normpath(os.fspath(target)),
           os.path.normpath(os.path.realpath(target))}
if aliases & mounted:
    raise SystemExit("mount blocks IOMMU source inspection")

flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
         | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
fds = []
chain = []
root_fd = os.open("/", flags); fds.append(root_fd)
root_st = os.fstat(root_fd)
current_fd = root_fd
for component in ("etc", target.parent.name):
    lst = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
    child_fd = os.open(component, flags, dir_fd=current_fd)
    fst = os.fstat(child_fd)
    if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISDIR(fst.st_mode) or fst.st_uid != 0
            or fst.st_gid != 0 or stat.S_IMODE(fst.st_mode) & 0o022
            or (component != "etc" and fst.st_dev != os.fstat(current_fd).st_dev)):
        raise SystemExit(f"unsafe literal IOMMU source ancestor: {component}")
    chain.append((current_fd, component, child_fd, fst))
    fds.append(child_fd); current_fd = child_fd
dfd = current_fd
pst = os.fstat(dfd)

def verify_chain():
    opened_root = os.fstat(root_fd)
    if ((opened_root.st_dev, opened_root.st_ino) !=
            (root_st.st_dev, root_st.st_ino)
            or not stat.S_ISDIR(opened_root.st_mode)
            or opened_root.st_uid != 0 or opened_root.st_gid != 0
            or stat.S_IMODE(opened_root.st_mode) & 0o022):
        raise SystemExit("IOMMU source root changed")
    for parent_fd, name, child_fd, expected in chain:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(child_fd)
        for observed in (current, opened):
            if (not stat.S_ISDIR(observed.st_mode)
                    or (observed.st_dev, observed.st_ino) !=
                       (expected.st_dev, expected.st_ino)
                    or observed.st_uid != expected.st_uid
                    or observed.st_gid != expected.st_gid
                    or stat.S_IMODE(observed.st_mode) !=
                       stat.S_IMODE(expected.st_mode)):
                raise SystemExit("literal IOMMU source chain changed")

tfd = -1
try:
    verify_chain()
    lst = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    tfd = os.open(target.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                  | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    tst = os.fstat(tfd)
    if ((tst.st_dev, tst.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISREG(tst.st_mode) or tst.st_uid != 0
            or tst.st_gid != 0 or tst.st_nlink != 1
            or stat.S_IMODE(tst.st_mode) & 0o022 or tst.st_dev != pst.st_dev):
        raise SystemExit("unsafe literal IOMMU source leaf")
    value = hashlib.sha256()
    while True:
        block = os.read(tfd, 1024 * 1024)
        if not block: break
        value.update(block)
    digest = value.hexdigest()
    verify_chain()
    current = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    if ((current.st_dev, current.st_ino) != (tst.st_dev, tst.st_ino)
            or mounted != mounts()):
        raise SystemExit("IOMMU source changed during inspection")
    print(digest); print(pst.st_dev); print(pst.st_ino)
finally:
    if tfd >= 0: os.close(tfd)
    for fd in reversed(fds): os.close(fd)
PY
    )" || return 1
    mapfile -t values <<< "${output}"
    (( ${#values[@]} == 3 )) || return 1
    [[ "${values[0]}" =~ ^[a-f0-9]{64}$ && \
       "${values[1]}" =~ ^[1-9][0-9]*$ && \
       "${values[2]}" =~ ^[1-9][0-9]*$ ]] || return 1
    IOMMU_SOURCE_NAMESPACE_HASH="${values[0]}"
    IOMMU_SOURCE_NAMESPACE_PARENT_DEV="${values[1]}"
    IOMMU_SOURCE_NAMESPACE_PARENT_INO="${values[2]}"
}

validate_iommu_legacy_authority() {
    python3 - \
        /etc/default/grub.cmpunlocker.bak "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" \
        /etc/default/grub.cmpunlocker.pending "${IOMMU_LEGACY_GRUB_PENDING_HASH}" \
        /etc/kernel/cmdline.cmpunlocker.bak "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" \
        /etc/kernel/cmdline.cmpunlocker.pending "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

pairs = list(zip(sys.argv[1::2], sys.argv[2::2]))
expected_paths = [
    "/etc/default/grub.cmpunlocker.bak",
    "/etc/default/grub.cmpunlocker.pending",
    "/etc/kernel/cmdline.cmpunlocker.bak",
    "/etc/kernel/cmdline.cmpunlocker.pending",
]
if [path for path, unused in pairs] != expected_paths:
    raise SystemExit("invalid legacy IOMMU path authority")

def parent_mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, unused_right = raw[:-1].split(b" - ", 1)
            fields = left.split(b" ")
            if len(fields) < 6 or not fields[4]:
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

mounted = parent_mounts()
for parent in (pathlib.Path("/etc/default"), pathlib.Path("/etc/kernel")):
    try:
        pst = os.lstat(parent)
    except FileNotFoundError:
        if any(pathlib.Path(path).parent == parent and expected != "absent"
               for path, expected in pairs):
            raise SystemExit(f"missing authorized legacy IOMMU parent: {parent}")
        continue
    if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
            or pst.st_uid != 0 or pst.st_gid != 0
            or stat.S_IMODE(pst.st_mode) & 0o022
            or os.path.normpath(os.fspath(parent)) in mounted):
        raise SystemExit(f"unsafe literal legacy IOMMU parent: {parent}")
for raw_path, expected in pairs:
    if expected != "absent" and re.fullmatch(r"[a-f0-9]{64}", expected) is None:
        raise SystemExit("invalid legacy IOMMU hash authority")
    path = pathlib.Path(raw_path)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        continue
    if expected == "absent":
        raise SystemExit(f"unowned legacy IOMMU sidecar appeared: {path}")
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1
            or stat.S_IMODE(st.st_mode) & 0o022):
        raise SystemExit(f"unsafe legacy IOMMU sidecar: {path}")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (st.st_dev, st.st_ino):
            raise SystemExit(f"legacy IOMMU sidecar changed while opening: {path}")
        value = hashlib.sha256()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            value.update(block)
    finally:
        os.close(fd)
    if value.hexdigest() != expected:
        raise SystemExit(f"legacy IOMMU sidecar changed: {path}")
PY
}

write_iommu_remove_pending() {
    local phase="$1"
    [[ "${phase}" == "restoring" || "${phase}" == "candidate-ready" || \
       "${phase}" == "boot-refreshed" ]] || return 1
    validate_iommu_legacy_authority || return 1
    valid_iommu_boot_namespace_names "${IOMMU_BOOT_TARGET}" \
        "${IOMMU_BOOT_STAGE}" && \
    [[ "${IOMMU_BOOT_TARGET}" != "absent" && \
       "${IOMMU_BOOT_TARGET_HASH}" =~ ^[a-f0-9]{64}$ && \
       "${IOMMU_BOOT_STAGE}" != "absent" && \
       "${IOMMU_BOOT_STAGE_NEW}" == "${IOMMU_BOOT_STAGE}.new" && \
       "${IOMMU_BOOT_GENERATOR_ATTEMPTED}" =~ ^[01]$ && \
       "${IOMMU_BOOT_PARENT_DEV}" =~ ^[1-9][0-9]*$ && \
       "${IOMMU_BOOT_PARENT_INO}" =~ ^[1-9][0-9]*$ && \
       "${IOMMU_SOURCE_PARENT_DEV}" =~ ^[1-9][0-9]*$ && \
       "${IOMMU_SOURCE_PARENT_INO}" =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ "${phase}" == "restoring" ]]; then
        [[ "${IOMMU_BOOT_CANDIDATE_HASH}" == "absent" ]] || return 1
    else
        [[ "${IOMMU_BOOT_CANDIDATE_HASH}" =~ ^[a-f0-9]{64}$ && \
           "${IOMMU_BOOT_GENERATOR_ATTEMPTED}" == "1" ]] || return 1
    fi
    durable_write_state "${IOMMU_REMOVE_PENDING}" \
        "format=5" "phase=${phase}" \
        "legacy_grub_backup_sha256=${IOMMU_LEGACY_GRUB_BACKUP_HASH}" \
        "legacy_grub_pending_sha256=${IOMMU_LEGACY_GRUB_PENDING_HASH}" \
        "legacy_cmdline_backup_sha256=${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" \
        "legacy_cmdline_pending_sha256=${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" \
        "boot_target=${IOMMU_BOOT_TARGET}" \
        "boot_target_sha256=${IOMMU_BOOT_TARGET_HASH}" \
        "boot_candidate_sha256=${IOMMU_BOOT_CANDIDATE_HASH}" \
        "boot_stage=${IOMMU_BOOT_STAGE}" \
        "boot_stage_new=${IOMMU_BOOT_STAGE_NEW}" \
        "boot_generator_attempted=${IOMMU_BOOT_GENERATOR_ATTEMPTED}" \
        "boot_parent_dev=${IOMMU_BOOT_PARENT_DEV}" \
        "boot_parent_ino=${IOMMU_BOOT_PARENT_INO}" \
        "source_parent_dev=${IOMMU_SOURCE_PARENT_DEV}" \
        "source_parent_ino=${IOMMU_SOURCE_PARENT_INO}"
}

IOMMU_PENDING_FORMAT=""
IOMMU_PENDING_PHASE=""
parse_iommu_remove_pending() {
    local -A pending_data=()
    local format

    read_kv_state "${IOMMU_REMOVE_PENDING}" \
        "format,phase,legacy_grub_backup_sha256,legacy_grub_pending_sha256,legacy_cmdline_backup_sha256,legacy_cmdline_pending_sha256,boot_target,boot_target_sha256,boot_candidate_sha256,boot_stage,boot_stage_new,boot_generator_attempted,boot_parent_dev,boot_parent_ino,source_parent_dev,source_parent_ino" \
        pending_data || return 1
    format="${pending_data[format]:-}"
    IOMMU_PENDING_FORMAT="${format}"
    IOMMU_PENDING_PHASE="${pending_data[phase]:-}"
    [[ "${IOMMU_PENDING_PHASE}" == "restoring" || \
       "${IOMMU_PENDING_PHASE}" == "candidate-ready" || \
       "${IOMMU_PENDING_PHASE}" == "boot-refreshed" ]] || return 1
    if [[ "${format}" == "1" ]]; then
        (( ${#pending_data[@]} == 2 )) || return 1
        set_iommu_legacy_absent_authority
        IOMMU_BOOT_TARGET=absent
        IOMMU_BOOT_TARGET_HASH=absent
        IOMMU_BOOT_CANDIDATE_HASH=absent
        IOMMU_BOOT_STAGE=absent
        IOMMU_BOOT_PARENT_DEV=absent
        IOMMU_BOOT_PARENT_INO=absent
        set_iommu_extended_boot_absent_authority
    elif [[ "${format}" == "2" ]]; then
        (( ${#pending_data[@]} == 6 )) || return 1
        IOMMU_LEGACY_GRUB_BACKUP_HASH="${pending_data[legacy_grub_backup_sha256]:-}"
        IOMMU_LEGACY_GRUB_PENDING_HASH="${pending_data[legacy_grub_pending_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_BACKUP_HASH="${pending_data[legacy_cmdline_backup_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_PENDING_HASH="${pending_data[legacy_cmdline_pending_sha256]:-}"
        valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_PENDING_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" || return 1
        IOMMU_BOOT_TARGET=absent
        IOMMU_BOOT_TARGET_HASH=absent
        IOMMU_BOOT_CANDIDATE_HASH=absent
        IOMMU_BOOT_STAGE=absent
        IOMMU_BOOT_PARENT_DEV=absent
        IOMMU_BOOT_PARENT_INO=absent
        set_iommu_extended_boot_absent_authority
    elif [[ "${format}" == "3" ]]; then
        (( ${#pending_data[@]} == 10 )) || return 1
        IOMMU_LEGACY_GRUB_BACKUP_HASH="${pending_data[legacy_grub_backup_sha256]:-}"
        IOMMU_LEGACY_GRUB_PENDING_HASH="${pending_data[legacy_grub_pending_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_BACKUP_HASH="${pending_data[legacy_cmdline_backup_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_PENDING_HASH="${pending_data[legacy_cmdline_pending_sha256]:-}"
        IOMMU_BOOT_TARGET="${pending_data[boot_target]:-}"
        IOMMU_BOOT_TARGET_HASH="${pending_data[boot_target_sha256]:-}"
        IOMMU_BOOT_CANDIDATE_HASH="${pending_data[boot_candidate_sha256]:-}"
        IOMMU_BOOT_STAGE="${pending_data[boot_stage]:-}"
        IOMMU_BOOT_PARENT_DEV=absent
        IOMMU_BOOT_PARENT_INO=absent
        set_iommu_extended_boot_absent_authority
        valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_PENDING_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" || return 1
        [[ "${IOMMU_BOOT_TARGET_HASH}" =~ ^[a-f0-9]{64}$ ]] && \
            valid_iommu_boot_namespace_names "${IOMMU_BOOT_TARGET}" \
                "${IOMMU_BOOT_STAGE}" || return 1
        if [[ "${IOMMU_PENDING_PHASE}" == "restoring" ]]; then
            [[ "${IOMMU_BOOT_CANDIDATE_HASH}" == "absent" ]] || return 1
        else
            [[ "${IOMMU_BOOT_CANDIDATE_HASH}" =~ ^[a-f0-9]{64}$ ]] || return 1
        fi
    elif [[ "${format}" == "4" ]]; then
        (( ${#pending_data[@]} == 12 )) || return 1
        IOMMU_LEGACY_GRUB_BACKUP_HASH="${pending_data[legacy_grub_backup_sha256]:-}"
        IOMMU_LEGACY_GRUB_PENDING_HASH="${pending_data[legacy_grub_pending_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_BACKUP_HASH="${pending_data[legacy_cmdline_backup_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_PENDING_HASH="${pending_data[legacy_cmdline_pending_sha256]:-}"
        IOMMU_BOOT_TARGET="${pending_data[boot_target]:-}"
        IOMMU_BOOT_TARGET_HASH="${pending_data[boot_target_sha256]:-}"
        IOMMU_BOOT_CANDIDATE_HASH="${pending_data[boot_candidate_sha256]:-}"
        IOMMU_BOOT_STAGE="${pending_data[boot_stage]:-}"
        IOMMU_BOOT_PARENT_DEV="${pending_data[boot_parent_dev]:-}"
        IOMMU_BOOT_PARENT_INO="${pending_data[boot_parent_ino]:-}"
        IOMMU_BOOT_STAGE_NEW=absent
        IOMMU_BOOT_GENERATOR_ATTEMPTED=0
        IOMMU_SOURCE_PARENT_DEV=absent
        IOMMU_SOURCE_PARENT_INO=absent
        valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_PENDING_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" || return 1
        [[ "${IOMMU_BOOT_TARGET_HASH}" =~ ^[a-f0-9]{64}$ && \
           "${IOMMU_BOOT_PARENT_DEV}" =~ ^[1-9][0-9]*$ && \
           "${IOMMU_BOOT_PARENT_INO}" =~ ^[1-9][0-9]*$ ]] && \
            valid_iommu_boot_namespace_names "${IOMMU_BOOT_TARGET}" \
                "${IOMMU_BOOT_STAGE}" || return 1
        if [[ "${IOMMU_PENDING_PHASE}" == "restoring" ]]; then
            [[ "${IOMMU_BOOT_CANDIDATE_HASH}" == "absent" ]] || return 1
        else
            [[ "${IOMMU_BOOT_CANDIDATE_HASH}" =~ ^[a-f0-9]{64}$ ]] || return 1
        fi
    elif [[ "${format}" == "5" ]]; then
        (( ${#pending_data[@]} == 16 )) || return 1
        IOMMU_LEGACY_GRUB_BACKUP_HASH="${pending_data[legacy_grub_backup_sha256]:-}"
        IOMMU_LEGACY_GRUB_PENDING_HASH="${pending_data[legacy_grub_pending_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_BACKUP_HASH="${pending_data[legacy_cmdline_backup_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_PENDING_HASH="${pending_data[legacy_cmdline_pending_sha256]:-}"
        IOMMU_BOOT_TARGET="${pending_data[boot_target]:-}"
        IOMMU_BOOT_TARGET_HASH="${pending_data[boot_target_sha256]:-}"
        IOMMU_BOOT_CANDIDATE_HASH="${pending_data[boot_candidate_sha256]:-}"
        IOMMU_BOOT_STAGE="${pending_data[boot_stage]:-}"
        IOMMU_BOOT_STAGE_NEW="${pending_data[boot_stage_new]:-}"
        IOMMU_BOOT_GENERATOR_ATTEMPTED="${pending_data[boot_generator_attempted]:-}"
        IOMMU_BOOT_PARENT_DEV="${pending_data[boot_parent_dev]:-}"
        IOMMU_BOOT_PARENT_INO="${pending_data[boot_parent_ino]:-}"
        IOMMU_SOURCE_PARENT_DEV="${pending_data[source_parent_dev]:-}"
        IOMMU_SOURCE_PARENT_INO="${pending_data[source_parent_ino]:-}"
        valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_PENDING_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" || return 1
        [[ "${IOMMU_BOOT_TARGET_HASH}" =~ ^[a-f0-9]{64}$ && \
           "${IOMMU_BOOT_STAGE_NEW}" == "${IOMMU_BOOT_STAGE}.new" && \
           "${IOMMU_BOOT_GENERATOR_ATTEMPTED}" =~ ^[01]$ && \
           "${IOMMU_BOOT_PARENT_DEV}" =~ ^[1-9][0-9]*$ && \
           "${IOMMU_BOOT_PARENT_INO}" =~ ^[1-9][0-9]*$ && \
           "${IOMMU_SOURCE_PARENT_DEV}" =~ ^[1-9][0-9]*$ && \
           "${IOMMU_SOURCE_PARENT_INO}" =~ ^[1-9][0-9]*$ ]] && \
            valid_iommu_boot_namespace_names "${IOMMU_BOOT_TARGET}" \
                "${IOMMU_BOOT_STAGE}" || return 1
        if [[ "${IOMMU_PENDING_PHASE}" == "restoring" ]]; then
            [[ "${IOMMU_BOOT_CANDIDATE_HASH}" == "absent" ]] || return 1
        else
            [[ "${IOMMU_BOOT_CANDIDATE_HASH}" =~ ^[a-f0-9]{64}$ && \
               "${IOMMU_BOOT_GENERATOR_ATTEMPTED}" == "1" ]] || return 1
        fi
    else
        return 1
    fi
    validate_iommu_legacy_authority
}

parse_iommu_state() {
    local actual_base actual_expected

    read_kv_state "${IOMMU_STATE}" \
        "format,backend,source,base_sha256,expected_sha256,generator,target,key,legacy_grub_backup_sha256,legacy_grub_pending_sha256,legacy_cmdline_backup_sha256,legacy_cmdline_pending_sha256" \
        IOMMU_DATA || return 1
    [[ "${IOMMU_DATA[format]:-}" == "1" || \
       "${IOMMU_DATA[format]:-}" == "2" ]] || return 1
    IOMMU_BACKEND="${IOMMU_DATA[backend]:-}"
    IOMMU_SOURCE="${IOMMU_DATA[source]:-}"
    IOMMU_BASE_HASH="${IOMMU_DATA[base_sha256]:-}"
    IOMMU_EXPECTED_HASH="${IOMMU_DATA[expected_sha256]:-}"
    IOMMU_GENERATOR="${IOMMU_DATA[generator]:-}"
    IOMMU_TARGET="${IOMMU_DATA[target]:-}"
    IOMMU_KEY="${IOMMU_DATA[key]:-}"
    if [[ "${IOMMU_DATA[format]}" == "1" ]]; then
        (( ${#IOMMU_DATA[@]} == 8 )) || return 1
        set_iommu_legacy_absent_authority
    else
        (( ${#IOMMU_DATA[@]} == 12 )) || return 1
        IOMMU_LEGACY_GRUB_BACKUP_HASH="${IOMMU_DATA[legacy_grub_backup_sha256]:-}"
        IOMMU_LEGACY_GRUB_PENDING_HASH="${IOMMU_DATA[legacy_grub_pending_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_BACKUP_HASH="${IOMMU_DATA[legacy_cmdline_backup_sha256]:-}"
        IOMMU_LEGACY_CMDLINE_PENDING_HASH="${IOMMU_DATA[legacy_cmdline_pending_sha256]:-}"
        valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_GRUB_PENDING_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" && \
            valid_iommu_legacy_hash "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" || return 1
    fi
    [[ "${IOMMU_BASE_HASH}" =~ ^[a-f0-9]{64}$ && \
       "${IOMMU_EXPECTED_HASH}" =~ ^[a-f0-9]{64}$ ]] || return 1

    case "${IOMMU_BACKEND}|${IOMMU_SOURCE}|${IOMMU_GENERATOR}|${IOMMU_TARGET}|${IOMMU_KEY}" in
        "grub|/etc/default/grub|update-grub|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
        "grub|/etc/default/grub|update-grub|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX"|\
        "grub|/etc/default/grub|grub2-mkconfig|/boot/grub2/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
        "grub|/etc/default/grub|grub2-mkconfig|/boot/grub2/grub.cfg|GRUB_CMDLINE_LINUX"|\
        "grub|/etc/default/grub|grub2-mkconfig|/boot/efi/EFI/"*"/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
        "grub|/etc/default/grub|grub2-mkconfig|/boot/efi/EFI/"*"/grub.cfg|GRUB_CMDLINE_LINUX"|\
        "grub|/etc/default/grub|grub-mkconfig|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX_DEFAULT"|\
        "grub|/etc/default/grub|grub-mkconfig|/boot/grub/grub.cfg|GRUB_CMDLINE_LINUX") ;;
        "kernel-cmdline|/etc/kernel/cmdline|kernel-install|/boot/loader/entries|-") ;;
        *) return 1 ;;
    esac
    if [[ "${IOMMU_TARGET}" == /boot/efi/EFI/* ]]; then
        [[ "${IOMMU_TARGET}" =~ ^/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg$ && \
           "$(basename -- "$(dirname -- "${IOMMU_TARGET}")")" != "." && \
           "$(basename -- "$(dirname -- "${IOMMU_TARGET}")")" != ".." ]] || return 1
    fi
    validate_root_file "${IOMMU_BASE}" 0 && validate_root_file "${IOMMU_EXPECTED}" 0 || return 1
    actual_base="$(sha256_regular "${IOMMU_BASE}")" || return 1
    actual_expected="$(sha256_regular "${IOMMU_EXPECTED}")" || return 1
    [[ "${actual_base}" == "${IOMMU_BASE_HASH}" && \
       "${actual_expected}" == "${IOMMU_EXPECTED_HASH}" ]] || return 1
    inspect_iommu_source_namespace "${IOMMU_SOURCE}" || return 1
    [[ "${IOMMU_SOURCE_NAMESPACE_HASH}" == "${IOMMU_BASE_HASH}" || \
       "${IOMMU_SOURCE_NAMESPACE_HASH}" == "${IOMMU_EXPECTED_HASH}" ]] || return 1
    validate_iommu_legacy_authority || return 1
}

iommu_params_for_cpu() {
    local vendor
    vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    case "${vendor}" in
        GenuineIntel) printf '%s\n' 'intel_iommu=on iommu=pt' ;;
        AuthenticAMD) printf '%s\n' 'amd_iommu=on iommu=pt' ;;
        *) return 1 ;;
    esac
}

GRUB_GENERATOR_EXECUTABLE=""
GRUB_SCRIPT_CHECK_EXECUTABLE=""
select_fixed_grub_generator() {
    local generator="$1" candidate
    local -a candidates=()

    case "${generator}" in
        update-grub|grub-mkconfig)
            candidates=(/usr/sbin/grub-mkconfig /usr/bin/grub-mkconfig)
            ;;
        grub2-mkconfig)
            candidates=(/usr/sbin/grub2-mkconfig /usr/bin/grub2-mkconfig)
            ;;
        *) return 1 ;;
    esac
    GRUB_GENERATOR_EXECUTABLE=""
    GRUB_SCRIPT_CHECK_EXECUTABLE=""
    for candidate in "${candidates[@]}"; do
        [[ -e "${candidate}" || -L "${candidate}" ]] || continue
        if validate_trusted_executable "${candidate}"; then
            GRUB_GENERATOR_EXECUTABLE="${candidate}"
            break
        fi
    done
    [[ -n "${GRUB_GENERATOR_EXECUTABLE}" ]] || return 1
    for candidate in /usr/bin/grub-script-check /usr/sbin/grub-script-check; do
        [[ -e "${candidate}" || -L "${candidate}" ]] || continue
        if validate_trusted_executable "${candidate}"; then
            GRUB_SCRIPT_CHECK_EXECUTABLE="${candidate}"
            break
        fi
    done
    [[ -n "${GRUB_SCRIPT_CHECK_EXECUTABLE}" ]]
}

grub_generator_sanitized() {
    local output="$1"
    /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C "${GRUB_GENERATOR_EXECUTABLE}" -o "${output}"
}

grub_script_check_sanitized() {
    /usr/bin/env -i PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root \
        LC_ALL=C LANG=C "${GRUB_SCRIPT_CHECK_EXECUTABLE}" "$1"
}

select_legacy_grub_generator() {
    local target
    local -a candidates=()

    for target in /boot/grub/grub.cfg /boot/grub2/grub.cfg \
                  /boot/efi/EFI/*/grub.cfg; do
        if [[ -e "${target}" || -L "${target}" ]]; then
            [[ -f "${target}" && ! -L "${target}" ]] || return 1
            candidates+=("${target}")
        fi
    done
    # Historical installers selected a tool by then-current availability and,
    # for grub2, preferred the first EFI match.  A backup alone cannot prove
    # which of multiple live outputs was active, so migration is allowed only
    # when the historical target namespace is unique today.
    (( ${#candidates[@]} == 1 )) || return 1
    IOMMU_TARGET="${candidates[0]}"
    case "${IOMMU_TARGET}" in
        /boot/grub/grub.cfg) IOMMU_GENERATOR="grub-mkconfig" ;;
        /boot/grub2/grub.cfg|/boot/efi/EFI/*/grub.cfg)
            IOMMU_GENERATOR="grub2-mkconfig"
            ;;
        *) return 1 ;;
    esac
    select_fixed_grub_generator "${IOMMU_GENERATOR}" >/dev/null
}

generate_legacy_expected() {
    local backend="$1" source="$2" output="$3" key="$4" params="$5"

    command -v python3 &>/dev/null || return 1
    python3 - "${backend}" "${source}" "${output}" "${key}" "${params}" <<'PY'
import os
import re
import shlex
import sys

backend, source, output, key, params = sys.argv[1:]
with open(source, "r", encoding="utf-8", newline="") as handle:
    original = handle.read()

def merge(value):
    tokens = shlex.split(value, posix=True)
    kept = [token for token in tokens
            if not (token.startswith("intel_iommu=") or
                    token.startswith("amd_iommu=") or
                    token.startswith("iommu="))]
    kept.extend(params.split())
    return " ".join(kept)

if backend == "grub":
    pattern = re.compile(rf'^{re.escape(key)}="([^"]*)"$', re.MULTILINE)
    matches = list(pattern.finditer(original))
    if len(matches) > 1:
        raise SystemExit("legacy GRUB source does not contain one exact managed assignment")
    if len(matches) == 1:
        match = matches[0]
        replacement = f'{key}="{merge(match.group(1))}"'
        expected = original[:match.start()] + replacement + original[match.end():]
    else:
        # The historical installer selected GRUB_CMDLINE_LINUX when neither
        # managed key existed, then appended that exact assignment with printf.
        # Reproduce only that byte-exact absent-key branch; malformed or
        # alternate assignments remain ambiguous and fail closed.
        if (key != "GRUB_CMDLINE_LINUX"
                or re.search(r"^(?:GRUB_CMDLINE_LINUX_DEFAULT|GRUB_CMDLINE_LINUX)=",
                             original, re.MULTILINE) is not None):
            raise SystemExit("legacy GRUB managed assignment is ambiguous")
        expected = original + f'{key}="{merge("")}"\n'
elif backend == "kernel-cmdline":
    if "\n" in original.rstrip("\n"):
        raise SystemExit("legacy kernel cmdline is not one line")
    expected = merge(original.rstrip("\n")) + "\n"
else:
    raise SystemExit("unknown backend")

with open(output, "w", encoding="utf-8", newline="") as handle:
    handle.write(expected)
    handle.flush()
    os.fsync(handle.fileno())
PY
}

migrate_legacy_iommu() {
    local grub_backup="/etc/default/grub.cmpunlocker.bak"
    local cmdline_backup="/etc/kernel/cmdline.cmpunlocker.bak"
    local source backup backend key params temp current_hash base_hash expected_hash
    local grub_present=0 cmdline_present=0 sidecar sidecar_count=0

    for sidecar in "${grub_backup}" /etc/default/grub.cmpunlocker.pending \
                   "${cmdline_backup}" /etc/kernel/cmdline.cmpunlocker.pending; do
        [[ -e "${sidecar}" || -L "${sidecar}" ]] && sidecar_count=$((sidecar_count + 1))
    done
    [[ -e "${grub_backup}" || -L "${grub_backup}" ]] && grub_present=1
    [[ -e "${cmdline_backup}" || -L "${cmdline_backup}" ]] && cmdline_present=1
    (( grub_present + cmdline_present <= 1 )) || \
        die "Both legacy IOMMU backends have backups; refusing ambiguous migration"
    (( grub_present + cmdline_present == 1 )) || return 0
    (( sidecar_count == 1 )) || \
        die "Legacy IOMMU migration requires one backup and all other shared sidecars absent"
    if (( grub_present == 1 )); then
        backend="grub"
        source="/etc/default/grub"
        backup="${grub_backup}"
        key="GRUB_CMDLINE_LINUX_DEFAULT"
        grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "${backup}" || key="GRUB_CMDLINE_LINUX"
        select_legacy_grub_generator || \
            die "Cannot bind the legacy GRUB backup to one explicit generator and target"
    else
        backend="kernel-cmdline"
        source="/etc/kernel/cmdline"
        backup="${cmdline_backup}"
        key="-"
        IOMMU_GENERATOR="kernel-install"
        IOMMU_TARGET="/boot/loader/entries"
    fi
    validate_root_file "${source}" 0 && validate_root_file "${backup}" 0 || \
        die "Unsafe legacy IOMMU source or backup"
    params="$(iommu_params_for_cpu)" || die "Cannot deterministically derive legacy IOMMU parameters"
    temp="$(mktemp -t cmpunlocker-iommu-expected.XXXXXX)"
    if ! generate_legacy_expected "${backend}" "${backup}" "${temp}" "${key}" "${params}"; then
        rm -f -- "${temp}"
        die "Cannot deterministically derive the legacy post-install IOMMU file"
    fi
    current_hash="$(sha256_regular "${source}")"
    base_hash="$(sha256_regular "${backup}")"
    expected_hash="$(sha256sum -- "${temp}" | awk '{print $1}')"
    [[ "${current_hash}" == "${base_hash}" || "${current_hash}" == "${expected_hash}" ]] || {
        rm -f -- "${temp}"
        die "Legacy IOMMU source has post-install edits; preserving it for manual reconciliation"
    }
    # The same remove-side journal is used here before publishing either
    # snapshot.  With no iommu.state, phase=restoring unambiguously means an
    # interrupted deterministic legacy migration and is safe to restart.
    set_iommu_legacy_absent_authority
    if [[ "${backup}" == "${grub_backup}" ]]; then
        IOMMU_LEGACY_GRUB_BACKUP_HASH="${base_hash}"
    else
        IOMMU_LEGACY_CMDLINE_BACKUP_HASH="${base_hash}"
    fi
    validate_iommu_legacy_authority || {
        rm -f -- "${temp}"
        die "Legacy IOMMU sidecar changed before ownership journaling"
    }
    durable_write_state "${IOMMU_REMOVE_PENDING}" \
        "format=2" "phase=restoring" \
        "legacy_grub_backup_sha256=${IOMMU_LEGACY_GRUB_BACKUP_HASH}" \
        "legacy_grub_pending_sha256=${IOMMU_LEGACY_GRUB_PENDING_HASH}" \
        "legacy_cmdline_backup_sha256=${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" \
        "legacy_cmdline_pending_sha256=${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" || {
        rm -f -- "${temp}"
        die "Could not begin durable legacy IOMMU migration"
    }
    atomic_copy_file "${backup}" "${IOMMU_BASE}" || { rm -f -- "${temp}"; die "Could not publish IOMMU base"; }
    atomic_copy_file "${temp}" "${IOMMU_EXPECTED}" || { rm -f -- "${temp}"; die "Could not publish IOMMU expected snapshot"; }
    rm -f -- "${temp}"
    IOMMU_BASE_HASH="$(sha256_regular "${IOMMU_BASE}")"
    IOMMU_EXPECTED_HASH="$(sha256_regular "${IOMMU_EXPECTED}")"
    durable_write_state "${IOMMU_STATE}" \
        "format=2" "backend=${backend}" "source=${source}" \
        "base_sha256=${IOMMU_BASE_HASH}" "expected_sha256=${IOMMU_EXPECTED_HASH}" \
        "generator=${IOMMU_GENERATOR}" "target=${IOMMU_TARGET}" "key=${key}" \
        "legacy_grub_backup_sha256=${IOMMU_LEGACY_GRUB_BACKUP_HASH}" \
        "legacy_grub_pending_sha256=${IOMMU_LEGACY_GRUB_PENDING_HASH}" \
        "legacy_cmdline_backup_sha256=${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" \
        "legacy_cmdline_pending_sha256=${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" || \
        die "Could not publish migrated IOMMU state"
    durable_remove_file "${IOMMU_REMOVE_PENDING}" || \
        die "Could not commit migrated IOMMU ownership state"
    ok "Migrated byte-exact legacy ${backend} IOMMU state into a durable receipt"
}

remove_legacy_iommu_files() {
    validate_iommu_legacy_authority || return 1
    python3 - \
        /etc/default/grub.cmpunlocker.bak "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" \
        /etc/default/grub.cmpunlocker.pending "${IOMMU_LEGACY_GRUB_PENDING_HASH}" \
        /etc/kernel/cmdline.cmpunlocker.bak "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}" \
        /etc/kernel/cmdline.cmpunlocker.pending "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

pairs = [(pathlib.Path(path), expected)
         for path, expected in zip(sys.argv[1::2], sys.argv[2::2])]
expected_paths = [
    pathlib.Path("/etc/default/grub.cmpunlocker.bak"),
    pathlib.Path("/etc/default/grub.cmpunlocker.pending"),
    pathlib.Path("/etc/kernel/cmdline.cmpunlocker.bak"),
    pathlib.Path("/etc/kernel/cmdline.cmpunlocker.pending"),
]
if [path for path, unused in pairs] != expected_paths:
    raise SystemExit("invalid legacy IOMMU deletion paths")

def mount_points():
    result = []
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields = left.split(b" ")
            tail = right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not field for field in fields)
                    or any(not field for field in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded = fields[4]
            decoded = bytearray()
            index = 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index])
                    index += 1
                    continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8))
                index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mountinfo mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.append(mount)
            result.append(os.path.normpath(os.path.realpath(mount)))
    return set(result)

def reject_file_mounts():
    mounts = mount_points()
    for parent in (pathlib.Path("/etc/default"), pathlib.Path("/etc/kernel")):
        if (os.path.normpath(os.fspath(parent)) in mounts
                or os.path.normpath(os.path.realpath(parent)) in mounts):
            raise SystemExit(f"mount blocks legacy IOMMU parent: {parent}")
    for path, unused in pairs:
        aliases = {os.path.normpath(os.fspath(path)),
                   os.path.normpath(os.path.realpath(path))}
        if aliases & mounts:
            raise SystemExit(f"mount blocks legacy IOMMU cleanup: {path}")

reject_file_mounts()
parents = {}
opened = []
try:
    for path, expected in pairs:
        if expected != "absent" and re.fullmatch(r"[a-f0-9]{64}", expected) is None:
            raise SystemExit("invalid legacy IOMMU deletion hash")
        parent = path.parent
        if parent not in parents:
            parent_lst = os.lstat(parent)
            dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                          | getattr(os, "O_CLOEXEC", 0)
                          | getattr(os, "O_NOFOLLOW", 0))
            pst = os.fstat(dfd)
            if ((pst.st_dev, pst.st_ino) != (parent_lst.st_dev, parent_lst.st_ino)
                    or not stat.S_ISDIR(pst.st_mode) or pst.st_uid != 0 or pst.st_gid != 0
                    or stat.S_IMODE(pst.st_mode) & 0o022):
                raise SystemExit(f"unsafe legacy IOMMU parent: {parent}")
            parents[parent] = (dfd, pst, parent_lst)
        dfd, pst, parent_lst = parents[parent]
        try:
            lst = os.stat(path.name, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if expected == "absent":
            raise SystemExit(f"unowned legacy IOMMU sidecar appeared: {path}")
        fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                     | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
        fst = os.fstat(fd)
        if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
                or not stat.S_ISREG(fst.st_mode) or fst.st_uid != 0
                or fst.st_gid != 0 or fst.st_nlink != 1
                or stat.S_IMODE(fst.st_mode) & 0o022 or fst.st_dev != pst.st_dev):
            os.close(fd)
            raise SystemExit(f"unsafe legacy IOMMU sidecar: {path}")
        value = hashlib.sha256()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            value.update(block)
        if value.hexdigest() != expected:
            os.close(fd)
            raise SystemExit(f"legacy IOMMU sidecar changed before deletion: {path}")
        opened.append((path, dfd, fd, fst))
    reject_file_mounts()
    # All four shared names have been proven before the first unlink.
    for path, dfd, fd, fst in opened:
        reject_file_mounts()
        parent_lst = os.lstat(path.parent)
        parent_opened = os.fstat(dfd)
        if ((parent_lst.st_dev, parent_lst.st_ino) !=
                (parent_opened.st_dev, parent_opened.st_ino)):
            raise SystemExit(f"legacy IOMMU parent changed before deletion: {path.parent}")
        current = os.stat(path.name, dir_fd=dfd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (fst.st_dev, fst.st_ino):
            raise SystemExit(f"legacy IOMMU pathname changed before deletion: {path}")
        os.unlink(path.name, dir_fd=dfd)
        os.fsync(dfd)
finally:
    for unused_path, unused_dfd, fd, unused_st in opened:
        os.close(fd)
    for dfd, unused_st, unused_lst in parents.values():
        os.close(dfd)
PY
}

IOMMU_BOOT_NAMESPACE_TARGET_HASH=""
IOMMU_BOOT_NAMESPACE_STAGE_HASH=""
IOMMU_BOOT_NAMESPACE_NEW_HASH=""
IOMMU_BOOT_NAMESPACE_PARENT_DEV=""
IOMMU_BOOT_NAMESPACE_PARENT_INO=""
inspect_iommu_boot_namespace() {
    local target="$1" stage="$2" stage_policy="$3"
    local new_policy="${4:-absent}" output
    local -a values=()

    output="$(python3 - "${target}" "${stage}" "${stage_policy}" \
        "${new_policy}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

target, stage = map(pathlib.Path, sys.argv[1:3])
policy, new_policy = sys.argv[3:5]
stage_new = pathlib.Path(os.fspath(stage) + ".new")
allowed = (target in (pathlib.Path("/boot/grub/grub.cfg"),
                      pathlib.Path("/boot/grub2/grub.cfg"))
           or re.fullmatch(r"/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg",
                           os.fspath(target)) is not None)
if (not allowed or (os.fspath(target).startswith("/boot/efi/EFI/")
                    and target.parent.name in (".", ".."))
        or policy not in ("absent", "present", "optional")
        or new_policy not in ("absent", "present", "optional")):
    raise SystemExit("invalid boot namespace authority")
parent = target.parent
if stage.parent != parent:
    raise SystemExit("boot stage is not beside its target")
if re.fullmatch(rf"\.cmpunlocker-remove\.{re.escape(target.name)}\.boot\.[a-f0-9]{{6}}",
                stage.name) is None:
    raise SystemExit("invalid boot stage name")
if stage_new.parent != parent or stage_new.name != stage.name + ".new":
    raise SystemExit("invalid implicit boot generator temp name")

dir_flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
             | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
ancestor_fds = []
chain = []
root_fd = os.open("/", dir_flags)
ancestor_fds.append(root_fd)
root_st = os.fstat(root_fd)
if (not stat.S_ISDIR(root_st.st_mode) or root_st.st_uid != 0
        or root_st.st_gid != 0 or stat.S_IMODE(root_st.st_mode) & 0o022):
    raise SystemExit("unsafe boot root directory")
current_fd = root_fd
for component in parent.parts[1:]:
    lst = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
    child_fd = os.open(component, dir_flags, dir_fd=current_fd)
    fst = os.fstat(child_fd)
    if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISDIR(fst.st_mode) or fst.st_uid != 0
            or fst.st_gid != 0 or stat.S_IMODE(fst.st_mode) & 0o022):
        raise SystemExit(f"unsafe boot ancestor: {component}")
    chain.append((current_fd, component, child_fd, fst))
    ancestor_fds.append(child_fd)
    current_fd = child_fd
dfd = current_fd
pst = os.fstat(dfd)

def verify_chain():
    opened_root = os.fstat(root_fd)
    if ((opened_root.st_dev, opened_root.st_ino) !=
            (root_st.st_dev, root_st.st_ino)
            or opened_root.st_uid != 0 or opened_root.st_gid != 0
            or stat.S_IMODE(opened_root.st_mode) & 0o022):
        raise SystemExit("boot root identity changed")
    for parent_fd, name, child_fd, expected in chain:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(child_fd)
        if ((current.st_dev, current.st_ino) !=
                (expected.st_dev, expected.st_ino)
                or (opened.st_dev, opened.st_ino) !=
                   (expected.st_dev, expected.st_ino)
                or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != 0
                or opened.st_gid != 0 or stat.S_IMODE(opened.st_mode) & 0o022):
            raise SystemExit("boot ancestor identity changed")

def digest_fd(fd):
    value = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        value.update(block)
    return value.hexdigest()

def mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

mounted = mounts()
allowed_ancestor_mounts = {"/", "/boot", "/boot/efi"}
ancestor_path = pathlib.Path("/")
for component in parent.parts[1:]:
    ancestor_path /= component
    normalized = os.path.normpath(os.fspath(ancestor_path))
    if normalized in mounted and normalized not in allowed_ancestor_mounts:
        raise SystemExit(f"mount redirects boot output ancestor: {ancestor_path}")
for path in (target, stage, stage_new):
    aliases = {os.path.normpath(os.fspath(path)),
               os.path.normpath(os.path.realpath(path))}
    if aliases & mounted:
        raise SystemExit(f"mount blocks boot output transaction: {path}")
tfd = sfd = nfd = -1
try:
    verify_chain()
    target_lst = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    tfd = os.open(target.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                  | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    tst = os.fstat(tfd)
    if ((tst.st_dev, tst.st_ino) != (target_lst.st_dev, target_lst.st_ino)
            or not stat.S_ISREG(tst.st_mode) or tst.st_uid != 0 or tst.st_gid != 0
            or tst.st_nlink != 1 or stat.S_IMODE(tst.st_mode) & 0o022
            or tst.st_dev != pst.st_dev or tst.st_size <= 0):
        raise SystemExit("unsafe live boot output")
    target_hash = digest_fd(tfd)
    try:
        stage_lst = os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
        sfd = os.open(stage.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                      | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    except FileNotFoundError:
        if policy == "present":
            raise SystemExit("required boot stage is absent")
        stage_hash = "absent"
    else:
        sst = os.fstat(sfd)
        if ((sst.st_dev, sst.st_ino) != (stage_lst.st_dev, stage_lst.st_ino)
                or not stat.S_ISREG(sst.st_mode) or sst.st_uid != 0
                or sst.st_gid != 0 or sst.st_nlink != 1
                or stat.S_IMODE(sst.st_mode) & 0o022
                or sst.st_dev != pst.st_dev):
            raise SystemExit("unsafe boot stage")
        stage_hash = digest_fd(sfd)
        if policy == "absent":
            raise SystemExit("boot stage collision")
    try:
        new_lst = os.stat(stage_new.name, dir_fd=dfd, follow_symlinks=False)
        nfd = os.open(stage_new.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                      | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    except FileNotFoundError:
        if new_policy == "present":
            raise SystemExit("required implicit boot generator temp is absent")
        new_hash = "absent"
    else:
        nst = os.fstat(nfd)
        if ((nst.st_dev, nst.st_ino) != (new_lst.st_dev, new_lst.st_ino)
                or not stat.S_ISREG(nst.st_mode) or nst.st_uid != 0
                or nst.st_gid != 0 or nst.st_nlink != 1
                or stat.S_IMODE(nst.st_mode) & 0o022
                or nst.st_dev != pst.st_dev):
            raise SystemExit("unsafe implicit boot generator temp")
        new_hash = digest_fd(nfd)
        if new_policy == "absent":
            raise SystemExit("implicit boot generator temp collision")
    verify_chain()
    current_target = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    if ((current_target.st_dev, current_target.st_ino) !=
            (tst.st_dev, tst.st_ino) or digest_fd(tfd) != target_hash):
        raise SystemExit("boot target changed during inspection")
    if sfd >= 0:
        current_stage = os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
        if ((current_stage.st_dev, current_stage.st_ino) !=
                (sst.st_dev, sst.st_ino) or digest_fd(sfd) != stage_hash):
            raise SystemExit("boot stage changed during inspection")
    else:
        try:
            os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise SystemExit("boot stage appeared during inspection")
    if nfd >= 0:
        current_new = os.stat(stage_new.name, dir_fd=dfd, follow_symlinks=False)
        if ((current_new.st_dev, current_new.st_ino) !=
                (nst.st_dev, nst.st_ino) or digest_fd(nfd) != new_hash):
            raise SystemExit("implicit boot generator temp changed during inspection")
    else:
        try:
            os.stat(stage_new.name, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise SystemExit("implicit boot generator temp appeared during inspection")
    if mounted != mounts():
        raise SystemExit("mount namespace changed during boot inspection")
    print(target_hash)
    print(stage_hash)
    print(new_hash)
    print(pst.st_dev)
    print(pst.st_ino)
finally:
    if nfd >= 0:
        os.close(nfd)
    if sfd >= 0:
        os.close(sfd)
    if tfd >= 0:
        os.close(tfd)
    for fd in reversed(ancestor_fds):
        os.close(fd)
PY
    )" || return 1
    mapfile -t values <<< "${output}"
    (( ${#values[@]} == 5 )) || return 1
    [[ "${values[0]}" =~ ^[a-f0-9]{64}$ && \
       ( "${values[1]}" == "absent" || "${values[1]}" =~ ^[a-f0-9]{64}$ ) && \
       ( "${values[2]}" == "absent" || "${values[2]}" =~ ^[a-f0-9]{64}$ ) && \
       "${values[3]}" =~ ^[1-9][0-9]*$ && "${values[4]}" =~ ^[1-9][0-9]*$ ]] || \
        return 1
    IOMMU_BOOT_NAMESPACE_TARGET_HASH="${values[0]}"
    IOMMU_BOOT_NAMESPACE_STAGE_HASH="${values[1]}"
    IOMMU_BOOT_NAMESPACE_NEW_HASH="${values[2]}"
    IOMMU_BOOT_NAMESPACE_PARENT_DEV="${values[3]}"
    IOMMU_BOOT_NAMESPACE_PARENT_INO="${values[4]}"
    if [[ "${IOMMU_BOOT_PARENT_DEV}" != "absent" || \
          "${IOMMU_BOOT_PARENT_INO}" != "absent" ]]; then
        [[ "${IOMMU_BOOT_PARENT_DEV}" == "${IOMMU_BOOT_NAMESPACE_PARENT_DEV}" && \
           "${IOMMU_BOOT_PARENT_INO}" == "${IOMMU_BOOT_NAMESPACE_PARENT_INO}" ]] || \
            return 1
    fi
}


recover_completed_iommu_cleanup() {
    local legacy_count=0 legacy path pending_authority

    [[ -e "${IOMMU_REMOVE_PENDING}" || -L "${IOMMU_REMOVE_PENDING}" ]] || return 1
    parse_iommu_remove_pending || die "Invalid ${IOMMU_REMOVE_PENDING}"
    pending_authority="${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}"
    case "${IOMMU_PENDING_PHASE}" in
        restoring)
            if [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]]; then
                # Either a normal restoration is awaiting its boot generator,
                # or legacy migration published its receipt just before a
                # crash.  Both resume through the normal B/E/current logic.
                parse_iommu_state && \
                    [[ "${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" == \
                       "${pending_authority}" ]] || \
                    die "IOMMU receipt and removal marker grant different legacy authority"
                [[ ( "${IOMMU_PENDING_FORMAT}" != "4" && \
                     "${IOMMU_PENDING_FORMAT}" != "5" ) || \
                   "${IOMMU_BOOT_TARGET}" == "${IOMMU_TARGET}" ]] || \
                    die "IOMMU removal marker targets a different boot output"
                [[ "${IOMMU_PENDING_FORMAT}" != "3" ]] || \
                    die "IOMMU removal marker lacks containing-filesystem identity"
                return 1
            fi
            [[ "${IOMMU_PENDING_FORMAT}" == "2" ]] || \
                die "IOMMU restoring marker lost a receipt outside legacy migration"
            [[ "${IOMMU_LEGACY_GRUB_PENDING_HASH}" == "absent" && \
               "${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" == "absent" ]] || \
                die "IOMMU migration marker grants unexpected pending-sidecar authority"
            for legacy in "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" \
                          "${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}"; do
                [[ "${legacy}" != "absent" ]] && legacy_count=$((legacy_count + 1))
            done
            (( legacy_count == 1 )) || \
                die "IOMMU restoring marker without a receipt is not bound to one hashed legacy backup"
            if [[ "${IOMMU_LEGACY_GRUB_BACKUP_HASH}" != "absent" ]]; then
                [[ -e /etc/default/grub.cmpunlocker.bak && \
                   ! -L /etc/default/grub.cmpunlocker.bak ]] || \
                    die "Hashed legacy GRUB backup disappeared during migration recovery"
            else
                [[ -e /etc/kernel/cmdline.cmpunlocker.bak && \
                   ! -L /etc/kernel/cmdline.cmpunlocker.bak ]] || \
                    die "Hashed legacy cmdline backup disappeared during migration recovery"
            fi
            for path in "${IOMMU_BASE}" "${IOMMU_EXPECTED}"; do
                if [[ -e "${path}" || -L "${path}" ]]; then
                    durable_remove_file "${path}" || \
                        die "Could not restart interrupted legacy IOMMU migration"
                fi
            done
            durable_remove_file "${IOMMU_REMOVE_PENDING}" || \
                die "Could not clear interrupted legacy IOMMU migration marker"
            info "Restarting an interrupted deterministic legacy IOMMU migration"
            return 1
            ;;
        candidate-ready)
            [[ "${IOMMU_PENDING_FORMAT}" == "5" ]] || \
                die "Candidate-ready IOMMU marker has no exact staged-output proof"
            inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
                "${IOMMU_BOOT_STAGE}" optional || \
                die "IOMMU boot candidate namespace changed after its durable marker"
            if [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
                  "${IOMMU_BOOT_TARGET_HASH}" && \
                  "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == \
                  "${IOMMU_BOOT_CANDIDATE_HASH}" ]]; then
                :
            elif [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
                    "${IOMMU_BOOT_CANDIDATE_HASH}" ]]; then
                [[ "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == "absent" || \
                   "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == \
                     "${IOMMU_BOOT_CANDIDATE_HASH}" ]] || \
                    die "IOMMU published candidate retained an unrelated stage"
            else
                die "IOMMU live boot output matches neither durable transaction hash"
            fi
            [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]] || \
                die "IOMMU candidate-ready marker lost its durable receipt"
            parse_iommu_state && \
                [[ "${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" == \
                   "${pending_authority}" ]] || \
                die "IOMMU receipt and candidate marker grant different legacy authority"
            [[ "${IOMMU_SOURCE_PARENT_DEV}" == \
                 "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" && \
               "${IOMMU_SOURCE_PARENT_INO}" == \
                 "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" ]] || \
                die "IOMMU source parent changed after candidate journaling"
            [[ "${IOMMU_BOOT_TARGET}" == "${IOMMU_TARGET}" ]] || \
                die "IOMMU candidate marker targets a different boot output"
            return 1
            ;;
        boot-refreshed)
            if [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]]; then
                # Keep the receipt until the stock-ready path has rebuilt clean
                # initramfs inputs and can republish the persisted boot target.
                parse_iommu_state && \
                    [[ "${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" == \
                       "${pending_authority}" ]] || \
                    die "IOMMU receipt and committed marker grant different legacy authority"
                [[ "${IOMMU_SOURCE_PARENT_DEV}" == \
                     "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" && \
                   "${IOMMU_SOURCE_PARENT_INO}" == \
                     "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" ]] || \
                    die "IOMMU source parent changed after committed journaling"
                [[ "${IOMMU_PENDING_FORMAT}" == "5" ]] || \
                    die "Committed IOMMU marker lacks exact implicit .new authority"
                if [[ "${IOMMU_PENDING_FORMAT}" == "5" ]]; then
                    [[ "${IOMMU_BOOT_TARGET}" == "${IOMMU_TARGET}" ]] || \
                        die "Committed IOMMU marker targets a different boot output"
                    inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
                        "${IOMMU_BOOT_STAGE}" absent && \
                        [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
                           "${IOMMU_BOOT_CANDIDATE_HASH}" ]] || \
                        die "Committed IOMMU boot output no longer matches its candidate"
                fi
                [[ "${IOMMU_PENDING_FORMAT}" != "3" ]] || \
                    die "Committed IOMMU marker lacks containing-filesystem identity"
                return 1
            fi
            [[ "${IOMMU_PENDING_FORMAT}" == "5" ]] || \
                die "Legacy completed IOMMU marker lacks an exact boot-output proof"
            inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
                "${IOMMU_BOOT_STAGE}" absent && \
                [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
                   "${IOMMU_BOOT_CANDIDATE_HASH}" ]] || \
                die "Completed IOMMU marker does not match the durable live boot output"
            for path in "${IOMMU_STATE}" "${IOMMU_BASE}" "${IOMMU_EXPECTED}"; do
                if [[ -e "${path}" || -L "${path}" ]]; then
                    durable_remove_file "${path}" || die "Could not finish IOMMU state cleanup"
                fi
            done
            remove_legacy_iommu_files || die "Could not finish legacy IOMMU cleanup"
            durable_remove_file "${IOMMU_REMOVE_PENDING}" || \
                die "Could not commit completed IOMMU cleanup"
            ok "Recovered a completed IOMMU boot-output transaction"
            return 0
            ;;
        *) die "Unknown IOMMU removal phase" ;;
    esac
}

validate_shared_iommu_temp_inventory() {
    local candidate expected="" count=0

    for candidate in /etc/default/.cmpunlocker-install.* \
                     /etc/kernel/.cmpunlocker-install.*; do
        die "Install-side shared temp ${candidate} must be recovered by install.sh; remove.sh will not delete it"
    done
    for candidate in /etc/default/.cmpunlocker-remove.* \
                     /etc/kernel/.cmpunlocker-remove.*; do
        count=$((count + 1))
        if [[ -n "${expected}" || \
              ! -e "${IOMMU_STATE}" || ! -e "${IOMMU_REMOVE_PENDING}" ]]; then
            die "Unbound shared IOMMU source temp requires manual reconciliation: ${candidate}"
        fi
        parse_iommu_state || \
            die "Cannot bind shared IOMMU source temp to a valid receipt"
        parse_iommu_remove_pending || \
            die "Cannot bind shared IOMMU source temp to a valid restoration marker"
        [[ "${IOMMU_PENDING_FORMAT}" == "5" && \
           "${IOMMU_PENDING_PHASE}" == "restoring" && \
           "${IOMMU_SOURCE_PARENT_DEV}" =~ ^[1-9][0-9]*$ && \
           "${IOMMU_SOURCE_PARENT_INO}" =~ ^[1-9][0-9]*$ && \
           "${IOMMU_SOURCE_PARENT_DEV}" == "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" && \
           "${IOMMU_SOURCE_PARENT_INO}" == "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" ]] || \
            die "Shared IOMMU source temp lacks exact format-5 restoring authority: ${candidate}"
        expected="$(dirname -- "${IOMMU_SOURCE}")/.cmpunlocker-remove.$(basename -- "${IOMMU_SOURCE}").tmp.${IOMMU_BASE_HASH}"
        [[ "${candidate}" == "${expected}" ]] || \
            die "Shared IOMMU source temp is not the receipt-reserved pathname: ${candidate}"
    done
    (( count <= 1 )) || die "Multiple shared IOMMU source temps are ambiguous"
}

validate_iommu_preflight() {
    local current_hash nonce probe_stage

    [[ ! -e "${IOMMU_INSTALL_PENDING}" && ! -L "${IOMMU_INSTALL_PENDING}" ]] || \
        die "An install-side IOMMU transaction is still pending; rerun install before remove"
    [[ ! -e "${IOMMU_CANDIDATE}" && ! -L "${IOMMU_CANDIDATE}" ]] || \
        die "An install-side IOMMU candidate remains; rerun install before remove"
    validate_shared_iommu_temp_inventory
    if recover_completed_iommu_cleanup; then
        return 0
    fi
    if [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]]; then
        parse_iommu_state || die "Invalid or inconsistent ${IOMMU_STATE}"
        current_hash="${IOMMU_SOURCE_NAMESPACE_HASH}"
        [[ "${current_hash}" == "${IOMMU_BASE_HASH}" || \
           "${current_hash}" == "${IOMMU_EXPECTED_HASH}" ]] || \
            die "${IOMMU_SOURCE} differs from both receipt snapshots; preserving post-install edits"
    else
        [[ ! -e "${IOMMU_REMOVE_PENDING}" && ! -L "${IOMMU_REMOVE_PENDING}" ]] || \
            die "IOMMU removal marker exists without its durable receipt"
        [[ ! -e "${IOMMU_BASE}" && ! -L "${IOMMU_BASE}" && \
           ! -e "${IOMMU_EXPECTED}" && ! -L "${IOMMU_EXPECTED}" ]] || \
            die "IOMMU snapshots exist without ${IOMMU_STATE}"
        migrate_legacy_iommu
        if [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]]; then
            parse_iommu_state || die "Migrated IOMMU state failed validation"
        fi
    fi
    if [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]]; then
        [[ "${IOMMU_GENERATOR}" != "kernel-install" ]] || \
            die "kernel-install output cannot be atomically journaled; restore ${IOMMU_SOURCE} manually before removal"
        select_fixed_grub_generator "${IOMMU_GENERATOR}" || \
            die "Persisted IOMMU receipt lacks a fixed trusted GRUB staging pipeline"
        if [[ "${IOMMU_BOOT_TARGET}" == "absent" ]]; then
            nonce="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(3))
PY
)"
            [[ "${nonce}" =~ ^[a-f0-9]{6}$ ]] || \
                die "Could not create IOMMU boot-namespace probe"
            probe_stage="$(dirname -- "${IOMMU_TARGET}")/.cmpunlocker-remove.$(basename -- "${IOMMU_TARGET}").boot.${nonce}"
            inspect_iommu_boot_namespace "${IOMMU_TARGET}" "${probe_stage}" \
                absent absent || \
                die "Persisted IOMMU boot target is not safe for staged publication"
        elif [[ "${IOMMU_PENDING_PHASE}" == "restoring" ]]; then
            [[ ( "${IOMMU_PENDING_FORMAT}" == "4" || \
                 "${IOMMU_PENDING_FORMAT}" == "5" ) && \
               "${IOMMU_BOOT_TARGET}" == "${IOMMU_TARGET}" ]] || \
                die "IOMMU restoring marker lacks exact boot-namespace authority"
            if [[ "${IOMMU_PENDING_FORMAT}" == "4" || \
                  "${IOMMU_BOOT_GENERATOR_ATTEMPTED}" == "0" ]]; then
                inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
                    "${IOMMU_BOOT_STAGE}" absent absent
            else
                inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
                    "${IOMMU_BOOT_STAGE}" optional optional
            fi && \
                [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
                   "${IOMMU_BOOT_TARGET_HASH}" ]] || \
                die "IOMMU restoring marker no longer matches its boot namespace"
            if [[ "${IOMMU_PENDING_FORMAT}" == "5" ]]; then
                [[ "${IOMMU_SOURCE_PARENT_DEV}" == \
                     "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" && \
                   "${IOMMU_SOURCE_PARENT_INO}" == \
                     "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" ]] || \
                    die "IOMMU source parent changed after restoration journaling"
            fi
        fi
    fi
    validate_iommu_legacy_authority || \
        die "Legacy IOMMU shared sidecars do not match their receipt authority"
}

declare -A GEN2_DATA=()
GEN2_UNIT_PATH=""
GEN2_UNIT_HASH=""
GEN2_HAMMER_PATH=""
GEN2_HAMMER_HASH=""
GEN2_MODPROBE_PATH=""
GEN2_MODPROBE_HASH=""

validate_owned_or_absent() {
    local path="$1" expected_hash="$2"
    local actual

    if [[ "${expected_hash}" == "absent" ]]; then
        [[ ! -e "${path}" && ! -L "${path}" ]]
        return
    fi
    [[ "${expected_hash}" =~ ^[a-f0-9]{64}$ ]] || return 1
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        # An earlier removal may already have unlinked this owned file.  The
        # receipt still safely owns any remaining siblings.
        return 0
    fi
    validate_root_managed_file "${path}" || return 1
    actual="$(sha256_regular "${path}")" || return 1
    [[ "${actual}" == "${expected_hash}" ]]
}

parse_gen2_state() {
    read_kv_state "${GEN2_STATE}" \
        "format,unit_path,unit_sha256,hammer_path,hammer_sha256,modprobe_path,modprobe_sha256" \
        GEN2_DATA || return 1
    [[ "${GEN2_DATA[format]:-}" == "1" ]] || return 1
    GEN2_UNIT_PATH="${GEN2_DATA[unit_path]:-}"
    GEN2_UNIT_HASH="${GEN2_DATA[unit_sha256]:-}"
    GEN2_HAMMER_PATH="${GEN2_DATA[hammer_path]:-}"
    GEN2_HAMMER_HASH="${GEN2_DATA[hammer_sha256]:-}"
    GEN2_MODPROBE_PATH="${GEN2_DATA[modprobe_path]:-}"
    GEN2_MODPROBE_HASH="${GEN2_DATA[modprobe_sha256]:-}"
    [[ "${GEN2_UNIT_PATH}" == "/etc/systemd/system/gen2.service" && \
       "${GEN2_HAMMER_PATH}" == "/usr/local/sbin/gen2-hammer" && \
       "${GEN2_MODPROBE_PATH}" == "/etc/modprobe.d/cmp-pcie-gen2.conf" ]] || return 1
    [[ "${GEN2_UNIT_HASH}" =~ ^([a-f0-9]{64}|absent)$ && \
       "${GEN2_HAMMER_HASH}" =~ ^([a-f0-9]{64}|absent)$ && \
       "${GEN2_MODPROBE_HASH}" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ ( "${GEN2_UNIT_HASH}" == "absent" && "${GEN2_HAMMER_HASH}" == "absent" ) || \
       ( "${GEN2_UNIT_HASH}" != "absent" && "${GEN2_HAMMER_HASH}" != "absent" ) ]] || return 1
    validate_owned_or_absent "${GEN2_UNIT_PATH}" "${GEN2_UNIT_HASH}" && \
        validate_owned_or_absent "${GEN2_HAMMER_PATH}" "${GEN2_HAMMER_HASH}" && \
        validate_owned_or_absent "${GEN2_MODPROBE_PATH}" "${GEN2_MODPROBE_HASH}"
}

migrate_legacy_gen2() {
    local unit="/etc/systemd/system/gen2.service"
    local hammer="/usr/local/sbin/gen2-hammer"
    local modprobe="/etc/modprobe.d/cmp-pcie-gen2.conf"
    local expected_modprobe temp unit_present=0 hammer_present=0

    [[ -e "${modprobe}" || -L "${modprobe}" ]] || return 0
    validate_root_managed_file "${modprobe}" || die "Unsafe legacy Gen2 modprobe file ${modprobe}"
    temp="$(mktemp -t cmpunlocker-gen2-modprobe.XXXXXX)"
    printf '%s\n' 'options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"' > "${temp}"
    cmp -s -- "${modprobe}" "${temp}" || { rm -f -- "${temp}"; die "Legacy Gen2 modprobe file was modified; preserving it"; }
    rm -f -- "${temp}"

    [[ -e "${unit}" || -L "${unit}" ]] && unit_present=1
    [[ -e "${hammer}" || -L "${hammer}" ]] && hammer_present=1
    (( unit_present == hammer_present )) || die "Incomplete legacy Gen2 service pair"
    if (( unit_present == 1 )); then
        validate_root_managed_file "${unit}" && \
            validate_root_managed_file "${hammer}" || \
            die "Unsafe legacy Gen2 service asset"
        GEN2_UNIT_HASH="$(sha256_regular "${unit}")"
        GEN2_HAMMER_HASH="$(sha256_regular "${hammer}")"
        [[ "${GEN2_UNIT_HASH}" == "${GEN2_SYSINIT_UNIT_HASH}" ]] && \
            array_has "${GEN2_HAMMER_HASH}" \
                "${GEN2_LEGACY_HAMMER_HASHES[@]}" || \
            die "Legacy generic Gen2 assets have no tracked install provenance; preserving them"
    else
        GEN2_UNIT_HASH="absent"
        GEN2_HAMMER_HASH="absent"
    fi
    GEN2_MODPROBE_HASH="$(sha256_regular "${modprobe}")"
    validate_legacy_unit_namespace gen2.service "${unit}" || \
        die "Legacy Gen2 service has an alternate fragment or drop-in"
    if (( unit_present == 1 )); then
        cleanup_owned_unit_links gen2.service "${unit}" validate \
            sysinit.target.wants || \
            die "Legacy Gen2 enable-link namespace has no exact install provenance"
        validate_trusted_executable "${SYSTEMCTL_EXECUTABLE}" || \
            die "A fixed trusted systemctl is required for legacy Gen2 migration"
        systemctl_sanitized daemon-reload || \
            die "systemd daemon-reload failed before legacy Gen2 migration"
        validate_legacy_unit_namespace gen2.service "${unit}" && \
            validate_loaded_legacy_unit gen2.service "${unit}" || \
            die "systemd does not bind legacy gen2.service to its exact fragment"
    else
        cleanup_owned_unit_links gen2.service "${unit}" validate none || \
            die "A dangling Gen2 enable relationship has no ownership receipt"
    fi
    durable_write_state "${GEN2_STATE}" \
        "format=1" "unit_path=${unit}" "unit_sha256=${GEN2_UNIT_HASH}" \
        "hammer_path=${hammer}" "hammer_sha256=${GEN2_HAMMER_HASH}" \
        "modprobe_path=${modprobe}" "modprobe_sha256=${GEN2_MODPROBE_HASH}" || \
        die "Could not publish migrated Gen2 ownership state"
    ok "Migrated byte-identical legacy Gen2 assets into an ownership receipt"
}

validate_gen2_preflight() {
    local unit="/etc/systemd/system/gen2.service"
    local hammer="/usr/local/sbin/gen2-hammer"
    local modprobe="/etc/modprobe.d/cmp-pcie-gen2.conf"
    local authority=none unit_present=0 hammer_present=0 modprobe_present=0

    GEN2_SYSTEMD_MUTATION_REQUIRED=0
    [[ ! -e "${GEN2_INSTALL_PENDING}" && ! -L "${GEN2_INSTALL_PENDING}" ]] || \
        die "An install-side Gen2 ownership transaction is still pending; rerun install before remove"
    validate_legacy_unit_namespace gen2.service "${unit}" || \
        die "Reserved Gen2 service namespace has an alternate fragment or drop-in"
    [[ -e "${unit}" || -L "${unit}" ]] && unit_present=1
    [[ -e "${hammer}" || -L "${hammer}" ]] && hammer_present=1
    [[ -e "${modprobe}" || -L "${modprobe}" ]] && modprobe_present=1
    if [[ -e "${GEN2_STATE}" || -L "${GEN2_STATE}" ]]; then
        parse_gen2_state || die "Gen2 ownership receipt is invalid or an owned file changed"
    else
        if (( modprobe_present == 0 )); then
            (( unit_present == 0 && hammer_present == 0 )) || \
                die "Standalone legacy Gen2 unit or helper has no ownership authority"
            cleanup_owned_unit_links gen2.service "${unit}" validate none || \
                die "A standalone Gen2 enable relationship has no ownership authority"
        else
            # Historical --no-gen2-service installs legitimately contain only
            # the exact tracked modprobe bytes.  The migration helper accepts
            # that profile or the complete exact unit/helper/modprobe tuple.
            migrate_legacy_gen2
        fi
        if [[ -e "${GEN2_STATE}" || -L "${GEN2_STATE}" ]]; then
            parse_gen2_state || die "Migrated Gen2 ownership state failed validation"
        else
            (( unit_present == 0 && hammer_present == 0 && modprobe_present == 0 )) || \
                die "Standalone Gen2 object has no ownership authority"
        fi
    fi
    if [[ -e "${GEN2_STATE}" || -L "${GEN2_STATE}" ]]; then
        validate_legacy_unit_namespace gen2.service "${GEN2_UNIT_PATH}" || \
            die "Owned Gen2 service has an alternate fragment or drop-in"
        if [[ "${GEN2_UNIT_HASH}" != "absent" ]]; then
            [[ "${GEN2_UNIT_HASH}" == "${GEN2_SYSINIT_UNIT_HASH}" ]] || \
                die "Gen2 unit revision has no exact enable-link manifest"
            authority=sysinit.target.wants
            GEN2_SYSTEMD_MUTATION_REQUIRED=1
        fi
        cleanup_owned_unit_links gen2.service "${GEN2_UNIT_PATH}" validate \
            "${authority}" || \
            die "Owned Gen2 enable-link namespace changed before the global mutation barrier"
        if (( GEN2_SYSTEMD_MUTATION_REQUIRED == 1 )); then
            validate_trusted_executable "${SYSTEMCTL_EXECUTABLE}" || \
                die "A fixed trusted systemctl is required for Gen2 preflight"
            systemctl_sanitized daemon-reload || \
                die "systemd daemon-reload failed during Gen2 preflight"
            validate_legacy_unit_namespace gen2.service "${GEN2_UNIT_PATH}" && \
                validate_owned_or_absent "${GEN2_UNIT_PATH}" "${GEN2_UNIT_HASH}" || \
                die "Receipt-owned Gen2 namespace changed during manager preflight"
            if [[ -e "${GEN2_UNIT_PATH}" || -L "${GEN2_UNIT_PATH}" ]]; then
                validate_loaded_legacy_unit gen2.service "${GEN2_UNIT_PATH}" || \
                    die "systemd does not bind Gen2 to the exact receipt-owned fragment without drop-ins"
            else
                validate_unloaded_legacy_unit gen2.service || \
                    die "systemd retained a cached Gen2 fragment or drop-in after controlled reload"
            fi
        fi
    fi
}

expected_version_in_scope() {
    local version="$1" value
    for value in "${EXPECTED_VERSIONS[@]}" "${RESUME_VERSIONS[@]}" \
                 "${DEFERRED_SCOPE_VERSIONS[@]}"; do
        [[ "${value}" == "${version}" ]] && return 0
    done
    return 1
}

deferred_forward_firmware_temp_in_scope() {
    local artifact="$1" expected

    (( DEFERRED_FORWARD_RECOVERY == 1 )) || return 1
    for expected in "${DEFERRED_FORWARD_FIRMWARE_TEMPS[@]}"; do
        [[ "${artifact}" == "${expected}" ]] && return 0
    done
    return 1
}

validate_firmware_residual_scope() {
    local artifact main version
    for artifact in /lib/firmware/nvidia/*/gsp_tu10x.bin.cmpunlocker.*; do
        main="${artifact%%.cmpunlocker.*}"
        version="$(basename "$(dirname "${main}")")"
        valid_version "${version}" || die "Unsafe legacy firmware artifact ${artifact}"
        expected_version_in_scope "${version}" || \
            die "Legacy firmware artifact is not bound to a removal transaction: ${artifact}"
        case "${artifact}" in
            *.cmpunlocker.bak|*.cmpunlocker.patched) ;;
            *) die "Ambiguous legacy firmware artifact ${artifact}" ;;
        esac
    done
    for artifact in /lib/firmware/nvidia/*/.cmpunlocker-remove.*; do
        version="$(basename -- "$(dirname -- "${artifact}")")"
        valid_version "${version}" && expected_version_in_scope "${version}" || \
            die "Interrupted firmware artifact is outside removal scope: ${artifact}"
        if deferred_forward_firmware_temp_in_scope "${artifact}"; then
            continue
        fi
        # Normal/resume paths reclaim their exact receipt-owned name before
        # this gate; deferred forward recovery retains only the read-only
        # validated name above until all global preflights have passed.
        die "Unreconciled interrupted firmware artifact remains: ${artifact}"
    done
}

kernel_in_scope() {
    local want="$1" value
    for value in "${KERNELS[@]}" "${RESUME_KERNELS[@]}" \
                 "${DEFERRED_SCOPE_KERNELS[@]}"; do
        [[ "${value}" == "${want}" ]] && return 0
    done
    return 1
}

validate_dkms_receipt_scope() {
    local receipt base kernel parse_rc
    for receipt in "${STATE_DIR}"/dkms-removed.*.receipt; do
        base="${receipt##*/}"
        kernel="${base#dkms-removed.}"
        kernel="${kernel%.receipt}"
        valid_kernel "${kernel}" || die "Unsafe DKMS receipt name ${receipt}"
        kernel_in_scope "${kernel}" || \
            die "DKMS receipt is not bound to a live or stock-ready removal: ${receipt}"
        if parse_dkms_receipt "${kernel}"; then
            :
        else
            parse_rc=$?
            (( parse_rc == 2 )) || die "Invalid DKMS receipt ${receipt}"
            die "DKMS receipt disappeared during preflight: ${receipt}"
        fi
    done
}

validate_forward_dkms_temp_scope() {
    local artifact kernel state_path i marker_index
    local -A checked=()

    for artifact in /lib/modules/*/updates/dkms/.cmpunlocker-forward.*; do
        kernel="${artifact#/lib/modules/}"
        kernel="${kernel%%/*}"
        valid_kernel "${kernel}" || \
            die "Unsafe forward DKMS temporary path ${artifact}"
        [[ -z "${checked[${kernel}]+x}" ]] || continue
        checked["${kernel}"]=1
        (( DEFERRED_FORWARD_RECOVERY == 1 )) || \
            die "Forward DKMS temporary is not bound to a forward marker: ${artifact}"
        marker_index=""
        for i in "${!REMOVE_FORWARD_KERNELS[@]}"; do
            if [[ "${REMOVE_FORWARD_KERNELS[$i]}" == "${kernel}" ]]; then
                marker_index="${i}"
                break
            fi
        done
        [[ -n "${marker_index}" ]] || \
            die "Forward DKMS temporary is outside marker scope: ${artifact}"
        state_path="$(remove_state_path "${kernel}")"
        parse_remove_state "${state_path}" || \
            die "Invalid forward state while inventorying DKMS temporaries: ${state_path}"
        [[ "${REMOVE_PHASE}" == "removing" && \
           "${REMOVE_BACKUP}" == "${REMOVE_FORWARD_BACKUPS[$marker_index]}" && \
           "${REMOVE_DKMS_PRESTATE}" == "absent" && \
           "${REMOVE_DKMS_ATTEMPTED}" == "1" && \
           "${REMOVE_DKMS_INSTALL_ATTEMPTED}" == "1" ]] || \
            die "Forward DKMS temporary lacks exact marker phase/prestate authority: ${artifact}"
        forward_dkms_tuple preflight "${REMOVE_VERSION}" "${kernel}" \
            "${REMOVE_DKMS_ARCH}" "${REMOVE_DKMS_BUILT_HASHES}" \
            "${REMOVE_DKMS_PREINSTALL_MANIFEST}" \
            "/lib/modules/${kernel}/updates/cmpunlocker" "${REMOVE_BACKUP}" || \
            die "Forward DKMS temporary namespace changed before the global barrier for ${kernel}"
    done
}

declare -a RESIDUALS=()

legacy_file_has_allowed_hash() {
    local path="$1" hashes_name="$2" actual expected
    local -n allowed_hashes="${hashes_name}"

    validate_root_managed_file "${path}" || return 1
    actual="$(sha256_regular "${path}")" || return 1
    for expected in "${allowed_hashes[@]}"; do
        [[ "${actual}" == "${expected}" ]] && return 0
    done
    return 1
}

durable_remove_allowed_legacy_file() {
    local path="$1" hashes_name="$2"
    local -n allowed_hashes="${hashes_name}"

    python3 - "${path}" "${allowed_hashes[@]}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

path = pathlib.Path(sys.argv[1])
allowed = set(sys.argv[2:])
if (not path.is_absolute() or not allowed
        or any(re.fullmatch(r"[a-f0-9]{64}", value) is None for value in allowed)):
    raise SystemExit("invalid legacy deletion authority")
parent = path.parent
dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
              | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
fd = -1
try:
    pst = os.fstat(dfd)
    if (not stat.S_ISDIR(pst.st_mode) or pst.st_uid != 0 or pst.st_gid != 0
            or stat.S_IMODE(pst.st_mode) & 0o022):
        raise SystemExit("unsafe legacy-file parent")
    fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    fst = os.fstat(fd)
    if (not stat.S_ISREG(fst.st_mode) or fst.st_uid != 0 or fst.st_gid != 0
            or fst.st_nlink != 1 or stat.S_IMODE(fst.st_mode) & 0o022):
        raise SystemExit("unsafe legacy file")
    value = hashlib.sha256()
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        value.update(block)
    if value.hexdigest() not in allowed:
        raise SystemExit("legacy file changed before deletion")
    current = os.stat(path.name, dir_fd=dfd, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != (fst.st_dev, fst.st_ino):
        raise SystemExit("legacy file pathname changed before deletion")
    os.unlink(path.name, dir_fd=dfd)
    os.fsync(dfd)
finally:
    if fd >= 0:
        os.close(fd)
    os.close(dfd)
PY
}

validate_legacy_unit_namespace() {
    local unit="$1" owned_path="$2" directory path

    [[ "${owned_path}" == "/etc/systemd/system/${unit}" ]] || return 1
    array_has "${unit}" "${SYSTEMD_RESERVED_UNITS[@]}" || return 1
    for directory in "${SYSTEMD_UNIT_ROOTS[@]}"; do
        path="${directory}/${unit}"
        if [[ "${path}" != "${owned_path}" ]]; then
            [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
        fi
        path="${directory}/${unit}.d"
        [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
    done
}

validate_loaded_legacy_unit() {
    local unit="$1" owned_path="$2" fragment dropins

    fragment="$(systemctl_sanitized show --property=FragmentPath --value "${unit}" 2>/dev/null)" || \
        return 1
    dropins="$(systemctl_sanitized show --property=DropInPaths --value "${unit}" 2>/dev/null)" || \
        return 1
    [[ "${fragment}" == "${owned_path}" && -z "${dropins}" && \
       "${fragment}" != *$'\n'* && "${dropins}" != *$'\n'* ]]
}

validate_unloaded_legacy_unit() {
    local unit="$1" load_state fragment dropins

    load_state="$(systemctl_sanitized show --property=LoadState --value \
        "${unit}" 2>/dev/null)" || return 1
    fragment="$(systemctl_sanitized show --property=FragmentPath --value \
        "${unit}" 2>/dev/null)" || return 1
    dropins="$(systemctl_sanitized show --property=DropInPaths --value \
        "${unit}" 2>/dev/null)" || return 1
    [[ "${load_state}" == "not-found" && -z "${fragment}" && -z "${dropins}" && \
       "${load_state}" != *$'\n'* && "${fragment}" != *$'\n'* && \
       "${dropins}" != *$'\n'* ]]
}

validate_quiescent_legacy_unit() {
    local unit="$1" state job

    state="$(systemctl_sanitized show --property=ActiveState --value \
        "${unit}" 2>/dev/null)" || return 1
    job="$(systemctl_sanitized show --property=Job --value \
        "${unit}" 2>/dev/null)" || return 1
    [[ "${state}" == "inactive" && -z "${job}" && \
       "${state}" != *$'\n'* && "${job}" != *$'\n'* ]]
}

cleanup_owned_unit_links() {
    local unit="$1" owned_path="$2" action="${3:-remove}"
    local authority="${4:-none}"
    python3 - "${unit}" "${owned_path}" "${action}" "${authority}" <<'PY'
import os
import pathlib
import re
import stat
import sys

unit, owned_raw, action, authority = sys.argv[1:]
owned = pathlib.Path(owned_raw)
if (re.fullmatch(r"[A-Za-z0-9_.@-]+\.service", unit) is None
        or owned != pathlib.Path("/etc/systemd/system") / unit
        or action not in ("validate", "remove")
        or authority not in ("none", "multi-user.target.wants",
                             "sysinit.target.wants")):
    raise SystemExit("invalid systemd enable-link authority")
roots = [
    pathlib.Path(value) for value in (
        "/etc/systemd/system.control", "/run/systemd/system.control",
        "/run/systemd/transient", "/run/systemd/generator.early",
        "/etc/systemd/system", "/etc/systemd/system.attached",
        "/run/systemd/system", "/run/systemd/system.attached",
        "/run/systemd/generator", "/usr/local/lib/systemd/system",
        "/usr/lib/systemd/system", "/lib/systemd/system",
        "/run/systemd/generator.late",
    )
]
if unit == "gen2.service":
    if authority not in ("none", "sysinit.target.wants"):
        raise SystemExit("Gen2 receipt grants an unknown enable relationship")
elif unit in ("cmpunlocker.service", "cmpretrain.service",
              "cmp-gen2-retrain.service"):
    if authority not in ("none", "multi-user.target.wants"):
        raise SystemExit("legacy unit revision has no matching enable authority")
else:
    raise SystemExit("unit has no historical enable-link manifest")
allowed_links = set()
if authority != "none":
    allowed_links.add(pathlib.Path("/etc/systemd/system") / authority / unit)

def mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

mounted = mounts()
links = []
for root in roots:
    try:
        rst = os.lstat(root)
    except FileNotFoundError:
        continue
    if (not stat.S_ISDIR(rst.st_mode) or stat.S_ISLNK(rst.st_mode)
            or rst.st_uid != 0 or rst.st_gid != 0
            or stat.S_IMODE(rst.st_mode) & 0o022):
        raise SystemExit(f"unsafe systemd link root: {root}")
    root_dev = rst.st_dev
    for current_raw, dirnames, filenames in os.walk(root, topdown=True,
                                                     followlinks=False):
        current = pathlib.Path(current_raw)
        cst = os.lstat(current)
        if (not stat.S_ISDIR(cst.st_mode) or stat.S_ISLNK(cst.st_mode)
                or cst.st_uid != 0 or cst.st_gid != 0
                or stat.S_IMODE(cst.st_mode) & 0o022 or cst.st_dev != root_dev):
            raise SystemExit(f"unsafe directory in systemd link namespace: {current}")
        if current != root:
            aliases = {os.path.normpath(os.fspath(current)),
                       os.path.normpath(os.path.realpath(current))}
            if aliases & mounted:
                raise SystemExit(f"mount hides systemd link namespace: {current}")
        kept = []
        for name in dirnames:
            child = current / name
            st = os.lstat(child)
            if stat.S_ISLNK(st.st_mode):
                if name.endswith((".wants", ".requires", ".upholds")):
                    raise SystemExit(f"symlinked systemd enable directory: {child}")
                try:
                    resolved = pathlib.Path(os.path.realpath(child))
                except OSError:
                    raise SystemExit(f"unresolvable systemd alias: {child}")
                if resolved == owned:
                    raise SystemExit(f"unowned systemd directory alias targets unit: {child}")
                continue
            if (not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_gid != 0
                    or stat.S_IMODE(st.st_mode) & 0o022 or st.st_dev != root_dev):
                raise SystemExit(f"unsafe systemd namespace directory: {child}")
            kept.append(name)
        dirnames[:] = kept
        for name in filenames:
            child = current / name
            st = os.lstat(child)
            if not stat.S_ISLNK(st.st_mode):
                continue
            try:
                resolved = pathlib.Path(os.path.realpath(child))
            except OSError:
                raise SystemExit(f"unresolvable systemd alias: {child}")
            if resolved == owned and child not in allowed_links:
                raise SystemExit(f"unowned systemd alias targets unit: {child}")
    for entry in os.scandir(root):
        if not entry.name.endswith((".wants", ".requires", ".upholds")):
            continue
        est = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(est.st_mode):
            raise SystemExit(f"symlinked systemd enable directory: {entry.path}")
        if not stat.S_ISDIR(est.st_mode):
            continue
        dfd = os.open(entry.path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                      | getattr(os, "O_CLOEXEC", 0)
                      | getattr(os, "O_NOFOLLOW", 0))
        dst = os.fstat(dfd)
        if (dst.st_uid != 0 or dst.st_gid != 0 or stat.S_IMODE(dst.st_mode) & 0o022):
            os.close(dfd)
            raise SystemExit(f"unsafe systemd enable directory: {entry.path}")
        try:
            lst = os.stat(unit, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            os.close(dfd)
            continue
        if (not stat.S_ISLNK(lst.st_mode) or lst.st_uid != 0 or lst.st_gid != 0
                or lst.st_nlink != 1):
            os.close(dfd)
            raise SystemExit(f"unsafe systemd enable object: {entry.path}/{unit}")
        target = os.readlink(unit, dir_fd=dfd)
        resolved = pathlib.Path(os.path.normpath(os.path.join(entry.path, target)))
        if resolved != owned:
            os.close(dfd)
            raise SystemExit(f"systemd enable link targets another unit: {entry.path}/{unit}")
        link_path = pathlib.Path(entry.path) / unit
        if link_path not in allowed_links:
            os.close(dfd)
            raise SystemExit(f"unit has an unowned enable relationship: {link_path}")
        links.append((dfd, unit, lst, target))
if mounted != mounts():
    raise SystemExit("mount namespace changed during systemd link inventory")
if action == "validate":
    for dfd, unused, unused_st, unused_target in links:
        os.close(dfd)
    raise SystemExit(0)
for dfd, name, expected_st, expected_target in links:
    try:
        if mounted != mounts():
            raise SystemExit("mount namespace changed before systemd link deletion")
        current = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if ((current.st_dev, current.st_ino) !=
                (expected_st.st_dev, expected_st.st_ino)
                or not stat.S_ISLNK(current.st_mode)
                or os.readlink(name, dir_fd=dfd) != expected_target):
            raise SystemExit("systemd enable link changed before deletion")
        os.unlink(name, dir_fd=dfd)
        os.fsync(dfd)
    finally:
        os.close(dfd)
PY
}

legacy_retrain_is_project_like() {
    local path="/usr/local/sbin/retrain.sh"

    [[ -e "${path}" || -L "${path}" ]] || return 1
    [[ -f "${path}" && ! -L "${path}" ]] || return 0
    legacy_file_has_allowed_hash "${path}" LEGACY_RETRAIN_HELPER_HASHES && return 0
    grep -aqF 'retrain: pre bar0=' "${path}" 2>/dev/null || \
        grep -aqF 'CMP 170HX' "${path}" 2>/dev/null
}

validate_service_remove_transaction_authority() (
    local state_path kernel
    local -A seen=()

    (( ${#CLEANUP_STATE_PATHS[@]} > 0 )) || return 1
    for state_path in "${CLEANUP_STATE_PATHS[@]}"; do
        [[ -z "${seen[${state_path}]+x}" ]] || continue
        seen["${state_path}"]=1
        parse_remove_state "${state_path}" || return 1
        [[ "${REMOVE_PHASE}" == "stock-ready" ]] || return 1
        array_has "${REMOVE_KERNEL}" "${KERNELS[@]}" "${RESUME_KERNELS[@]}" || \
            return 1
        kernel="$(remove_state_path "${REMOVE_KERNEL}")" || return 1
        [[ "${state_path}" == "${kernel}" ]] || return 1
    done
)

parse_service_remove_pending() {
    read_kv_state "${SERVICE_REMOVE_PENDING}" \
        "format,phase,watchdog_unit,watchdog_path,watchdog_sha256,watchdog_link_path,watchdog_link_target_sha256,retrain_unit,retrain_path,retrain_sha256,retrain_link_path,retrain_link_target_sha256" \
        SERVICE_REMOVE_DATA || return 1
    (( ${#SERVICE_REMOVE_DATA[@]} == 12 )) || return 1
    [[ "${SERVICE_REMOVE_DATA[format]:-}" == "1" && \
       "${SERVICE_REMOVE_DATA[phase]:-}" == "reload-required" && \
       "${SERVICE_REMOVE_DATA[watchdog_unit]:-}" == "${SERVICE_NAME}.service" && \
       "${SERVICE_REMOVE_DATA[watchdog_path]:-}" == "${SERVICE_FILE}" && \
       "${SERVICE_REMOVE_DATA[watchdog_link_path]:-}" == "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service" && \
       "${SERVICE_REMOVE_DATA[retrain_unit]:-}" == "cmpretrain.service" && \
       "${SERVICE_REMOVE_DATA[retrain_path]:-}" == "/etc/systemd/system/cmpretrain.service" && \
       "${SERVICE_REMOVE_DATA[retrain_link_path]:-}" == "/etc/systemd/system/multi-user.target.wants/cmpretrain.service" ]] || \
        return 1
    SERVICE_PENDING_WATCHDOG_HASH="${SERVICE_REMOVE_DATA[watchdog_sha256]:-}"
    SERVICE_PENDING_WATCHDOG_LINK="${SERVICE_REMOVE_DATA[watchdog_link_target_sha256]:-}"
    SERVICE_PENDING_RETRAIN_HASH="${SERVICE_REMOVE_DATA[retrain_sha256]:-}"
    SERVICE_PENDING_RETRAIN_LINK="${SERVICE_REMOVE_DATA[retrain_link_target_sha256]:-}"
    [[ "${SERVICE_PENDING_WATCHDOG_HASH}" =~ ^(absent|[a-f0-9]{64})$ && \
       "${SERVICE_PENDING_RETRAIN_HASH}" =~ ^(absent|[a-f0-9]{64})$ && \
       "${SERVICE_PENDING_WATCHDOG_LINK}" =~ ^(absent|[a-f0-9]{64})$ && \
       "${SERVICE_PENDING_RETRAIN_LINK}" =~ ^(absent|[a-f0-9]{64})$ ]] || return 1
    if [[ "${SERVICE_PENDING_WATCHDOG_HASH}" != "absent" ]]; then
        array_has "${SERVICE_PENDING_WATCHDOG_HASH}" \
            "${LEGACY_WATCHDOG_UNIT_HASHES[@]}" || return 1
    else
        [[ "${SERVICE_PENDING_WATCHDOG_LINK}" == "absent" ]] || return 1
    fi
    if [[ "${SERVICE_PENDING_RETRAIN_HASH}" != "absent" ]]; then
        array_has "${SERVICE_PENDING_RETRAIN_HASH}" \
            "${LEGACY_RETRAIN_UNIT_HASHES[@]}" || return 1
    else
        [[ "${SERVICE_PENDING_RETRAIN_LINK}" == "absent" ]] || return 1
    fi
    [[ "${SERVICE_PENDING_WATCHDOG_HASH}" != "absent" || \
       "${SERVICE_PENDING_RETRAIN_HASH}" != "absent" ]] || return 1
    validate_service_remove_transaction_authority || return 1
    SERVICE_REMOVE_PRESENT=1
}

systemd_link_target_sha256() {
    local path="$1"

    python3 - "${path}" <<'PY'
import hashlib
import os
import stat
import sys

path = os.fsencode(sys.argv[1])
st = os.lstat(path)
if not stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_gid != 0 or st.st_nlink != 1:
    raise SystemExit("unsafe systemd link while hashing target")
value = (b"cmpunlocker-systemd-link-v1\0" + path + b"\0"
         + os.fsencode(os.readlink(path)))
print(hashlib.sha256(value).hexdigest())
PY
}

validate_service_pending_unit() {
    local unit="$1" path="$2" expected_hash="$3" expected_link="$4"
    local authority=none link_path current_link=absent

    [[ "${expected_hash}" =~ ^(absent|[a-f0-9]{64})$ && \
       "${expected_link}" =~ ^(absent|[a-f0-9]{64})$ ]] || return 1
    validate_legacy_unit_namespace "${unit}" "${path}" || return 1
    validate_owned_or_absent "${path}" "${expected_hash}" || return 1
    if [[ "${expected_hash}" != "absent" ]]; then
        authority=multi-user.target.wants
    fi
    cleanup_owned_unit_links "${unit}" "${path}" validate "${authority}" || return 1
    link_path="/etc/systemd/system/multi-user.target.wants/${unit}"
    if [[ -e "${link_path}" || -L "${link_path}" ]]; then
        current_link="$(systemd_link_target_sha256 "${link_path}")" || return 1
    fi
    [[ "${current_link}" == "absent" || "${current_link}" == "${expected_link}" ]]
}

validate_service_remove_pending_assets() {
    (( SERVICE_REMOVE_PRESENT == 1 )) || return 1
    validate_service_pending_unit "${SERVICE_NAME}.service" "${SERVICE_FILE}" \
        "${SERVICE_PENDING_WATCHDOG_HASH}" "${SERVICE_PENDING_WATCHDOG_LINK}" && \
    validate_service_pending_unit cmpretrain.service \
        /etc/systemd/system/cmpretrain.service \
        "${SERVICE_PENDING_RETRAIN_HASH}" "${SERVICE_PENDING_RETRAIN_LINK}"
}

write_service_remove_pending() {
    local watchdog_hash="$1" watchdog_link="$2"
    local retrain_hash="$3" retrain_link="$4"

    [[ ! -e "${SERVICE_REMOVE_PENDING}" && ! -L "${SERVICE_REMOVE_PENDING}" ]] || \
        die "Service reload intent already exists"
    durable_write_state_noreplace "${SERVICE_REMOVE_PENDING}" \
        "format=1" \
        "phase=reload-required" \
        "watchdog_unit=${SERVICE_NAME}.service" \
        "watchdog_path=${SERVICE_FILE}" \
        "watchdog_sha256=${watchdog_hash}" \
        "watchdog_link_path=/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service" \
        "watchdog_link_target_sha256=${watchdog_link}" \
        "retrain_unit=cmpretrain.service" \
        "retrain_path=/etc/systemd/system/cmpretrain.service" \
        "retrain_sha256=${retrain_hash}" \
        "retrain_link_path=/etc/systemd/system/multi-user.target.wants/cmpretrain.service" \
        "retrain_link_target_sha256=${retrain_link}" || \
        die "Could not publish durable service reload intent"
    parse_service_remove_pending && validate_service_remove_pending_assets || \
        die "Service reload intent failed exact read-back validation"
}

validate_final_reserved_service_namespace() {
    local unit="$1" path="/etc/systemd/system/${1}"

    array_has "${unit}" "${SYSTEMD_RESERVED_UNITS[@]}" || return 1
    [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
    validate_legacy_unit_namespace "${unit}" "${path}" && \
        cleanup_owned_unit_links "${unit}" "${path}" validate none
}

validate_namespaced_service_assets() {
    local path unit expected_hash
    local -A owned_units=()
    local -A owned_unit_hashes=()

    SERVICE_SYSTEMD_MUTATION_REQUIRED=0
    SERVICE_REMOVE_PRESENT=0
    if [[ -e "${SERVICE_REMOVE_PENDING}" || -L "${SERVICE_REMOVE_PENDING}" ]]; then
        parse_service_remove_pending && validate_service_remove_pending_assets || \
            die "Service reload intent or its exact asset namespace is invalid"
        if [[ "${SERVICE_PENDING_WATCHDOG_HASH}" != "absent" ]]; then
            owned_units["${SERVICE_NAME}.service"]="${SERVICE_FILE}"
            owned_unit_hashes["${SERVICE_NAME}.service"]="${SERVICE_PENDING_WATCHDOG_HASH}"
        fi
        if [[ "${SERVICE_PENDING_RETRAIN_HASH}" != "absent" ]]; then
            owned_units[cmpretrain.service]="/etc/systemd/system/cmpretrain.service"
            owned_unit_hashes[cmpretrain.service]="${SERVICE_PENDING_RETRAIN_HASH}"
        fi
    else
        validate_legacy_unit_namespace "${SERVICE_NAME}.service" "${SERVICE_FILE}" || \
            die "Reserved watchdog namespace has an alternate fragment or drop-in"
        if [[ -e "${SERVICE_FILE}" || -L "${SERVICE_FILE}" ]]; then
            legacy_file_has_allowed_hash "${SERVICE_FILE}" LEGACY_WATCHDOG_UNIT_HASHES || \
                die "Legacy watchdog unit is not an exact project-owned revision: ${SERVICE_FILE}"
            owned_units["${SERVICE_NAME}.service"]="${SERVICE_FILE}"
            owned_unit_hashes["${SERVICE_NAME}.service"]="$(sha256_regular "${SERVICE_FILE}")"
        else
            cleanup_owned_unit_links "${SERVICE_NAME}.service" "${SERVICE_FILE}" \
                validate none || \
                die "Standalone watchdog enable relationship has no ownership authority"
        fi
        unit=cmpretrain.service
        path="/etc/systemd/system/${unit}"
        validate_legacy_unit_namespace "${unit}" "${path}" || \
            die "Reserved retrain namespace has an alternate fragment or drop-in: ${unit}"
        if [[ -e "${path}" || -L "${path}" ]]; then
            legacy_file_has_allowed_hash "${path}" LEGACY_RETRAIN_UNIT_HASHES || \
                die "Legacy retrain unit is not an exact project-owned revision: ${path}"
            owned_units["${unit}"]="${path}"
            owned_unit_hashes["${unit}"]="$(sha256_regular "${path}")"
        else
            cleanup_owned_unit_links "${unit}" "${path}" validate none || \
                die "Standalone retrain enable relationship has no ownership authority: ${unit}"
        fi
        for unit in "${!owned_units[@]}"; do
            cleanup_owned_unit_links "${unit}" "${owned_units[$unit]}" validate \
                multi-user.target.wants && \
                validate_owned_or_absent "${owned_units[$unit]}" \
                    "${owned_unit_hashes[$unit]}" || \
                die "Owned unit or enable-link namespace changed before the global mutation barrier: ${unit}"
        done
    fi
    path="/etc/systemd/system/cmp-gen2-retrain.service"
    validate_legacy_unit_namespace cmp-gen2-retrain.service "${path}" || \
        die "Reserved legacy Gen2 retrain namespace has a fragment or drop-in"
    [[ ! -e "${path}" && ! -L "${path}" ]] || \
        die "No tracked installer grants deletion authority for legacy unit ${path}"
    cleanup_owned_unit_links cmp-gen2-retrain.service "${path}" validate none || \
        die "Legacy Gen2 retrain enable relationship has no ownership authority"
    path="/usr/local/sbin/cmp-gen2-retrain.sh"
    if [[ -e "${path}" || -L "${path}" ]]; then
        die "No tracked installer grants deletion authority for legacy path ${path}; reconcile it manually"
    fi
    path="/usr/local/sbin/retrain.sh"
    if [[ -e "${path}" || -L "${path}" ]]; then
        legacy_file_has_allowed_hash "${path}" LEGACY_RETRAIN_HELPER_HASHES || \
            ! legacy_retrain_is_project_like || \
            die "Project-like legacy retrain helper was modified; preserving it for review"
    fi
    if (( ${#owned_units[@]} > 0 )); then
        SERVICE_SYSTEMD_MUTATION_REQUIRED=1
        validate_trusted_executable "${SYSTEMCTL_EXECUTABLE}" || \
            die "A fixed trusted systemctl is required for service preflight"
        systemctl_sanitized daemon-reload || \
            die "systemd daemon-reload failed during service preflight"
        for unit in "${!owned_units[@]}"; do
            expected_hash="${owned_unit_hashes[$unit]}"
            validate_legacy_unit_namespace "${unit}" "${owned_units[$unit]}" && \
                validate_owned_or_absent "${owned_units[$unit]}" "${expected_hash}" || \
                die "Owned service namespace changed during manager preflight: ${unit}"
            if [[ -e "${owned_units[$unit]}" || -L "${owned_units[$unit]}" ]]; then
                validate_loaded_legacy_unit "${unit}" "${owned_units[$unit]}" || \
                    die "systemd does not bind ${unit} to the exact owned fragment without drop-ins"
            else
                validate_unloaded_legacy_unit "${unit}" || \
                    die "systemd retained a removed service fragment during reload: ${unit}"
            fi
        done
    fi
}

validate_namespaced_service_assets
validate_gen2_preflight
validate_iommu_preflight
validate_deferred_firmware_domain_preflight
validate_firmware_residual_scope
validate_dkms_receipt_scope
validate_forward_dkms_temp_scope

validate_legacy_install_dir_preflight() {
    [[ -e "${INSTALL_DIR}" || -L "${INSTALL_DIR}" ]] || return 0
    python3 - "${INSTALL_DIR}" <<'PY'
import os
import pathlib
import re
import stat
import sys

path = pathlib.Path(sys.argv[1])
if path != pathlib.Path("/opt/cmpunlocker") or path.resolve(strict=True) != path:
    raise SystemExit("unsafe legacy install path")
parent = path.parent.resolve(strict=True)
pst = os.lstat(parent)
st = os.lstat(path)
if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != 0 or pst.st_gid != 0 or stat.S_IMODE(pst.st_mode) & 0o022
        or not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != 0 or st.st_gid != 0 or stat.S_IMODE(st.st_mode) & 0o022
        or st.st_dev != pst.st_dev):
    raise SystemExit("unsafe legacy install directory")
exact = os.path.normpath(os.fspath(path))
prefix = exact + os.sep
with open("/proc/self/mountinfo", "rb") as stream:
    for raw in stream:
        fields = raw.rstrip(b"\n").split(b" ")
        if len(fields) < 5:
            raise SystemExit("malformed mountinfo")
        decoded = re.sub(rb"\\([0-7]{3})",
                         lambda match: bytes((int(match.group(1), 8),)),
                         fields[4])
        mount = os.path.normpath(os.fsdecode(decoded))
        if mount == exact or mount.startswith(prefix):
            raise SystemExit(f"mount blocks legacy install cleanup: {mount}")
entry = next(os.scandir(path), None)
if entry is not None:
    raise SystemExit(
        f"nonempty unreceipted legacy install directory requires manual reconciliation: {entry.path}"
    )
PY
}

validate_legacy_install_dir_preflight || \
    die "Legacy ${INSTALL_DIR} has no exact deletion manifest; preserving it"

if (( DEFERRED_FORWARD_RECOVERY == 1 )); then
    # The marker-specific read-only proof and every existing global preflight
    # have now succeeded in this invocation.  Re-run the forward proof from
    # scratch and only then cross its firmware/CMP/DKMS publication boundary.
    recover_forward_transaction recover
    for kernel in "${REMOVE_FORWARD_KERNELS[@]}"; do
        state_path="$(remove_state_path "${kernel}")"
        parse_remove_state "${state_path}" || \
            die "Recovered forward state failed read-back validation: ${state_path}"
        append_parsed_stock_ready_state "${state_path}" 1
    done
    DEFERRED_FORWARD_RECOVERY=0
    DEFERRED_SCOPE_KERNELS=()
    DEFERRED_SCOPE_VERSIONS=()
    DEFERRED_FORWARD_FIRMWARE_TEMPS=()
    validate_firmware_residual_scope
    validate_dkms_receipt_scope
    ok "Classified ${#REMOVE_FORWARD_KERNELS[@]} recovered forward transition(s)"
fi

collect_resolved_cmp_core_residuals() {
    local module_root kernel resolved canonical marker_rc existing

    for module_root in /lib/modules/*; do
        [[ -d "${module_root}" ]] || continue
        kernel="${module_root##*/}"
        valid_kernel "${kernel}" || die "Unsafe kernel module directory ${module_root}"
        resolved="$(modinfo -k "${kernel}" -n nvidia 2>/dev/null || true)"
        [[ -n "${resolved}" ]] || continue
        [[ -f "${resolved}" ]] || \
            die "Cannot inspect resolved NVIDIA core for ${kernel}: ${resolved}"
        canonical="$(readlink -f -- "${resolved}")" || \
            die "Cannot canonicalize resolved NVIDIA core for ${kernel}"
        if module_contains_cmp_marker "${resolved}"; then
            existing=0
            for resolved in "${RESIDUALS[@]}"; do
                [[ "${resolved}" == "${canonical}" ]] && existing=1
            done
            (( existing == 1 )) || RESIDUALS+=("${canonical}")
        else
            marker_rc=$?
            (( marker_rc == 1 )) || \
                die "Cannot prove resolved NVIDIA core is free of cmpunlocker markers: ${resolved}"
        fi
    done
}

collect_cmp_residuals() {
    local path reserved_unit
    RESIDUALS=()
    for path in \
        /lib/modules/*/updates/cmpunlocker \
        /lib/modules/*/updates/.cmpunlocker.stage.* \
        /lib/modules/*/updates/.cmpunlocker.backup.* \
        /lib/modules/*/updates/.cmpunlocker.failed.* \
        /lib/modules/*/updates/dkms/.cmpunlocker-forward.* \
        /lib/modules/.cmpunlocker.remove.* \
        "${REMOVE_COMMIT}" "${REMOVE_FORWARD}" \
        "${STATE_DIR}"/remove.*.state \
        "${STATE_DIR}"/dkms-removed.*.receipt \
        "${IOMMU_STATE}" "${IOMMU_BASE}" "${IOMMU_EXPECTED}" "${IOMMU_CANDIDATE}" \
        "${IOMMU_INSTALL_PENDING}" "${IOMMU_REMOVE_PENDING}" \
        "${GEN2_STATE}" "${GEN2_INSTALL_PENDING}" "${SERVICE_REMOVE_PENDING}" \
        /etc/default/grub.cmpunlocker.bak /etc/default/grub.cmpunlocker.pending \
        /etc/kernel/cmdline.cmpunlocker.bak /etc/kernel/cmdline.cmpunlocker.pending \
        /etc/modprobe.d/cmp-pcie-gen2.conf \
        /usr/local/sbin/cmp-gen2-retrain.sh \
        /usr/local/sbin/gen2-hammer \
        /lib/firmware/nvidia/*/gsp_tu10x.bin.cmpunlocker.* \
        /lib/firmware/nvidia/*/.cmpunlocker-remove.* \
        /etc/default/.cmpunlocker-remove.* /etc/default/.cmpunlocker-install.* \
        /etc/kernel/.cmpunlocker-remove.* /etc/kernel/.cmpunlocker-install.* \
        /etc/systemd/system/.cmpunlocker-remove.* \
        /etc/systemd/system/.cmpunlocker-install.* \
        /usr/local/sbin/.cmpunlocker-remove.* /usr/local/sbin/.cmpunlocker-install.* \
        /etc/modprobe.d/.cmpunlocker-remove.* /etc/modprobe.d/.cmpunlocker-install.* \
        "${INSTALL_DIR}"; do
        [[ -e "${path}" || -L "${path}" ]] && RESIDUALS+=("${path}")
    done
    for reserved_unit in "${SYSTEMD_RESERVED_UNITS[@]}"; do
        validate_final_reserved_service_namespace "${reserved_unit}" || \
            RESIDUALS+=("reserved-systemd-namespace:${reserved_unit}")
    done
    legacy_retrain_is_project_like && RESIDUALS+=("/usr/local/sbin/retrain.sh")
    if [[ -d "${TX_ROOT}" && ! -L "${TX_ROOT}" ]]; then
        while IFS= read -r -d '' path; do
            valid_kernel_lock_object "${path}" || RESIDUALS+=("${path}")
        done < <(find -P "${TX_ROOT}" -mindepth 1 -maxdepth 1 -print0)
    fi
    if [[ -d "${STATE_DIR}" && ! -L "${STATE_DIR}" ]]; then
        while IFS= read -r -d '' path; do
            [[ "${path}" == "${LIFECYCLE_LOCK}" ]] || RESIDUALS+=("${path}")
        done < <(find -P "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print0)
    fi
    collect_resolved_cmp_core_residuals
}

if (( ${#MODULE_DIRS[@]} == 0 && ${#RESUME_KERNELS[@]} == 0 )); then
    collect_cmp_residuals
    if (( ${#RESIDUALS[@]} > 0 )); then
        err "No patched module directory or stock-ready receipt exists, but cmpunlocker residuals remain:"
        printf '  %s\n' "${RESIDUALS[@]}" >&2
        die "Refusing to claim successful removal from an unproven state"
    fi
    warn "cmpunlocker is already absent; no on-disk stock transition was asserted"
fi

STOCK_READY=0
declare -a MODULE_MOVED=()

CAPTURED_DKMS_BUILT_HASHES=""
CAPTURED_DKMS_BUILT_PAYLOAD_HASHES=""
declare -a CAPTURED_DKMS_BUILT_FILENAMES=()
capture_dkms_built_hashes() {
    local version="$1" kernel="$2" arch="$3"
    local directory="${DKMS_TREE}/nvidia/${version}/${kernel}/${arch}/module"
    local build_workspace="${DKMS_TREE}/nvidia/${version}/build"
    local i suffix candidate module_name module_version vermagic hash payload_hash marker_rc
    local -a matches=() hashes=() payload_hashes=() objects=()

    CAPTURED_DKMS_BUILT_HASHES=""
    CAPTURED_DKMS_BUILT_PAYLOAD_HASHES=""
    CAPTURED_DKMS_BUILT_FILENAMES=()
    [[ ! -e "${build_workspace}" && ! -L "${build_workspace}" ]] || return 1
    [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
    for i in "${!MODULE_FILES[@]}"; do
        matches=()
        for suffix in '' .gz .xz .zst; do
            candidate="${directory}/${MODULE_FILES[$i]}${suffix}"
            [[ -e "${candidate}" || -L "${candidate}" ]] && matches+=("${candidate}")
        done
        (( ${#matches[@]} == 1 )) || return 1
        candidate="${matches[0]}"
        [[ -f "${candidate}" && ! -L "${candidate}" && \
           "$(readlink -f -- "${candidate}" 2>/dev/null || true)" == "${candidate}" ]] || return 1
        [[ "$(stat -c '%u:%g:%h' -- "${candidate}")" == "0:0:1" ]] || return 1
        module_name="$(modinfo -F name -- "${candidate}" 2>/dev/null)" || return 1
        [[ "${module_name}" == "${MODULE_INTERNAL[$i]}" ]] || return 1
        module_version="$(modinfo -F version -- "${candidate}" 2>/dev/null)" || return 1
        [[ "${module_version}" == "${version}" ]] || return 1
        vermagic="$(modinfo -F vermagic -- "${candidate}" 2>/dev/null)" || return 1
        [[ "${vermagic}" == "${kernel}" || "${vermagic}" == "${kernel} "* ]] || return 1
        hash="$(sha256_regular "${candidate}")" || return 1
        [[ "${hash}" =~ ^[a-f0-9]{64}$ ]] || return 1
        payload_hash="$(module_payload_sha256 "${candidate}")" || return 1
        [[ "${payload_hash}" =~ ^[a-f0-9]{64}$ ]] || return 1
        hashes+=("${hash}")
        payload_hashes+=("${payload_hash}")
        CAPTURED_DKMS_BUILT_FILENAMES+=("${candidate##*/}")
        if (( i == 0 )); then
            if module_contains_cmp_marker "${candidate}"; then
                return 1
            else
                marker_rc=$?
                (( marker_rc == 1 )) || return 1
            fi
        fi
    done
    mapfile -d '' -t objects < <(find -P "${directory}" -mindepth 1 -print0)
    (( ${#objects[@]} == ${#MODULE_FILES[@]} || \
       ${#objects[@]} == ${#MODULE_FILES[@]} + 1 )) || return 1
    for candidate in "${objects[@]}"; do
        [[ -f "${candidate}" && ! -L "${candidate}" ]] || return 1
        case "${candidate##*/}" in
            Module.symvers|nvidia.ko|nvidia.ko.gz|nvidia.ko.xz|nvidia.ko.zst|\
            nvidia-modeset.ko|nvidia-modeset.ko.gz|nvidia-modeset.ko.xz|nvidia-modeset.ko.zst|\
            nvidia-uvm.ko|nvidia-uvm.ko.gz|nvidia-uvm.ko.xz|nvidia-uvm.ko.zst|\
            nvidia-drm.ko|nvidia-drm.ko.gz|nvidia-drm.ko.xz|nvidia-drm.ko.zst|\
            nvidia-peermem.ko|nvidia-peermem.ko.gz|nvidia-peermem.ko.xz|nvidia-peermem.ko.zst) ;;
            *) return 1 ;;
        esac
    done
    CAPTURED_DKMS_BUILT_HASHES="$(IFS=:; printf '%s' "${hashes[*]}")"
    CAPTURED_DKMS_BUILT_PAYLOAD_HASHES="$(IFS=:; printf '%s' "${payload_hashes[*]}")"
}

CAPTURED_DKMS_PREINSTALL_MANIFEST=""
capture_dkms_preinstall_manifest() {
    local kernel="$1" excluded="$2" filename_mode="${3:-built}"
    local -a target_filenames=()

    case "${filename_mode}" in
        built) target_filenames=("${CAPTURED_DKMS_BUILT_FILENAMES[@]}") ;;
        uncompressed) target_filenames=("${MODULE_FILES[@]}") ;;
        *) return 1 ;;
    esac

    CAPTURED_DKMS_PREINSTALL_MANIFEST="$(python3 - \
        "/lib/modules/${kernel}" "${excluded}" \
        "${#MODULE_FILES[@]}" "${MODULE_FILES[@]}" \
        "${target_filenames[@]}" <<'PY'
import os
import pathlib
import re
import shlex
import stat
import sys

root_arg = pathlib.Path(sys.argv[1])
excluded_arg = pathlib.Path(sys.argv[2])
count = int(sys.argv[3])
names = set(sys.argv[4:4 + count])
built_filenames = sys.argv[4 + count:]
if len(built_filenames) != count or len(set(built_filenames)) != count:
    raise SystemExit("built DKMS filename set is incomplete")
root = root_arg.resolve(strict=True)
try:
    excluded_relative = excluded_arg.relative_to(root_arg)
except ValueError:
    raise SystemExit("excluded CMP directory escapes the kernel tree")
if ".." in excluded_relative.parts:
    raise SystemExit("excluded CMP directory escapes the kernel tree")
excluded = root / excluded_relative
suffixes = ("", ".gz", ".xz", ".zst")
allowed_names = {name + suffix for name in names for suffix in suffixes}

rst = os.lstat(root)
if (not stat.S_ISDIR(rst.st_mode) or stat.S_ISLNK(rst.st_mode)
        or rst.st_uid != 0 or rst.st_gid != 0 or stat.S_IMODE(rst.st_mode) & 0o022):
    raise SystemExit("unsafe kernel module root")

mounted = set()
with open("/proc/self/mountinfo", "rb") as stream:
    for raw in stream:
        fields = raw.rstrip(b"\n").split(b" ")
        if len(fields) < 5:
            raise SystemExit("malformed mountinfo")
        decoded = re.sub(
            rb"\\([0-7]{3})",
            lambda match: bytes((int(match.group(1), 8),)),
            fields[4],
        )
        mounted.add(os.path.normpath(os.fsdecode(decoded)))
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    current_path = pathlib.Path(current)
    cst = os.lstat(current_path)
    if (not stat.S_ISDIR(cst.st_mode) or stat.S_ISLNK(cst.st_mode)
            or cst.st_uid != 0 or cst.st_gid != 0
            or stat.S_IMODE(cst.st_mode) & 0o022 or cst.st_dev != rst.st_dev):
        raise SystemExit(f"unsafe directory in kernel module tree: {current_path}")
    if current_path != root and os.path.normpath(os.fspath(current_path)) in mounted:
        raise SystemExit(f"nested mount in kernel module tree: {current_path}")
    kept = []
    for dirname in dirs:
        child = current_path / dirname
        if dirname in allowed_names:
            raise SystemExit(f"unexpected pre-install NVIDIA module object: {child}")
        try:
            if child.resolve(strict=False) == excluded:
                continue
        except OSError:
            raise SystemExit(f"cannot resolve kernel module directory: {child}")
        dst = os.lstat(child)
        if stat.S_ISLNK(dst.st_mode):
            continue
        if (not stat.S_ISDIR(dst.st_mode) or dst.st_uid != 0 or dst.st_gid != 0
                or stat.S_IMODE(dst.st_mode) & 0o022 or dst.st_dev != rst.st_dev
                or os.path.normpath(os.fspath(child)) in mounted):
            raise SystemExit(f"unsafe directory in kernel module tree: {child}")
        kept.append(dirname)
    dirs[:] = kept
    for filename in files:
        if filename not in allowed_names:
            continue
        path = current_path / filename
        raise SystemExit(f"unexpected pre-install NVIDIA module object: {path}")

# DKMS overrides DEST_MODULE_LOCATION deterministically by distro.  Pin the
# exact no-original target set rather than authorizing a name-wide cleanup.
os_release = pathlib.Path("/etc/os-release")
if not os.path.lexists(os_release):
    os_release = pathlib.Path("/usr/lib/os-release")
resolved_release = os_release.resolve(strict=True)
ost = os.lstat(resolved_release)
if (not stat.S_ISREG(ost.st_mode) or ost.st_uid != 0 or ost.st_gid != 0
        or stat.S_IMODE(ost.st_mode) & 0o022):
    raise SystemExit("unsafe os-release for DKMS target derivation")
release = {}
for number, raw in enumerate(resolved_release.read_text(encoding="ascii").splitlines(), 1):
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue
    match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)", stripped)
    if match is None:
        continue
    key, encoded = match.groups()
    if key not in ("ID", "ID_LIKE"):
        continue
    if key in release or any(token in encoded for token in ("$", "`", ";", "(", ")")):
        raise SystemExit(f"dynamic or duplicate {key} in os-release")
    values = shlex.split(encoded, posix=True)
    if len(values) != 1:
        raise SystemExit(f"ambiguous {key} in os-release")
    release[key] = values[0]
identifier = release.get("ID", "")
if identifier != "ubuntu" and release.get("ID_LIKE", ""):
    identifier = release["ID_LIKE"].split()[0]
if re.fullmatch(r"[a-z0-9._+-]+", identifier) is None:
    raise SystemExit("unsupported os-release identity")
if identifier.startswith(("debian", "ubuntu", "arch")):
    destination = pathlib.PurePosixPath("updates/dkms")
else:
    raise SystemExit(f"cannot safely reproduce DKMS weak-module state for {identifier}")

current = root
parent_missing = False
for component in destination.parts:
    current /= component
    if parent_missing or not os.path.lexists(current):
        parent_missing = True
        continue
    cst = os.lstat(current)
    if (not stat.S_ISDIR(cst.st_mode) or stat.S_ISLNK(cst.st_mode)
            or cst.st_uid != 0 or cst.st_gid != 0
            or stat.S_IMODE(cst.st_mode) & 0o022
            or cst.st_dev != rst.st_dev
            or os.path.normpath(os.fspath(current)) in mounted):
        raise SystemExit(f"unsafe DKMS target parent: {current}")

entries = []
for name in built_filenames:
    target = root.joinpath(*destination.parts, name)
    if os.path.lexists(target):
        raise SystemExit(f"DKMS install target is not absent: {target}")
    entries.append(f"{destination.as_posix()}/{name}@absent")
entries.sort()
print(";".join(entries))
PY
)" || return 1
    valid_dkms_install_target_manifest "${CAPTURED_DKMS_PREINSTALL_MANIFEST}"
}

verify_dkms_preinstall_manifest() {
    local kernel="$1" excluded="$2" expected="$3"
    capture_dkms_preinstall_manifest "${kernel}" "${excluded}" && \
        [[ "${CAPTURED_DKMS_PREINSTALL_MANIFEST}" == "${expected}" ]]
}

prepare_transaction_dkms() {
    local i="$1"
    local kernel="${KERNELS[$i]}" version="${EXPECTED_VERSIONS[$i]}"
    local prestate="${DKMS_PRESTATES[$i]}" parse_rc signing_before signing_after

    [[ "${prestate}" == "absent" ]] || return 0
    if [[ "${DKMS_ATTEMPTED_FLAGS[$i]}" == "1" ]]; then
        [[ "${DKMS_INSTALL_ATTEMPTED_FLAGS[$i]}" == "0" && \
           "${DKMS_BUILT_HASH_SETS[$i]}" != "pending" && \
           "${DKMS_PREINSTALL_MANIFESTS[$i]}" != "pending" ]] || \
            die "Cannot reuse incomplete pre-forward DKMS state for ${kernel}"
        parse_dkms_receipt "${kernel}" "${version}" || \
            die "Required DKMS receipt changed for ${kernel}"
        [[ "${DKMS_ARCH}" == "${DKMS_ARCHES[$i]}" ]] || \
            die "DKMS receipt architecture changed before build reuse for ${kernel}"
        ensure_dkms_tool
        query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
            [[ "${DKMS_TUPLE_STATE}" == "present" ]] || \
            die "Reusable DKMS tuple changed for ${kernel}"
        capture_dkms_built_hashes "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
            [[ "${CAPTURED_DKMS_BUILT_HASHES}" == "${DKMS_BUILT_HASH_SETS[$i]}" && \
               "${CAPTURED_DKMS_BUILT_PAYLOAD_HASHES}" == "${STOCK_HASH_SETS[$i]}" ]] || \
            die "Reusable DKMS payload changed for ${kernel}"
        validate_dkms_built_signature_policy "${DKMS_VERSION}" "${DKMS_KERNEL}" \
            "${DKMS_ARCH}" || \
            die "Reusable DKMS signature identity is incomplete or inconsistent for ${kernel}"
        verify_dkms_preinstall_manifest "${kernel}" "${MODULE_DIRS[$i]}" \
            "${DKMS_PREINSTALL_MANIFESTS[$i]}" || \
            die "Reusable DKMS target manifest changed for ${kernel}"
        forward_dkms_tuple validate "${version}" "${kernel}" "${DKMS_ARCHES[$i]}" \
            "${DKMS_BUILT_HASH_SETS[$i]}" "${DKMS_PREINSTALL_MANIFESTS[$i]}" \
            "${MODULE_DIRS[$i]}" "${MODULE_BACKUPS[$i]}" || \
            die "Reusable DKMS forward proof changed for ${kernel}"
        info "Reusing durable DKMS build for ${kernel}"
        return 0
    fi
    if parse_dkms_receipt "${kernel}" "${version}"; then
        :
    else
        parse_rc=$?
        (( parse_rc == 2 )) && die "Required DKMS receipt disappeared for ${kernel}"
        die "Invalid DKMS receipt for ${kernel}"
    fi
    [[ "${DKMS_ARCH}" == "${DKMS_ARCHES[$i]}" ]] || \
        die "DKMS receipt architecture changed before build for ${kernel}"
    ensure_dkms_tool
    query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
        die "Cannot inspect exact DKMS tuple for ${kernel}"
    [[ "${DKMS_TUPLE_STATE}" == "absent" && "${DKMS_GLOBAL_ADDED}" == "1" ]] && \
        dkms_exact_residue_absent "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
        die "DKMS tuple changed after its absent baseline was recorded for ${kernel}"

    # Reject an unsafe DKMS destination before build creates any tuple
    # artifacts.  The post-build capture below repeats the same namespace and
    # ancestor checks with the exact built compression suffixes.
    capture_dkms_preinstall_manifest "${kernel}" "${MODULE_DIRS[$i]}" uncompressed || \
        die "Could not preflight the DKMS installation namespace for ${kernel}"
    validate_dkms_signing_preflight "${kernel}" || \
        die "DKMS signing policy could create or change credentials for ${kernel}; prepare any required MOK explicitly outside removal"
    signing_before="${DKMS_SIGNING_MODE}|${DKMS_SIGNING_KEY}|${DKMS_SIGNING_CERT}|${DKMS_SIGNING_KEY_HASH}|${DKMS_SIGNING_CERT_HASH}|${DKMS_SIGNING_PROGRAM}|${DKMS_SIGNING_PROGRAM_HASH}"

    # Build changes B, so acquire cleanup authority before invoking DKMS.
    DKMS_ATTEMPTED_FLAGS[$i]=1
    write_remove_state "removing" "${kernel}" "${version}" \
        "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" "${MODULE_BACKUPS[$i]}" \
        "${prestate}" "1" "${FIRMWARE_PRESTATES[$i]}" \
        "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" "${FIRMWARE_STOCK_HASHES[$i]}" \
        "${FIRMWARE_PATCHED_HASHES[$i]}" "0" "${STOCK_HASH_SETS[$i]}" \
        "0" "pending" "pending" "${DKMS_ARCHES[$i]}"
    info "Building exact DKMS tuple nvidia/${DKMS_VERSION}, ${DKMS_KERNEL}, ${DKMS_ARCH}"
    (umask 022; dkms_sanitized build nvidia/"${DKMS_VERSION}" -k "${DKMS_KERNEL}" \
        -a "${DKMS_ARCH}" --no-depmod --dkmstree "${DKMS_TREE}" \
        --installtree "${DKMS_INSTALL_TREE}" \
        "${DKMS_SAFE_DIRECTIVES[@]}") || \
        die "Failed to build exact DKMS tuple for ${DKMS_KERNEL}"
    validate_dkms_tree_configuration || \
        die "DKMS framework configuration changed during build for ${kernel}"
    validate_dkms_signing_preflight "${kernel}" || \
        die "DKMS signing inputs became unsafe during build for ${kernel}"
    signing_after="${DKMS_SIGNING_MODE}|${DKMS_SIGNING_KEY}|${DKMS_SIGNING_CERT}|${DKMS_SIGNING_KEY_HASH}|${DKMS_SIGNING_CERT_HASH}|${DKMS_SIGNING_PROGRAM}|${DKMS_SIGNING_PROGRAM_HASH}"
    [[ "${signing_after}" == "${signing_before}" ]] || \
        die "DKMS signing policy, key, certificate, or signing program changed during build for ${kernel}"
    capture_dkms_built_hashes "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
        die "Could not bind the exact built DKMS module set for ${kernel}"
    validate_dkms_built_signature_policy "${DKMS_VERSION}" "${DKMS_KERNEL}" \
        "${DKMS_ARCH}" || \
        die "DKMS built modules have missing or inconsistent signature fields for ${kernel}"
    [[ "${signing_after%%|*}" != "active" || \
       "${DKMS_BUILT_SIGNATURE_MODE}" == "signed" ]] || \
        die "Active DKMS signing policy produced unsigned modules for ${kernel}"
    capture_dkms_preinstall_manifest "${kernel}" "${MODULE_DIRS[$i]}" || \
        die "Could not bind the pre-install NVIDIA module inventory for ${kernel}"
    DKMS_BUILT_HASH_SETS[$i]="${CAPTURED_DKMS_BUILT_HASHES}"
    STOCK_HASH_SETS[$i]="${CAPTURED_DKMS_BUILT_PAYLOAD_HASHES}"
    DKMS_PREINSTALL_MANIFESTS[$i]="${CAPTURED_DKMS_PREINSTALL_MANIFEST}"
    write_remove_state "removing" "${kernel}" "${version}" \
        "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" "${MODULE_BACKUPS[$i]}" \
        "${prestate}" "1" "${FIRMWARE_PRESTATES[$i]}" \
        "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" "${FIRMWARE_STOCK_HASHES[$i]}" \
        "${FIRMWARE_PATCHED_HASHES[$i]}" "0" "${STOCK_HASH_SETS[$i]}" \
        "0" "${DKMS_BUILT_HASH_SETS[$i]}" "${DKMS_PREINSTALL_MANIFESTS[$i]}" \
        "${DKMS_ARCHES[$i]}"
}

restore_transaction_dkms() {
    local i="$1"
    local kernel="${KERNELS[$i]}" version="${EXPECTED_VERSIONS[$i]}"
    local prestate="${DKMS_PRESTATES[$i]}" parse_rc signature_mode signature_identity

    case "${prestate}" in
        none)
            [[ ! -e "${STATE_DIR}/dkms-removed.${kernel}.receipt" && \
               ! -L "${STATE_DIR}/dkms-removed.${kernel}.receipt" ]] || \
                die "Unexpected DKMS receipt appeared for ${kernel}"
            return 0
            ;;
        installed)
            parse_dkms_receipt "${kernel}" "${version}" || \
                die "Required DKMS receipt is missing or invalid for ${kernel}"
            [[ "${DKMS_ARCH}" == "${DKMS_ARCHES[$i]}" ]] || \
                die "DKMS receipt architecture changed before removal for ${kernel}"
            ensure_dkms_tool
            query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
                die "Cannot inspect preinstalled DKMS tuple for ${kernel}"
            [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
                die "Preinstalled DKMS tuple changed before removal for ${kernel}"
            return 0
            ;;
        absent) ;;
        *) die "Internal invalid DKMS prestate for ${kernel}" ;;
    esac
    if parse_dkms_receipt "${kernel}" "${version}"; then
        :
    else
        parse_rc=$?
        (( parse_rc == 2 )) && die "Required DKMS receipt disappeared for ${kernel}"
        die "Invalid DKMS receipt for ${kernel}"
    fi
    [[ "${DKMS_ARCH}" == "${DKMS_ARCHES[$i]}" ]] || \
        die "DKMS receipt architecture changed before installation for ${kernel}"
    ensure_dkms_tool
    query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" || \
        die "Cannot inspect exact DKMS tuple for ${kernel}"
    [[ "${DKMS_TUPLE_STATE}" == "present" && \
       "${DKMS_ATTEMPTED_FLAGS[$i]}" == "1" && \
       "${DKMS_INSTALL_ATTEMPTED_FLAGS[$i]}" == "0" ]] || \
        die "Built DKMS tuple changed before installation for ${kernel}"
    capture_dkms_built_hashes "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
        [[ "${CAPTURED_DKMS_BUILT_HASHES}" == "${DKMS_BUILT_HASH_SETS[$i]}" ]] || \
        die "Built DKMS module bytes changed before installation for ${kernel}"
    verify_dkms_preinstall_manifest "${kernel}" "${MODULE_DIRS[$i]}" \
        "${DKMS_PREINSTALL_MANIFESTS[$i]}" || \
        die "NVIDIA module inventory changed before DKMS installation for ${kernel}"

    forward_dkms_tuple validate "${version}" "${kernel}" "${DKMS_ARCHES[$i]}" \
        "${DKMS_BUILT_HASH_SETS[$i]}" "${DKMS_PREINSTALL_MANIFESTS[$i]}" \
        "${MODULE_DIRS[$i]}" "${MODULE_BACKUPS[$i]}" || \
        die "DKMS target namespace changed before forward publication for ${kernel}"
    validate_dkms_built_signature_policy "${version}" "${kernel}" \
        "${DKMS_ARCHES[$i]}" || \
        die "DKMS signature identity changed before publication for ${kernel}"
    signature_mode="${DKMS_BUILT_SIGNATURE_MODE}"
    signature_identity="${DKMS_BUILT_SIGNATURE_IDENTITY}"

    # Publish exact-copy authority before the first target leaf.  Recovery
    # completes missing leaves and the active link monotonically from B.
    DKMS_INSTALL_ATTEMPTED_FLAGS[$i]=1
    write_remove_state "removing" "${kernel}" "${version}" \
        "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" "${MODULE_BACKUPS[$i]}" \
        "${prestate}" "1" "${FIRMWARE_PRESTATES[$i]}" \
        "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" "${FIRMWARE_STOCK_HASHES[$i]}" \
        "${FIRMWARE_PATCHED_HASHES[$i]}" "0" "${STOCK_HASH_SETS[$i]}" \
        "1" "${DKMS_BUILT_HASH_SETS[$i]}" "${DKMS_PREINSTALL_MANIFESTS[$i]}" \
        "${DKMS_ARCHES[$i]}"
    info "Publishing exact DKMS tuple nvidia/${DKMS_VERSION}, ${DKMS_KERNEL}, ${DKMS_ARCH}"
    forward_dkms_tuple publish "${version}" "${kernel}" "${DKMS_ARCHES[$i]}" \
        "${DKMS_BUILT_HASH_SETS[$i]}" "${DKMS_PREINSTALL_MANIFESTS[$i]}" \
        "${MODULE_DIRS[$i]}" "${MODULE_BACKUPS[$i]}" || \
        die "Failed to publish exact DKMS tuple for ${DKMS_KERNEL}"
    verify_published_dkms_signature_identity "${kernel}" \
        "${DKMS_PREINSTALL_MANIFESTS[$i]}" "${signature_mode}" \
        "${signature_identity}" || \
        die "Published DKMS signature fields differ from the built payloads for ${kernel}"
    query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
        [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
        die "DKMS did not report the restored tuple as installed"
}

mark_firmware_attempted_for_version() {
    local version="$1" i main main_hash needs_mark=0

    for i in "${!EXPECTED_VERSIONS[@]}"; do
        if [[ "${EXPECTED_VERSIONS[$i]}" == "${version}" && \
              "${FIRMWARE_PRESTATES[$i]}" == "patched" && \
              "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" == "0" ]]; then
            needs_mark=1
        fi
    done
    (( needs_mark == 1 )) || return 0
    main="/lib/firmware/nvidia/${version}/gsp_tu10x.bin"
    firmware_namespace_action "${version}" inspect || \
        die "Could not recheck firmware before recording copy intent for ${version}"
    main_hash="${FIRMWARE_NAMESPACE_MAIN_HASH}"
    for i in "${!EXPECTED_VERSIONS[@]}"; do
        [[ "${EXPECTED_VERSIONS[$i]}" == "${version}" && \
           "${FIRMWARE_PRESTATES[$i]}" == "patched" ]] || continue
        [[ "${main_hash}" == "${FIRMWARE_PATCHED_HASHES[$i]}" && \
           "${FIRMWARE_NAMESPACE_BACKUP_HASH}" == \
             "${FIRMWARE_STOCK_HASHES[$i]}" && \
           "${FIRMWARE_NAMESPACE_PATCHED_HASH}" == \
             "${FIRMWARE_PATCHED_HASHES[$i]}" ]] || \
            die "Firmware changed before removal acquired copy authority for ${version}"
    done
    for i in "${!EXPECTED_VERSIONS[@]}"; do
        [[ "${EXPECTED_VERSIONS[$i]}" == "${version}" && \
           "${FIRMWARE_PRESTATES[$i]}" == "patched" && \
           "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" == "0" ]] || continue
        FIRMWARE_ATTEMPTED_FLAGS[$i]=1
        write_remove_state "removing" "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}" \
            "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" "${MODULE_BACKUPS[$i]}" \
            "${DKMS_PRESTATES[$i]}" "${DKMS_ATTEMPTED_FLAGS[$i]}" \
            "${FIRMWARE_PRESTATES[$i]}" "1" "${FIRMWARE_STOCK_HASHES[$i]}" \
            "${FIRMWARE_PATCHED_HASHES[$i]}" "0" "${STOCK_HASH_SETS[$i]}" \
            "${DKMS_INSTALL_ATTEMPTED_FLAGS[$i]}" "${DKMS_BUILT_HASH_SETS[$i]}" \
            "${DKMS_PREINSTALL_MANIFESTS[$i]}" "${DKMS_ARCHES[$i]}"
    done
}

rollback_module_removal() {
    local i state_path

    warn "Stopping before the forward barrier; the running driver remains untouched"
    if [[ -e "${REMOVE_FORWARD}" || -L "${REMOVE_FORWARD}" ]]; then
        warn "A durable forward-only marker exists; preserving it for forward recovery"
        REMOVE_TRANSACTION_ACTIVE=0
        return 1
    fi
    if [[ -e "${REMOVE_COMMIT}" || -L "${REMOVE_COMMIT}" ]]; then
        warn "A legacy stock commit exists; preserving it for forward recovery"
        REMOVE_TRANSACTION_ACTIVE=0
        return 1
    fi
    for i in "${!DKMS_ATTEMPTED_FLAGS[@]}"; do
        if [[ "${DKMS_ATTEMPTED_FLAGS[$i]:-0}" == "1" ]]; then
            warn "DKMS build work for ${KERNELS[$i]} may exist without a durable payload journal"
            warn "Preserving CMP, firmware, all removal states, and every canonical DKMS object; manual reconciliation is required if a retry reports residue"
            REMOVE_TRANSACTION_ACTIVE=0
            return 1
        fi
    done
    # No side effect precedes a DKMS build in the new transaction order.  If
    # no build intent exists, every live CMP/firmware baseline must still be
    # exact and only the freshly-created private state records need removal.
    for i in "${!MODULE_DIRS[@]}"; do
        [[ -d "${MODULE_DIRS[$i]}" && ! -L "${MODULE_DIRS[$i]}" && \
           ! -e "${MODULE_BACKUPS[$i]:-}" && ! -L "${MODULE_BACKUPS[$i]:-}" && \
           "${FIRMWARE_ATTEMPTED_FLAGS[$i]:-0}" == "0" ]] || \
            die "Pre-forward failure crossed an unjournaled mutation boundary for ${KERNELS[$i]}"
        state_path="$(remove_state_path "${KERNELS[$i]}")"
        if [[ -e "${state_path}" || -L "${state_path}" ]]; then
            parse_remove_state "${state_path}" && \
                [[ "${REMOVE_PHASE}" == "removing" && \
                   "${REMOVE_DKMS_ATTEMPTED}" == "0" && \
                   "${REMOVE_FIRMWARE_ATTEMPTED}" == "0" && \
                   "${REMOVE_BACKUP}" == "${MODULE_BACKUPS[$i]}" ]] || \
                die "Cannot safely reset pre-forward state ${state_path}"
            durable_remove_file "${state_path}" || \
                die "Could not reset pre-forward state ${state_path}"
        fi
    done
    REMOVE_TRANSACTION_ACTIVE=0
}

remove_transaction_exit() {
    local rc=$?
    trap - EXIT
    if (( REMOVE_TRANSACTION_ACTIVE == 1 )); then
        rollback_module_removal || true
    fi
    exit "${rc}"
}
trap remove_transaction_exit EXIT

step "Restoring and validating the stock on-disk driver"
if (( ${#RESUME_KERNELS[@]} > 0 )); then
    ensure_recovery_tools
    for i in "${!RESUME_KERNELS[@]}"; do
        if [[ "${RESUME_STOCK_ALREADY_PUBLISHED_FLAGS[$i]:-0}" == "1" ]]; then
            verify_stock_module_set "${RESUME_KERNELS[$i]}" \
                "${RESUME_VERSIONS[$i]}" "${RESUME_PATCHED_SRCS[$i]}" \
                "${RESUME_PATCHED_HASH_SETS[$i]}" \
                "${RESUME_STOCK_HASH_SETS[$i]}" || \
                die "Recovered stock state changed for ${RESUME_KERNELS[$i]}"
            continue
        fi
        prepare_stock_firmware "${RESUME_VERSIONS[$i]}" 1 \
            "${RESUME_FIRMWARE_STOCK_HASHES[$i]}" \
            "${RESUME_FIRMWARE_PATCHED_HASHES[$i]}" \
            "${RESUME_FIRMWARE_PRESTATES[$i]}" \
            "${RESUME_FIRMWARE_ATTEMPTED_FLAGS[$i]}"
        ensure_stock_dkms_state "${RESUME_KERNELS[$i]}" "${RESUME_VERSIONS[$i]}" \
            "${RESUME_DKMS_PRESTATES[$i]}" \
            "${RESUME_DKMS_ATTEMPTED_FLAGS[$i]}" \
            "${RESUME_DKMS_RECEIPT_COMMITTED_FLAGS[$i]}" \
            "${RESUME_DKMS_ARCHES[$i]}"
        depmod -a "${RESUME_KERNELS[$i]}" || \
            die "depmod failed while resuming stock state for ${RESUME_KERNELS[$i]}"
        verify_stock_module_set "${RESUME_KERNELS[$i]}" "${RESUME_VERSIONS[$i]}" \
            "${RESUME_PATCHED_SRCS[$i]}" "${RESUME_PATCHED_HASH_SETS[$i]}" \
            "${RESUME_STOCK_HASH_SETS[$i]}" || \
            die "Stock state no longer validates for ${RESUME_KERNELS[$i]}"
        rebuild_kernel_initramfs "${RESUME_KERNELS[$i]}" || \
            die "initramfs refresh failed while resuming ${RESUME_KERNELS[$i]}"
        sync || die "Could not persist resumed stock state for ${RESUME_KERNELS[$i]}"
    done
    STOCK_READY=1
    # Resume work is already committed to stock and must never be reverted by
    # a later, independent live-module transaction in this invocation.
    FIRMWARE_CHANGED_MAIN=()
fi

if (( ${#MODULE_DIRS[@]} > 0 )); then
    ensure_recovery_tools
    for i in "${!MODULE_DIRS[@]}"; do
        if [[ "${LIVE_STATE_PRESENT_FLAGS[$i]:-0}" == "1" ]]; then
            continue
        fi
        determine_dkms_prestate "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}"
        DKMS_PRESTATES[$i]="${DETERMINED_DKMS_PRESTATE}"
        DKMS_ATTEMPTED_FLAGS[$i]=0
        DKMS_ARCHES[$i]="${DETERMINED_DKMS_ARCH}"
        DKMS_INSTALL_ATTEMPTED_FLAGS[$i]=0
        DKMS_BUILT_HASH_SETS[$i]=pending
        DKMS_PREINSTALL_MANIFESTS[$i]=pending
        determine_firmware_prestate "${EXPECTED_VERSIONS[$i]}"
        FIRMWARE_PRESTATES[$i]="${DETERMINED_FIRMWARE_PRESTATE}"
        FIRMWARE_ATTEMPTED_FLAGS[$i]=0
        FIRMWARE_STOCK_HASHES[$i]="${DETERMINED_FIRMWARE_STOCK_HASH}"
        FIRMWARE_PATCHED_HASHES[$i]="${DETERMINED_FIRMWARE_PATCHED_HASH}"
        DKMS_RECEIPT_COMMITTED_FLAGS[$i]=0
        STOCK_HASH_SETS[$i]=pending
        if [[ "${DKMS_PRESTATES[$i]}" != "absent" ]]; then
            capture_prebarrier_stock_set "${KERNELS[$i]}" \
                "${EXPECTED_VERSIONS[$i]}" "${PATCHED_CORE_SRCS[$i]}" \
                "${PATCHED_HASH_SETS[$i]}" "${MODULE_DIRS[$i]}" || \
                die "No unique exact stock five-module set exists before the removal barrier for ${KERNELS[$i]}"
            STOCK_HASH_SETS[$i]="${CAPTURED_STOCK_HASHES}"
            DKMS_PREINSTALL_MANIFESTS[$i]="${CAPTURED_STOCK_MANIFEST}"
        fi
    done
    REMOVE_TRANSACTION_ACTIVE=1
    for i in "${!MODULE_DIRS[@]}"; do
        MODULE_MOVED[$i]=0
        if [[ "${LIVE_STATE_PRESENT_FLAGS[$i]:-0}" == "1" ]]; then
            continue
        fi
        backup_nonce="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(3))
PY
)"
        [[ "${backup_nonce}" =~ ^[a-f0-9]{6}$ ]] || die "Could not generate rollback nonce"
        backup="/lib/modules/.cmpunlocker.remove.${KERNELS[$i]}.${backup_nonce}"
        [[ ! -e "${backup}" && ! -L "${backup}" ]] || die "Rollback path collision: ${backup}"
        MODULE_BACKUPS[$i]="${backup}"
        write_remove_state "removing" "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}" \
            "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" "${backup}" \
            "${DKMS_PRESTATES[$i]}" "${DKMS_ATTEMPTED_FLAGS[$i]}" \
            "${FIRMWARE_PRESTATES[$i]}" "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" \
            "${FIRMWARE_STOCK_HASHES[$i]}" \
            "${FIRMWARE_PATCHED_HASHES[$i]}" "0" "${STOCK_HASH_SETS[$i]}" \
            "${DKMS_INSTALL_ATTEMPTED_FLAGS[$i]}" "${DKMS_BUILT_HASH_SETS[$i]}" \
            "${DKMS_PREINSTALL_MANIFESTS[$i]}" "${DKMS_ARCHES[$i]}"
    done

    # Canonical DKMS builds are the only pre-barrier external mutation.  A cut
    # while DKMS owns its shared build workspace is deliberately fail-closed;
    # CMP, firmware, module resolution, and initramfs remain unchanged.
    for i in "${!KERNELS[@]}"; do
        prepare_transaction_dkms "${i}"
    done
    for i in "${!KERNELS[@]}"; do
        if [[ "${DKMS_PRESTATES[$i]}" == "absent" ]]; then
            capture_dkms_built_hashes "${EXPECTED_VERSIONS[$i]}" "${KERNELS[$i]}" \
                "${DKMS_ARCHES[$i]}" && \
                [[ "${CAPTURED_DKMS_BUILT_HASHES}" == "${DKMS_BUILT_HASH_SETS[$i]}" && \
                   "${CAPTURED_DKMS_BUILT_PAYLOAD_HASHES}" == "${STOCK_HASH_SETS[$i]}" ]] || \
                die "DKMS stock payload changed before the forward barrier for ${KERNELS[$i]}"
            validate_dkms_built_signature_policy "${EXPECTED_VERSIONS[$i]}" \
                "${KERNELS[$i]}" "${DKMS_ARCHES[$i]}" || \
                die "DKMS signature proof changed before the forward barrier for ${KERNELS[$i]}"
            forward_dkms_tuple validate "${EXPECTED_VERSIONS[$i]}" "${KERNELS[$i]}" \
                "${DKMS_ARCHES[$i]}" "${DKMS_BUILT_HASH_SETS[$i]}" \
                "${DKMS_PREINSTALL_MANIFESTS[$i]}" "${MODULE_DIRS[$i]}" \
                "${MODULE_BACKUPS[$i]}" || \
                die "DKMS build proof changed before the forward barrier for ${KERNELS[$i]}"
        else
            verify_prebarrier_stock_set "${KERNELS[$i]}" \
                "${EXPECTED_VERSIONS[$i]}" "${PATCHED_CORE_SRCS[$i]}" \
                "${PATCHED_HASH_SETS[$i]}" "${MODULE_DIRS[$i]}" \
                "${STOCK_HASH_SETS[$i]}" "${DKMS_PREINSTALL_MANIFESTS[$i]}" || \
                die "Stock candidate changed before the forward barrier for ${KERNELS[$i]}"
        fi
    done
    write_remove_forward
    # From this durable point onward every retry is forward-only.  EXIT must
    # never republish CMP or delete a canonical DKMS build.
    REMOVE_TRANSACTION_ACTIVE=0

    for i in "${!EXPECTED_VERSIONS[@]}"; do
        if [[ "${FIRMWARE_PRESTATES[$i]}" == "patched" ]]; then
            mark_firmware_attempted_for_version "${EXPECTED_VERSIONS[$i]}"
        fi
        prepare_stock_firmware "${EXPECTED_VERSIONS[$i]}" 0 \
            "${FIRMWARE_STOCK_HASHES[$i]}" "${FIRMWARE_PATCHED_HASHES[$i]}" \
            "${FIRMWARE_PRESTATES[$i]}" "${FIRMWARE_ATTEMPTED_FLAGS[$i]}"
    done

    for i in "${!MODULE_DIRS[@]}"; do
        rename_cmp_module_dir_noreplace "${MODULE_DIRS[$i]}" \
            "${MODULE_BACKUPS[$i]}" "${KERNELS[$i]}" \
            "${EXPECTED_VERSIONS[$i]}" "${PATCHED_HASH_SETS[$i]}" || \
            die "Could not move patched modules to rollback storage for ${KERNELS[$i]}"
        MODULE_MOVED[$i]=1
        validate_cmp_module_dir "${MODULE_BACKUPS[$i]}" "${KERNELS[$i]}" && \
            [[ "${VALIDATED_DRIVER_VERSION}" == "${EXPECTED_VERSIONS[$i]}" && \
               "${VALIDATED_CORE_SRC}" == "${PATCHED_CORE_SRCS[$i]}" && \
               "${VALIDATED_PATCHED_HASHES}" == "${PATCHED_HASH_SETS[$i]}" ]] || \
            die "Patched module set changed during removal for ${KERNELS[$i]}"
    done

    for i in "${!KERNELS[@]}"; do
        restore_transaction_dkms "${i}"
    done

    for i in "${!KERNELS[@]}"; do
        depmod -a "${KERNELS[$i]}" || \
            die "depmod failed while selecting stock modules for ${KERNELS[$i]}"
        verify_stock_module_set "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}" \
            "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" \
            "${STOCK_HASH_SETS[$i]}" || \
            die "No exact, non-patched stock five-module set exists for ${KERNELS[$i]}"
        [[ "${VERIFIED_STOCK_HASHES}" == "${STOCK_HASH_SETS[$i]}" ]] || \
            die "Resolved stock hashes differ from the pre-barrier proof for ${KERNELS[$i]}"
        write_remove_state "removing" "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}" \
            "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" "${MODULE_BACKUPS[$i]}" \
            "${DKMS_PRESTATES[$i]}" "${DKMS_ATTEMPTED_FLAGS[$i]}" \
            "${FIRMWARE_PRESTATES[$i]}" "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" \
            "${FIRMWARE_STOCK_HASHES[$i]}" "${FIRMWARE_PATCHED_HASHES[$i]}" \
            "0" "${STOCK_HASH_SETS[$i]}" \
            "${DKMS_INSTALL_ATTEMPTED_FLAGS[$i]}" "${DKMS_BUILT_HASH_SETS[$i]}" \
            "${DKMS_PREINSTALL_MANIFESTS[$i]}" "${DKMS_ARCHES[$i]}"
    done
    for i in "${!KERNELS[@]}"; do
        verify_stock_module_set "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}" \
            "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" \
            "${STOCK_HASH_SETS[$i]}" || \
            die "Recorded stock module set changed before initramfs for ${KERNELS[$i]}"
    done
    for kernel in "${KERNELS[@]}"; do
        rebuild_kernel_initramfs "${kernel}" || \
            die "Stock initramfs rebuild failed for ${kernel}; rerun removal to continue forward"
    done
    sync || die "Could not persist verified stock modules and initramfs"
    for i in "${!KERNELS[@]}"; do
        write_remove_state "stock-ready" "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}" \
            "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" "${MODULE_BACKUPS[$i]}" \
            "${DKMS_PRESTATES[$i]}" "${DKMS_ATTEMPTED_FLAGS[$i]}" \
            "${FIRMWARE_PRESTATES[$i]}" "${FIRMWARE_ATTEMPTED_FLAGS[$i]}" \
            "${FIRMWARE_STOCK_HASHES[$i]}" \
            "${FIRMWARE_PATCHED_HASHES[$i]}" "0" "${STOCK_HASH_SETS[$i]}" \
            "${DKMS_INSTALL_ATTEMPTED_FLAGS[$i]}" "${DKMS_BUILT_HASH_SETS[$i]}" \
            "${DKMS_PREINSTALL_MANIFESTS[$i]}" "${DKMS_ARCHES[$i]}"
        CLEANUP_STATE_PATHS+=("$(remove_state_path "${KERNELS[$i]}")")
    done

    for i in "${!MODULE_BACKUPS[@]}"; do
        safe_remove_backup "${MODULE_BACKUPS[$i]}" "${KERNELS[$i]}" \
            "${EXPECTED_VERSIONS[$i]}" "${PATCHED_HASH_SETS[$i]}" validate || \
            die "Stock is ready, but backup cleanup proof failed at ${MODULE_BACKUPS[$i]}"
    done
    for i in "${!MODULE_BACKUPS[@]}"; do
        safe_remove_backup "${MODULE_BACKUPS[$i]}" "${KERNELS[$i]}" \
            "${EXPECTED_VERSIONS[$i]}" "${PATCHED_HASH_SETS[$i]}" || \
            die "Stock is ready, but rollback cleanup failed at ${MODULE_BACKUPS[$i]}"
    done
    durable_remove_file "${REMOVE_FORWARD}" || \
        die "Stock backups are clean, but forward barrier finalization failed"
    STOCK_READY=1
    ok "Committed ${#MODULE_DIRS[@]} exact stock module transition(s)"
elif (( ${#RESUME_KERNELS[@]} == 0 )); then
    info "No module transition was needed"
fi

trap - EXIT

cleanup_gen2_owned() {
    local -a unit_hashes=() hammer_hashes=() modprobe_hashes=()
    local manager_unit_owned=0
    local unit_link_authority=none

    [[ -e "${GEN2_STATE}" || -L "${GEN2_STATE}" ]] || return 0
    parse_gen2_state || die "Gen2 ownership changed after preflight; preserving all remaining files"
    if [[ "${GEN2_UNIT_HASH}" != "absent" ]]; then
        [[ "${GEN2_UNIT_HASH}" == "${GEN2_SYSINIT_UNIT_HASH}" ]] || \
            die "Gen2 unit revision has no exact enable-link manifest"
        unit_link_authority=sysinit.target.wants
        (( GEN2_SYSTEMD_MUTATION_REQUIRED == 1 )) || \
            die "Gen2 manager-action preflight was not completed"
    else
        (( GEN2_SYSTEMD_MUTATION_REQUIRED == 0 )) || \
            die "Gen2 manager-action scope changed after preflight"
    fi
    if (( GEN2_SYSTEMD_MUTATION_REQUIRED == 1 )); then
        validate_trusted_executable "${SYSTEMCTL_EXECUTABLE}" || \
            die "A fixed trusted systemctl is required for Gen2 cleanup"
    fi
    if [[ "${GEN2_UNIT_HASH}" != "absent" && \
          ( -e "${GEN2_UNIT_PATH}" || -L "${GEN2_UNIT_PATH}" ) ]]; then
        manager_unit_owned=1
        validate_legacy_unit_namespace gen2.service "${GEN2_UNIT_PATH}" || \
            die "Owned gen2.service has an alternate fragment or drop-in"
        cleanup_owned_unit_links gen2.service "${GEN2_UNIT_PATH}" validate \
            "${unit_link_authority}" || \
            die "Gen2 enable-link namespace is not exactly deletion-authorized"
        unit_hashes=("${GEN2_UNIT_HASH}")
        legacy_file_has_allowed_hash "${GEN2_UNIT_PATH}" unit_hashes || \
            die "Owned gen2.service changed before manager reload"
        systemctl_sanitized daemon-reload || \
            die "systemd daemon-reload failed before Gen2 cleanup"
        legacy_file_has_allowed_hash "${GEN2_UNIT_PATH}" unit_hashes && \
        validate_loaded_legacy_unit gen2.service "${GEN2_UNIT_PATH}" || \
            die "systemd does not bind gen2.service to the receipt-owned fragment"
        legacy_file_has_allowed_hash "${GEN2_UNIT_PATH}" unit_hashes && \
            validate_loaded_legacy_unit gen2.service "${GEN2_UNIT_PATH}" || \
            die "Owned gen2.service changed before stop"
        systemctl_sanitized stop gen2.service || \
            die "Failed to stop owned gen2.service"
        validate_quiescent_legacy_unit gen2.service || \
            die "Owned gen2.service did not reach an idle inactive state"
    fi
    cleanup_owned_unit_links gen2.service "${GEN2_UNIT_PATH}" remove \
        "${unit_link_authority}" || \
        die "Could not durably clear receipt-owned gen2.service enable links"
    if (( manager_unit_owned == 1 )); then
        systemctl_sanitized reset-failed gen2.service 2>/dev/null || true
        systemctl_sanitized is-enabled --quiet gen2.service 2>/dev/null && \
            die "Owned gen2.service remains enabled after exact link cleanup"
        validate_quiescent_legacy_unit gen2.service || \
            die "Owned gen2.service changed state before fragment cleanup"
    fi
    if [[ "${GEN2_UNIT_HASH}" != "absent" && \
          ( -e "${GEN2_UNIT_PATH}" || -L "${GEN2_UNIT_PATH}" ) ]]; then
        unit_hashes=("${GEN2_UNIT_HASH}")
        validate_legacy_unit_namespace gen2.service "${GEN2_UNIT_PATH}" && \
            durable_remove_allowed_legacy_file "${GEN2_UNIT_PATH}" unit_hashes || \
            die "Owned Gen2 unit changed during removal"
    fi
    if [[ "${GEN2_HAMMER_HASH}" != "absent" && \
          ( -e "${GEN2_HAMMER_PATH}" || -L "${GEN2_HAMMER_PATH}" ) ]]; then
        hammer_hashes=("${GEN2_HAMMER_HASH}")
        durable_remove_allowed_legacy_file "${GEN2_HAMMER_PATH}" hammer_hashes || \
            die "Owned Gen2 helper changed during removal"
    fi
    if [[ -e "${GEN2_MODPROBE_PATH}" || -L "${GEN2_MODPROBE_PATH}" ]]; then
        modprobe_hashes=("${GEN2_MODPROBE_HASH}")
        durable_remove_allowed_legacy_file "${GEN2_MODPROBE_PATH}" modprobe_hashes || \
            die "Owned Gen2 modprobe file changed during removal"
    fi
    if (( GEN2_SYSTEMD_MUTATION_REQUIRED == 1 )); then
        systemctl_sanitized daemon-reload || \
            die "systemd daemon-reload failed after Gen2 cleanup"
        validate_legacy_unit_namespace gen2.service "${GEN2_UNIT_PATH}" && \
            validate_unloaded_legacy_unit gen2.service || \
            die "systemd retained Gen2 state after exact fragment cleanup"
    fi
    durable_remove_file "${GEN2_STATE}" || die "Could not commit Gen2 ownership cleanup"
    ok "Removed only hash-verified Gen2 assets"
}

cleanup_namespaced_services() {
    local unit path expected_hash watchdog_hash=absent retrain_hash=absent
    local watchdog_link=absent retrain_link=absent link_path
    local -a exact_hash=()
    local -A owned_units=()
    local -A owned_unit_hashes=()
    local -A owned_helpers=()

    SERVICE_REMOVE_PRESENT=0
    if [[ -e "${SERVICE_REMOVE_PENDING}" || -L "${SERVICE_REMOVE_PENDING}" ]]; then
        parse_service_remove_pending && validate_service_remove_pending_assets || \
            die "Service reload intent changed after preflight"
        if [[ "${SERVICE_PENDING_WATCHDOG_HASH}" != "absent" ]]; then
            owned_units["${SERVICE_NAME}.service"]="${SERVICE_FILE}"
            owned_unit_hashes["${SERVICE_NAME}.service"]="${SERVICE_PENDING_WATCHDOG_HASH}"
        fi
        if [[ "${SERVICE_PENDING_RETRAIN_HASH}" != "absent" ]]; then
            owned_units[cmpretrain.service]="/etc/systemd/system/cmpretrain.service"
            owned_unit_hashes[cmpretrain.service]="${SERVICE_PENDING_RETRAIN_HASH}"
        fi
    else
        validate_legacy_unit_namespace "${SERVICE_NAME}.service" "${SERVICE_FILE}" || \
            die "Reserved watchdog namespace changed after preflight"
        if [[ -e "${SERVICE_FILE}" || -L "${SERVICE_FILE}" ]]; then
            legacy_file_has_allowed_hash "${SERVICE_FILE}" LEGACY_WATCHDOG_UNIT_HASHES || \
                die "Legacy watchdog unit changed after preflight"
            owned_units["${SERVICE_NAME}.service"]="${SERVICE_FILE}"
            owned_unit_hashes["${SERVICE_NAME}.service"]="$(sha256_regular "${SERVICE_FILE}")"
        else
            cleanup_owned_unit_links "${SERVICE_NAME}.service" "${SERVICE_FILE}" \
                validate none || die "Watchdog enable-link namespace changed after preflight"
        fi
        unit=cmpretrain.service
        path="/etc/systemd/system/${unit}"
        validate_legacy_unit_namespace "${unit}" "${path}" || \
            die "Reserved retrain namespace changed after preflight: ${unit}"
        if [[ -e "${path}" || -L "${path}" ]]; then
            legacy_file_has_allowed_hash "${path}" LEGACY_RETRAIN_UNIT_HASHES || \
                die "Legacy retrain unit changed after preflight: ${path}"
            owned_units["${unit}"]="${path}"
            owned_unit_hashes["${unit}"]="$(sha256_regular "${path}")"
        else
            cleanup_owned_unit_links "${unit}" "${path}" validate none || \
                die "Retrain enable-link namespace changed after preflight: ${unit}"
        fi
        for unit in "${!owned_units[@]}"; do
            cleanup_owned_unit_links "${unit}" "${owned_units[$unit]}" validate \
                multi-user.target.wants && \
                validate_owned_or_absent "${owned_units[$unit]}" \
                    "${owned_unit_hashes[$unit]}" || \
                die "Owned unit or enable-link namespace changed before reload: ${unit}"
        done
    fi

    path="/etc/systemd/system/cmp-gen2-retrain.service"
    validate_legacy_unit_namespace cmp-gen2-retrain.service "${path}" || \
        die "Reserved legacy Gen2 retrain namespace changed after preflight"
    [[ ! -e "${path}" && ! -L "${path}" ]] || \
        die "No tracked installer grants deletion authority for legacy unit ${path}"
    cleanup_owned_unit_links cmp-gen2-retrain.service "${path}" validate none || \
        die "Legacy Gen2 retrain enable-link namespace changed after preflight"
    path="/usr/local/sbin/cmp-gen2-retrain.sh"
    if [[ -e "${path}" || -L "${path}" ]]; then
        die "No tracked installer grants deletion authority for legacy path ${path}; reconcile it manually"
    fi
    path="/usr/local/sbin/retrain.sh"
    if [[ -e "${path}" || -L "${path}" ]]; then
        if legacy_file_has_allowed_hash "${path}" LEGACY_RETRAIN_HELPER_HASHES; then
            owned_helpers["${path}"]="LEGACY_RETRAIN_HELPER_HASHES"
        elif legacy_retrain_is_project_like; then
            die "Project-like legacy retrain helper was modified; preserving it for review"
        fi
    fi

    if (( ${#owned_units[@]} > 0 )); then
        (( SERVICE_SYSTEMD_MUTATION_REQUIRED == 1 )) || \
            die "Service manager-action preflight was not completed"
        if (( SERVICE_REMOVE_PRESENT == 0 )); then
            if [[ -n "${owned_unit_hashes[${SERVICE_NAME}.service]+x}" ]]; then
                watchdog_hash="${owned_unit_hashes[${SERVICE_NAME}.service]}"
                link_path="/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
                if [[ -e "${link_path}" || -L "${link_path}" ]]; then
                    watchdog_link="$(systemd_link_target_sha256 "${link_path}")" || \
                        die "Could not bind watchdog enable link into reload intent"
                fi
            fi
            if [[ -n "${owned_unit_hashes[cmpretrain.service]+x}" ]]; then
                retrain_hash="${owned_unit_hashes[cmpretrain.service]}"
                link_path=/etc/systemd/system/multi-user.target.wants/cmpretrain.service
                if [[ -e "${link_path}" || -L "${link_path}" ]]; then
                    retrain_link="$(systemd_link_target_sha256 "${link_path}")" || \
                        die "Could not bind retrain enable link into reload intent"
                fi
            fi
            write_service_remove_pending "${watchdog_hash}" "${watchdog_link}" \
                "${retrain_hash}" "${retrain_link}"
        fi
        validate_service_remove_pending_assets || \
            die "Service reload intent changed before manager cleanup"
        validate_trusted_executable "${SYSTEMCTL_EXECUTABLE}" || \
            die "A fixed trusted systemctl is required for service cleanup"
        systemctl_sanitized daemon-reload || \
            die "systemd daemon-reload failed before service cleanup"
        for unit in "${!owned_units[@]}"; do
            path="${owned_units[$unit]}"
            expected_hash="${owned_unit_hashes[$unit]}"
            validate_owned_or_absent "${path}" "${expected_hash}" || \
                die "Receipt-owned service fragment changed before cleanup: ${unit}"
            if [[ -e "${path}" || -L "${path}" ]]; then
                validate_loaded_legacy_unit "${unit}" "${path}" || \
                    die "systemd does not bind ${unit} to the receipt-owned fragment"
            else
                validate_unloaded_legacy_unit "${unit}" || \
                    die "systemd retained removed service state before cleanup: ${unit}"
            fi
        done
    else
        (( SERVICE_SYSTEMD_MUTATION_REQUIRED == 0 && SERVICE_REMOVE_PRESENT == 0 )) || \
            die "Service manager-action scope changed after preflight"
    fi

    for unit in "${!owned_units[@]}"; do
        path="${owned_units[$unit]}"
        expected_hash="${owned_unit_hashes[$unit]}"
        if [[ -e "${path}" || -L "${path}" ]]; then
            validate_legacy_unit_namespace "${unit}" "${path}" && \
                validate_owned_or_absent "${path}" "${expected_hash}" && \
                validate_loaded_legacy_unit "${unit}" "${path}" || \
                die "Owned systemd identity changed before stopping ${unit}"
            systemctl_sanitized stop "${unit}" || die "Failed to stop owned ${unit}"
            validate_quiescent_legacy_unit "${unit}" || \
                die "Owned ${unit} did not reach an idle inactive state"
        else
            validate_unloaded_legacy_unit "${unit}" || \
                die "systemd retained a removed fragment before cleanup: ${unit}"
            if ! validate_quiescent_legacy_unit "${unit}"; then
                systemctl_sanitized stop "${unit}" || \
                    die "Failed to stop receipt-owned cached ${unit}"
                validate_quiescent_legacy_unit "${unit}" || \
                    die "Receipt-owned cached ${unit} did not become inactive"
            fi
        fi
        cleanup_owned_unit_links "${unit}" "${path}" remove \
            multi-user.target.wants || \
            die "Could not durably clear owned enable links for ${unit}"
        systemctl_sanitized reset-failed "${unit}" 2>/dev/null || true
        systemctl_sanitized is-enabled --quiet "${unit}" 2>/dev/null && \
            die "Owned ${unit} remains enabled after exact link cleanup"
        if [[ -e "${path}" || -L "${path}" ]]; then
            validate_quiescent_legacy_unit "${unit}" || \
                die "Owned ${unit} changed state before fragment cleanup"
            exact_hash=("${expected_hash}")
            validate_legacy_unit_namespace "${unit}" "${path}" && \
                durable_remove_allowed_legacy_file "${path}" exact_hash || \
                die "Could not remove exact project-owned unit ${path}"
        fi
    done
    for path in "${!owned_helpers[@]}"; do
        legacy_file_has_allowed_hash "${path}" "${owned_helpers[$path]}" && \
            durable_remove_allowed_legacy_file "${path}" "${owned_helpers[$path]}" || \
            die "Could not remove exact project-owned helper ${path}"
    done

    if (( SERVICE_SYSTEMD_MUTATION_REQUIRED == 1 )); then
        systemctl_sanitized daemon-reload || \
            die "systemd daemon-reload failed after service cleanup"
        for unit in "${!owned_units[@]}"; do
            path="${owned_units[$unit]}"
            [[ ! -e "${path}" && ! -L "${path}" ]] && \
                validate_legacy_unit_namespace "${unit}" "${path}" && \
                cleanup_owned_unit_links "${unit}" "${path}" validate none && \
                validate_unloaded_legacy_unit "${unit}" && \
                validate_quiescent_legacy_unit "${unit}" || \
                die "Service namespace or manager cache remains after cleanup: ${unit}"
        done
        durable_remove_file "${SERVICE_REMOVE_PENDING}" || \
            die "Could not commit service manager reload intent"
        SERVICE_REMOVE_PRESENT=0
    fi
}

remove_iommu_generator_outputs() {
    local target="$1" stage="$2" stage_new="$3" target_hash="$4"
    local parent_dev="$5" parent_ino="$6"
    python3 - "${target}" "${stage}" "${stage_new}" "${target_hash}" \
        "${parent_dev}" "${parent_ino}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

target, stage, stage_new = map(pathlib.Path, sys.argv[1:4])
expected_target_hash = sys.argv[4]
expected_dev, expected_ino = map(int, sys.argv[5:7])
allowed = (target in (pathlib.Path("/boot/grub/grub.cfg"),
                      pathlib.Path("/boot/grub2/grub.cfg"))
           or re.fullmatch(r"/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg",
                           os.fspath(target)) is not None)
if (not allowed or re.fullmatch(r"[a-f0-9]{64}", expected_target_hash) is None
        or min(expected_dev, expected_ino) <= 0):
    raise SystemExit("invalid boot-generator cleanup authority")
parent = target.parent
if (stage.parent != parent or stage_new.parent != parent
        or stage_new.name != stage.name + ".new"
        or re.fullmatch(rf"\.cmpunlocker-remove\.{re.escape(target.name)}\.boot\.[a-f0-9]{{6}}",
                        stage.name) is None):
    raise SystemExit("invalid boot-generator output names")

def digest(fd):
    value = hashlib.sha256(); os.lseek(fd, 0, os.SEEK_SET)
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block: break
        value.update(block)
    return value.hexdigest()

def xattrs(fd):
    return tuple((name, os.getxattr(fd, name))
                 for name in sorted(os.listxattr(fd)))

def mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount): raise SystemExit("invalid mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

mounted = mounts()
allowed_ancestor_mounts = {"/", "/boot", "/boot/efi"}
ancestor = pathlib.Path("/")
for component in parent.parts[1:]:
    ancestor /= component
    normalized = os.path.normpath(os.fspath(ancestor))
    if normalized in mounted and normalized not in allowed_ancestor_mounts:
        raise SystemExit(f"mount redirects boot-generator ancestor: {ancestor}")
for path in (target, stage, stage_new):
    if {os.path.normpath(os.fspath(path)),
        os.path.normpath(os.path.realpath(path))} & mounted:
        raise SystemExit("mount blocks boot-generator cleanup")

flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
         | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
ancestor_fds, chain = [], []
root_fd = os.open("/", flags); ancestor_fds.append(root_fd)
root_st = os.fstat(root_fd); current_fd = root_fd
for component in parent.parts[1:]:
    lst = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
    child_fd = os.open(component, flags, dir_fd=current_fd)
    fst = os.fstat(child_fd)
    if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISDIR(fst.st_mode) or fst.st_uid != 0
            or fst.st_gid != 0 or stat.S_IMODE(fst.st_mode) & 0o022):
        raise SystemExit("unsafe boot-generator ancestor")
    chain.append((current_fd, component, child_fd, fst))
    ancestor_fds.append(child_fd); current_fd = child_fd
dfd = current_fd
pst = os.fstat(dfd)
if ((pst.st_dev, pst.st_ino) != (expected_dev, expected_ino)
        or pst.st_uid != 0 or pst.st_gid != 0
        or stat.S_IMODE(pst.st_mode) & 0o022):
    raise SystemExit("boot-generator parent identity changed")

def verify_chain():
    opened_root = os.fstat(root_fd)
    if ((opened_root.st_dev, opened_root.st_ino) !=
            (root_st.st_dev, root_st.st_ino)
            or opened_root.st_uid != 0 or opened_root.st_gid != 0
            or stat.S_IMODE(opened_root.st_mode) & 0o022):
        raise SystemExit("boot root changed")
    for parent_fd, name, child_fd, expected in chain:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(child_fd)
        for observed in (current, opened):
            if ((observed.st_dev, observed.st_ino) !=
                    (expected.st_dev, expected.st_ino)
                    or not stat.S_ISDIR(observed.st_mode)
                    or observed.st_uid != expected.st_uid
                    or observed.st_gid != expected.st_gid
                    or stat.S_IMODE(observed.st_mode) !=
                       stat.S_IMODE(expected.st_mode)):
                raise SystemExit("boot-generator ancestor changed")
    if mounted != mounts(): raise SystemExit("mount topology changed")

opened = {}
try:
    verify_chain()
    target_lst = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    target_fd = os.open(target.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                        | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    target_st = os.fstat(target_fd)
    if ((target_st.st_dev, target_st.st_ino) !=
            (target_lst.st_dev, target_lst.st_ino)
            or not stat.S_ISREG(target_st.st_mode) or target_st.st_uid != 0
            or target_st.st_gid != 0 or target_st.st_nlink != 1
            or stat.S_IMODE(target_st.st_mode) & 0o022
            or target_st.st_dev != pst.st_dev
            or digest(target_fd) != expected_target_hash):
        raise SystemExit("live boot target changed before generator cleanup")
    target_attrs = xattrs(target_fd)
    for path in (stage, stage_new):
        try:
            lst = os.stat(path.name, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                     | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
        fst = os.fstat(fd)
        if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
                or not stat.S_ISREG(fst.st_mode) or fst.st_uid != 0
                or fst.st_gid != 0 or fst.st_nlink != 1
                or stat.S_IMODE(fst.st_mode) & 0o022 or fst.st_dev != pst.st_dev):
            os.close(fd); raise SystemExit("unsafe boot-generator partial output")
        opened[path.name] = (fd, fst, digest(fd), xattrs(fd))
    for path in (stage, stage_new):
        if path.name not in opened: continue
        verify_chain()
        current_target = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
        if ((current_target.st_dev, current_target.st_ino) !=
                (target_st.st_dev, target_st.st_ino)
                or digest(target_fd) != expected_target_hash
                or xattrs(target_fd) != target_attrs):
            raise SystemExit("boot target changed during generator cleanup")
        fd, expected, expected_hash, expected_attrs = opened[path.name]
        current = os.stat(path.name, dir_fd=dfd, follow_symlinks=False)
        held = os.fstat(fd)
        if ((current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino)
                or (held.st_dev, held.st_ino) != (expected.st_dev, expected.st_ino)
                or current.st_uid != held.st_uid or current.st_gid != held.st_gid
                or current.st_nlink != held.st_nlink
                or current.st_size != held.st_size
                or current.st_mtime_ns != held.st_mtime_ns
                or current.st_ctime_ns != held.st_ctime_ns
                or stat.S_IMODE(current.st_mode) != stat.S_IMODE(held.st_mode)
                or digest(fd) != expected_hash or xattrs(fd) != expected_attrs):
            raise SystemExit("boot-generator partial output changed before cleanup")
        os.unlink(path.name, dir_fd=dfd); os.fsync(dfd)
    verify_chain()
finally:
    for fd, unused_st, unused_hash, unused_attrs in opened.values(): os.close(fd)
    if 'target_fd' in locals(): os.close(target_fd)
    for fd in reversed(ancestor_fds): os.close(fd)
PY
}

publish_iommu_boot_stage() {
    local target="$1" stage="$2" old_hash="$3" candidate_hash="$4"
    local parent_dev="$5" parent_ino="$6"
    python3 - "${target}" "${stage}" "${old_hash}" "${candidate_hash}" \
        "${parent_dev}" "${parent_ino}" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

target, stage = map(pathlib.Path, sys.argv[1:3])
old_hash, candidate_hash = sys.argv[3:5]
expected_parent_dev, expected_parent_ino = map(int, sys.argv[5:7])
allowed = (target in (pathlib.Path("/boot/grub/grub.cfg"),
                      pathlib.Path("/boot/grub2/grub.cfg"))
           or re.fullmatch(r"/boot/efi/EFI/[A-Za-z0-9._+-]+/grub\.cfg",
                           os.fspath(target)) is not None)
if (not allowed
        or any(re.fullmatch(r"[a-f0-9]{64}", value) is None
               for value in (old_hash, candidate_hash))
        or min(expected_parent_dev, expected_parent_ino) <= 0):
    raise SystemExit("invalid atomic boot publication hashes")
parent = target.parent
stage_new = pathlib.Path(os.fspath(stage) + ".new")
if (stage.parent != parent or stage_new.parent != parent
        or stage_new.name != stage.name + ".new"
        or re.fullmatch(rf"\.cmpunlocker-remove\.{re.escape(target.name)}\.boot\.[a-f0-9]{{6}}",
                        stage.name) is None):
    raise SystemExit("boot publication paths have different parents")

def digest(fd):
    value = hashlib.sha256(); os.lseek(fd, 0, os.SEEK_SET)
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block: break
        value.update(block)
    return value.hexdigest()

def read_xattrs(fd):
    return tuple((name, os.getxattr(fd, name))
                 for name in sorted(os.listxattr(fd)))

def install_xattrs(fd, expected):
    wanted = dict(expected)
    for name in os.listxattr(fd):
        if name not in wanted:
            os.removexattr(fd, name)
    for name, value in expected:
        os.setxattr(fd, name, value)
    if read_xattrs(fd) != expected:
        raise SystemExit("boot stage xattrs did not round-trip")

def strict_mounts():
    result = set()
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            if not raw.endswith(b"\n") or raw.count(b" - ") != 1:
                raise SystemExit("malformed mountinfo")
            left, right = raw[:-1].split(b" - ", 1)
            fields, tail = left.split(b" "), right.split(b" ")
            if (len(fields) < 6 or len(tail) < 3
                    or any(not item for item in fields)
                    or any(not item for item in tail) or not fields[4]):
                raise SystemExit("malformed mountinfo")
            encoded, decoded, index = fields[4], bytearray(), 0
            while index < len(encoded):
                if encoded[index] != 0x5c:
                    decoded.append(encoded[index]); index += 1; continue
                if (index + 3 >= len(encoded)
                        or any(value not in b"01234567"
                               for value in encoded[index + 1:index + 4])):
                    raise SystemExit("malformed mountinfo escape")
                decoded.append(int(encoded[index + 1:index + 4], 8)); index += 4
            if not decoded or b"\x00" in decoded:
                raise SystemExit("invalid mount point")
            mount = os.path.normpath(os.fsdecode(bytes(decoded)))
            if not os.path.isabs(mount):
                raise SystemExit("non-absolute mount point")
            result.update((mount, os.path.normpath(os.path.realpath(mount))))
    return result

aliases = set()
for path in (target, stage, stage_new):
    aliases.update((os.path.normpath(os.fspath(path)),
                    os.path.normpath(os.path.realpath(path))))
mounted = strict_mounts()
allowed_ancestor_mounts = {"/", "/boot", "/boot/efi"}
ancestor_path = pathlib.Path("/")
for component in parent.parts[1:]:
    ancestor_path /= component
    normalized = os.path.normpath(os.fspath(ancestor_path))
    if normalized in mounted and normalized not in allowed_ancestor_mounts:
        raise SystemExit(f"mount redirects boot publication ancestor: {ancestor_path}")
if aliases & mounted:
    raise SystemExit("mount blocks atomic boot publication")

dir_flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
             | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
ancestor_fds = []
chain = []
root_fd = os.open("/", dir_flags)
ancestor_fds.append(root_fd)
root_st = os.fstat(root_fd)
current_fd = root_fd
for component in parent.parts[1:]:
    lst = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
    child_fd = os.open(component, dir_flags, dir_fd=current_fd)
    fst = os.fstat(child_fd)
    if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
            or not stat.S_ISDIR(fst.st_mode) or fst.st_uid != 0
            or fst.st_gid != 0 or stat.S_IMODE(fst.st_mode) & 0o022):
        raise SystemExit(f"unsafe boot ancestor: {component}")
    chain.append((current_fd, component, child_fd, fst))
    ancestor_fds.append(child_fd); current_fd = child_fd
dfd = current_fd
pst = os.fstat(dfd)
if ((pst.st_dev, pst.st_ino) != (expected_parent_dev, expected_parent_ino)
        or pst.st_uid != 0 or pst.st_gid != 0
        or stat.S_IMODE(pst.st_mode) & 0o022):
    raise SystemExit("boot publication parent identity changed")

def verify_chain():
    opened_root = os.fstat(root_fd)
    if ((opened_root.st_dev, opened_root.st_ino) !=
            (root_st.st_dev, root_st.st_ino)
            or not stat.S_ISDIR(opened_root.st_mode) or opened_root.st_uid != 0
            or opened_root.st_gid != 0 or stat.S_IMODE(opened_root.st_mode) & 0o022):
        raise SystemExit("boot root identity changed")
    for parent_fd, name, child_fd, expected in chain:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(child_fd)
        if ((current.st_dev, current.st_ino) !=
                (expected.st_dev, expected.st_ino)
                or (opened.st_dev, opened.st_ino) !=
                   (expected.st_dev, expected.st_ino)
                or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != 0
                or opened.st_gid != 0 or stat.S_IMODE(opened.st_mode) & 0o022):
            raise SystemExit("boot ancestor identity changed")

def require_new_absent():
    try:
        os.stat(stage_new.name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise SystemExit("implicit boot generator temp exists during publication")

tfd = sfd = -1
try:
    verify_chain()
    require_new_absent()
    opened_parent = os.fstat(dfd)
    if ((opened_parent.st_dev, opened_parent.st_ino) !=
            (expected_parent_dev, expected_parent_ino)
            or opened_parent.st_uid != 0 or opened_parent.st_gid != 0
            or stat.S_IMODE(opened_parent.st_mode) & 0o022):
        raise SystemExit("boot publication parent changed while opening")
    target_lst = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    tfd = os.open(target.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                  | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    tst = os.fstat(tfd)
    if ((tst.st_dev, tst.st_ino) != (target_lst.st_dev, target_lst.st_ino)
            or not stat.S_ISREG(tst.st_mode) or tst.st_uid != 0 or tst.st_gid != 0
            or tst.st_nlink != 1 or stat.S_IMODE(tst.st_mode) & 0o022
            or tst.st_dev != pst.st_dev):
        raise SystemExit("unsafe live boot target")
    current_hash = digest(tfd)
    target_xattrs = read_xattrs(tfd)
    if current_hash == candidate_hash:
        os.fsync(tfd)
        verify_chain()
        current_target = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
        if ((current_target.st_dev, current_target.st_ino) !=
                (tst.st_dev, tst.st_ino) or digest(tfd) != candidate_hash
                or read_xattrs(tfd) != target_xattrs
                or mounted != strict_mounts()):
            raise SystemExit("published boot target changed before stage cleanup")
        try:
            stage_lst = os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
            sfd = os.open(stage.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                          | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
        except FileNotFoundError:
            sfd = -1
        if sfd >= 0:
            sst = os.fstat(sfd)
            if ((sst.st_dev, sst.st_ino) != (stage_lst.st_dev, stage_lst.st_ino)
                    or not stat.S_ISREG(sst.st_mode) or sst.st_uid != 0
                    or sst.st_gid != 0
                    or sst.st_nlink != 1 or sst.st_dev != tst.st_dev
                    or stat.S_IMODE(sst.st_mode) & 0o022
                    or digest(sfd) != candidate_hash):
                raise SystemExit("unrelated boot stage exists beside published candidate")
            current_stage = os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
            if ((current_stage.st_dev, current_stage.st_ino) !=
                    (sst.st_dev, sst.st_ino)):
                raise SystemExit("boot stage changed before committed cleanup")
            verify_chain()
            require_new_absent()
            if mounted != strict_mounts():
                raise SystemExit("mount namespace changed before boot-stage cleanup")
            os.unlink(stage.name, dir_fd=dfd)
        else:
            try:
                os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise SystemExit("boot stage appeared before committed cleanup")
        os.fsync(dfd)
        verify_chain()
        if mounted != strict_mounts():
            raise SystemExit("mount namespace changed during committed cleanup")
        raise SystemExit(0)
    if current_hash != old_hash:
        raise SystemExit("live boot target changed before atomic publication")
    stage_lst = os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
    sfd = os.open(stage.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                  | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    sst = os.fstat(sfd)
    if ((sst.st_dev, sst.st_ino) != (stage_lst.st_dev, stage_lst.st_ino)
            or not stat.S_ISREG(sst.st_mode) or sst.st_uid != 0 or sst.st_gid != 0
            or sst.st_nlink != 1 or sst.st_dev != tst.st_dev
            or stat.S_IMODE(sst.st_mode) & 0o022
            or digest(sfd) != candidate_hash):
        raise SystemExit("boot stage changed before atomic publication")
    os.fchown(sfd, tst.st_uid, tst.st_gid)
    os.fchmod(sfd, stat.S_IMODE(tst.st_mode))
    install_xattrs(sfd, target_xattrs)
    os.fsync(sfd)
    verify_chain()
    require_new_absent()
    current = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    stage_current = os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
    if ((current.st_dev, current.st_ino) != (tst.st_dev, tst.st_ino)
            or current.st_uid != tst.st_uid or current.st_gid != tst.st_gid
            or stat.S_IMODE(current.st_mode) != stat.S_IMODE(tst.st_mode)
            or digest(tfd) != old_hash or read_xattrs(tfd) != target_xattrs
            or (stage_current.st_dev, stage_current.st_ino) !=
               (sst.st_dev, sst.st_ino)
            or stage_current.st_uid != tst.st_uid
            or stage_current.st_gid != tst.st_gid
            or stat.S_IMODE(stage_current.st_mode) != stat.S_IMODE(tst.st_mode)
            or digest(sfd) != candidate_hash
            or read_xattrs(sfd) != target_xattrs
            or mounted != strict_mounts()):
        raise SystemExit("boot target changed before replace")
    os.replace(stage.name, target.name, src_dir_fd=dfd, dst_dir_fd=dfd)
    published_lst = os.stat(target.name, dir_fd=dfd, follow_symlinks=False)
    newfd = os.open(target.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0), dir_fd=dfd)
    try:
        nst = os.fstat(newfd)
        if ((nst.st_dev, nst.st_ino) != (published_lst.st_dev, published_lst.st_ino)
                or not stat.S_ISREG(nst.st_mode) or nst.st_uid != tst.st_uid
                or nst.st_gid != tst.st_gid or nst.st_nlink != 1
                or stat.S_IMODE(nst.st_mode) != stat.S_IMODE(tst.st_mode)
                or digest(newfd) != candidate_hash
                or read_xattrs(newfd) != target_xattrs):
            raise SystemExit("atomic boot publication metadata or hash mismatch")
        os.fsync(newfd)
    finally:
        os.close(newfd)
    os.fsync(dfd)
    verify_chain()
    require_new_absent()
    try:
        os.stat(stage.name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise SystemExit("boot stage remained after atomic publication")
    if mounted != strict_mounts():
        raise SystemExit("mount namespace changed during atomic boot publication")
finally:
    if sfd >= 0: os.close(sfd)
    if tfd >= 0: os.close(tfd)
    for ancestor_fd in reversed(ancestor_fds):
        os.close(ancestor_fd)
PY
}

run_persisted_boot_generator() {
    local source_hash stage_hash

    [[ "${IOMMU_GENERATOR}" != "kernel-install" ]] || return 1
    select_fixed_grub_generator "${IOMMU_GENERATOR}" || return 1
    parse_iommu_remove_pending || return 1
    [[ "${IOMMU_PENDING_FORMAT}" == "5" && \
       "${IOMMU_BOOT_TARGET}" == "${IOMMU_TARGET}" && \
       "${IOMMU_BOOT_STAGE_NEW}" == "${IOMMU_BOOT_STAGE}.new" ]] || return 1

    if [[ "${IOMMU_PENDING_PHASE}" == "restoring" ]]; then
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" optional optional || return 1
        [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
           "${IOMMU_BOOT_TARGET_HASH}" ]] || return 1
        if [[ "${IOMMU_BOOT_GENERATOR_ATTEMPTED}" == "0" ]]; then
            [[ "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == "absent" && \
               "${IOMMU_BOOT_NAMESPACE_NEW_HASH}" == "absent" ]] || return 1
            inspect_iommu_source_namespace "${IOMMU_SOURCE}" || return 1
            [[ "${IOMMU_SOURCE_NAMESPACE_HASH}" == "${IOMMU_BASE_HASH}" && \
               "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" == \
                 "${IOMMU_SOURCE_PARENT_DEV}" && \
               "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" == \
                 "${IOMMU_SOURCE_PARENT_INO}" ]] || return 1
            IOMMU_BOOT_GENERATOR_ATTEMPTED=1
            write_iommu_remove_pending restoring || return 1
        else
            remove_iommu_generator_outputs "${IOMMU_BOOT_TARGET}" \
                "${IOMMU_BOOT_STAGE}" "${IOMMU_BOOT_STAGE_NEW}" \
                "${IOMMU_BOOT_TARGET_HASH}" "${IOMMU_BOOT_PARENT_DEV}" \
                "${IOMMU_BOOT_PARENT_INO}" || return 1
        fi
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" absent absent || return 1
        [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
           "${IOMMU_BOOT_TARGET_HASH}" ]] || return 1
        grub_generator_sanitized "${IOMMU_BOOT_STAGE}" || return 1
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" present absent || return 1
        [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
           "${IOMMU_BOOT_TARGET_HASH}" ]] || return 1
        grub_script_check_sanitized "${IOMMU_BOOT_STAGE}" || return 1
        stage_hash="${IOMMU_BOOT_NAMESPACE_STAGE_HASH}"
        # The fixed generator consumes the exact receipt base while it is live.
        # Other trusted GRUB inputs may legitimately contribute their own IOMMU
        # tokens, so a single /etc/default/grub snapshot cannot authorize a
        # content-level token ban on the complete generated script.
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" present || return 1
        [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
           "${IOMMU_BOOT_TARGET_HASH}" && \
           "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == "${stage_hash}" ]] || return 1
        inspect_iommu_source_namespace "${IOMMU_SOURCE}" || return 1
        source_hash="${IOMMU_SOURCE_NAMESPACE_HASH}"
        [[ "${source_hash}" == "${IOMMU_BASE_HASH}" && \
           "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" == \
             "${IOMMU_SOURCE_PARENT_DEV}" && \
           "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" == \
             "${IOMMU_SOURCE_PARENT_INO}" ]] || return 1
        sync -f "${IOMMU_BOOT_STAGE}" || return 1
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" present || return 1
        [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
           "${IOMMU_BOOT_TARGET_HASH}" && \
           "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == "${stage_hash}" ]] || return 1
        IOMMU_BOOT_CANDIDATE_HASH="${stage_hash}"
        write_iommu_remove_pending candidate-ready || return 1
    fi

    parse_iommu_remove_pending || return 1
    if [[ "${IOMMU_PENDING_PHASE}" == "candidate-ready" ]]; then
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" optional || return 1
        if [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
              "${IOMMU_BOOT_TARGET_HASH}" && \
              "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == \
              "${IOMMU_BOOT_CANDIDATE_HASH}" ]]; then
            grub_script_check_sanitized "${IOMMU_BOOT_STAGE}" || return 1
        elif [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
                "${IOMMU_BOOT_CANDIDATE_HASH}" ]]; then
            [[ "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == "absent" || \
               "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" == \
                 "${IOMMU_BOOT_CANDIDATE_HASH}" ]] || return 1
            if [[ "${IOMMU_BOOT_NAMESPACE_STAGE_HASH}" != "absent" ]]; then
                grub_script_check_sanitized "${IOMMU_BOOT_STAGE}" || return 1
            fi
        else
            return 1
        fi
        inspect_iommu_source_namespace "${IOMMU_SOURCE}" || return 1
        source_hash="${IOMMU_SOURCE_NAMESPACE_HASH}"
        [[ "${source_hash}" == "${IOMMU_BASE_HASH}" && \
           "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" == \
             "${IOMMU_SOURCE_PARENT_DEV}" && \
           "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" == \
             "${IOMMU_SOURCE_PARENT_INO}" ]] || return 1
        publish_iommu_boot_stage "${IOMMU_BOOT_TARGET}" "${IOMMU_BOOT_STAGE}" \
            "${IOMMU_BOOT_TARGET_HASH}" "${IOMMU_BOOT_CANDIDATE_HASH}" \
            "${IOMMU_BOOT_PARENT_DEV}" "${IOMMU_BOOT_PARENT_INO}" || return 1
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" absent || return 1
        [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
           "${IOMMU_BOOT_CANDIDATE_HASH}" ]] || return 1
        write_iommu_remove_pending boot-refreshed || return 1
    fi

    parse_iommu_remove_pending || return 1
    [[ "${IOMMU_PENDING_PHASE}" == "boot-refreshed" ]] || return 1
    inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
        "${IOMMU_BOOT_STAGE}" absent || return 1
    [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
       "${IOMMU_BOOT_CANDIDATE_HASH}" ]]
}

prepare_iommu_source_restoration() {
    local current_hash state_authority pending_authority nonce

    [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]] || return 0
    parse_iommu_state || die "IOMMU receipt or snapshots changed after preflight"
    [[ "${IOMMU_GENERATOR}" != "kernel-install" ]] || \
        die "kernel-install output cannot be atomically journaled; restore ${IOMMU_SOURCE} manually"
    select_fixed_grub_generator "${IOMMU_GENERATOR}" || \
        die "Persisted GRUB generator lacks a fixed trusted staging pipeline"
    inspect_iommu_source_namespace "${IOMMU_SOURCE}" || \
        die "Unsafe literal IOMMU source namespace after preflight"
    current_hash="${IOMMU_SOURCE_NAMESPACE_HASH}"
    [[ "${current_hash}" == "${IOMMU_BASE_HASH}" || \
       "${current_hash}" == "${IOMMU_EXPECTED_HASH}" ]] || \
        die "IOMMU source changed after preflight; preserving it"
    state_authority="${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}"
    if [[ -e "${IOMMU_REMOVE_PENDING}" || -L "${IOMMU_REMOVE_PENDING}" ]]; then
        parse_iommu_remove_pending || die "Invalid IOMMU restoration marker"
        pending_authority="${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}"
        [[ "${pending_authority}" == "${state_authority}" ]] || \
            die "IOMMU marker and receipt grant different cleanup authority"
    fi
    if [[ "${IOMMU_BOOT_TARGET}" == "absent" ]]; then
        nonce="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(3))
PY
)"
        [[ "${nonce}" =~ ^[a-f0-9]{6}$ ]] || die "Could not create boot-stage nonce"
        IOMMU_BOOT_TARGET="${IOMMU_TARGET}"
        IOMMU_BOOT_STAGE="$(dirname -- "${IOMMU_TARGET}")/.cmpunlocker-remove.$(basename -- "${IOMMU_TARGET}").boot.${nonce}"
        IOMMU_BOOT_STAGE_NEW="${IOMMU_BOOT_STAGE}.new"
        IOMMU_BOOT_GENERATOR_ATTEMPTED=0
        inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
            "${IOMMU_BOOT_STAGE}" absent absent || \
            die "Unsafe persisted boot target or stage namespace"
        IOMMU_BOOT_TARGET_HASH="${IOMMU_BOOT_NAMESPACE_TARGET_HASH}"
        IOMMU_BOOT_CANDIDATE_HASH=absent
        IOMMU_BOOT_PARENT_DEV="${IOMMU_BOOT_NAMESPACE_PARENT_DEV}"
        IOMMU_BOOT_PARENT_INO="${IOMMU_BOOT_NAMESPACE_PARENT_INO}"
        IOMMU_SOURCE_PARENT_DEV="${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}"
        IOMMU_SOURCE_PARENT_INO="${IOMMU_SOURCE_NAMESPACE_PARENT_INO}"
        write_iommu_remove_pending restoring || \
            die "Could not durably begin IOMMU restoration"
    else
        [[ "${IOMMU_BOOT_TARGET}" == "${IOMMU_TARGET}" ]] || \
            die "IOMMU marker targets a different boot output"
        if [[ "${IOMMU_PENDING_FORMAT}" == "4" ]]; then
            [[ "${IOMMU_PENDING_PHASE}" == "restoring" ]] || \
                die "Legacy IOMMU marker cannot prove whether its generator ran"
            inspect_iommu_boot_namespace "${IOMMU_BOOT_TARGET}" \
                "${IOMMU_BOOT_STAGE}" absent absent || \
                die "Legacy IOMMU marker has ambiguous stage or implicit .new residue"
            [[ "${IOMMU_BOOT_NAMESPACE_TARGET_HASH}" == \
               "${IOMMU_BOOT_TARGET_HASH}" ]] || \
                die "Legacy IOMMU marker boot target changed before safe upgrade"
            IOMMU_BOOT_STAGE_NEW="${IOMMU_BOOT_STAGE}.new"
            IOMMU_BOOT_GENERATOR_ATTEMPTED=0
            IOMMU_SOURCE_PARENT_DEV="${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}"
            IOMMU_SOURCE_PARENT_INO="${IOMMU_SOURCE_NAMESPACE_PARENT_INO}"
            write_iommu_remove_pending restoring || \
                die "Could not durably upgrade legacy IOMMU restoration authority"
            parse_iommu_remove_pending || \
                die "Upgraded IOMMU restoration marker did not validate"
        elif [[ "${IOMMU_PENDING_FORMAT}" == "5" ]]; then
            [[ "${IOMMU_SOURCE_PARENT_DEV}" == \
                 "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" && \
               "${IOMMU_SOURCE_PARENT_INO}" == \
                 "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" ]] || \
                die "IOMMU literal source parent changed after journaling"
        else
            die "Persisted IOMMU boot transaction lacks exact S/S.new authority"
        fi
    fi
    atomic_restore_iommu_source "${IOMMU_BASE}" "${IOMMU_SOURCE}" \
        "${IOMMU_EXPECTED_HASH}" "${IOMMU_BASE_HASH}" \
        "${IOMMU_SOURCE_PARENT_DEV}" "${IOMMU_SOURCE_PARENT_INO}" || \
        die "Atomic IOMMU source restoration failed"
    if [[ "${current_hash}" == "${IOMMU_EXPECTED_HASH}" ]]; then
        ok "Atomically restored ${IOMMU_SOURCE} from its exact pre-install snapshot"
    else
        info "${IOMMU_SOURCE} is already at the receipt base"
    fi
}

finish_iommu_boot_restoration() {
    local current_hash path state_authority

    [[ -e "${IOMMU_STATE}" || -L "${IOMMU_STATE}" ]] || return 0
    parse_iommu_state || die "IOMMU receipt or snapshots changed before boot publication"
    inspect_iommu_source_namespace "${IOMMU_SOURCE}" || \
        die "Unsafe literal IOMMU source namespace before boot publication"
    current_hash="${IOMMU_SOURCE_NAMESPACE_HASH}"
    [[ "${current_hash}" == "${IOMMU_BASE_HASH}" ]] || \
        die "IOMMU source changed before clean boot publication; preserving its receipt"
    state_authority="${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}"
    parse_iommu_remove_pending || \
        die "Missing or invalid IOMMU restoration intent"
    [[ "${IOMMU_PENDING_FORMAT}" == "5" && \
       "${IOMMU_PENDING_PHASE}" =~ ^(restoring|candidate-ready|boot-refreshed)$ && \
       "${IOMMU_SOURCE_PARENT_DEV}" == \
         "${IOMMU_SOURCE_NAMESPACE_PARENT_DEV}" && \
       "${IOMMU_SOURCE_PARENT_INO}" == \
         "${IOMMU_SOURCE_NAMESPACE_PARENT_INO}" && \
       "${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" == \
       "${state_authority}" ]] || \
        die "IOMMU restoration intent is not ready for boot publication"
    run_persisted_boot_generator || \
        die "Persisted ${IOMMU_GENERATOR} regeneration failed; IOMMU receipt retained"
    parse_iommu_remove_pending && \
        [[ "${IOMMU_PENDING_PHASE}" == "boot-refreshed" && \
           "${IOMMU_LEGACY_GRUB_BACKUP_HASH}:${IOMMU_LEGACY_GRUB_PENDING_HASH}:${IOMMU_LEGACY_CMDLINE_BACKUP_HASH}:${IOMMU_LEGACY_CMDLINE_PENDING_HASH}" == \
           "${state_authority}" ]] || \
        die "IOMMU boot publication did not reach its committed phase"
    for path in "${IOMMU_STATE}" "${IOMMU_BASE}" "${IOMMU_EXPECTED}"; do
        durable_remove_file "${path}" || die "Could not clean committed IOMMU state ${path}"
    done
    remove_legacy_iommu_files || die "Could not remove legacy IOMMU recovery files"
    durable_remove_file "${IOMMU_REMOVE_PENDING}" || die "Could not finalize IOMMU cleanup"
    ok "Restored the receipt-bound IOMMU command line using the persisted boot target"
}

commit_dkms_receipts() {
    local state_path receipt parse_rc
    local phase kernel version patched_src patched_hashes backup
    local dkms_prestate dkms_attempted dkms_arch dkms_install_attempted dkms_built_hashes
    local dkms_preinstall_manifest firmware_prestate firmware_attempted receipt_committed
    local firmware_stock_hash firmware_patched_hash stock_hashes
    local -A seen=()

    for state_path in "${CLEANUP_STATE_PATHS[@]}"; do
        parse_remove_state "${state_path}" || die "Invalid removal state while committing ${state_path}"
        [[ "${REMOVE_PHASE}" == "stock-ready" ]] || \
            die "Refusing DKMS receipt commit from non-stock state ${state_path}"
        phase="${REMOVE_PHASE}"
        kernel="${REMOVE_KERNEL}"
        version="${REMOVE_VERSION}"
        patched_src="${REMOVE_PATCHED_SRC}"
        patched_hashes="${REMOVE_PATCHED_HASHES}"
        backup="${REMOVE_BACKUP}"
        dkms_prestate="${REMOVE_DKMS_PRESTATE}"
        dkms_attempted="${REMOVE_DKMS_ATTEMPTED}"
        dkms_arch="${REMOVE_DKMS_ARCH}"
        dkms_install_attempted="${REMOVE_DKMS_INSTALL_ATTEMPTED}"
        dkms_built_hashes="${REMOVE_DKMS_BUILT_HASHES}"
        dkms_preinstall_manifest="${REMOVE_DKMS_PREINSTALL_MANIFEST}"
        firmware_prestate="${REMOVE_FIRMWARE_PRESTATE}"
        firmware_attempted="${REMOVE_FIRMWARE_ATTEMPTED}"
        firmware_stock_hash="${REMOVE_FIRMWARE_STOCK_HASH}"
        firmware_patched_hash="${REMOVE_FIRMWARE_PATCHED_HASH}"
        stock_hashes="${REMOVE_STOCK_HASHES}"
        receipt_committed="${REMOVE_DKMS_RECEIPT_COMMITTED}"
        [[ -z "${seen[${kernel}]+x}" ]] || continue
        seen["${kernel}"]=1
        receipt="${STATE_DIR}/dkms-removed.${kernel}.receipt"

        if [[ "${receipt_committed}" == "0" ]]; then
            ensure_stock_dkms_state "${kernel}" "${version}" \
                "${dkms_prestate}" "${dkms_attempted}" "0" "${dkms_arch}"
            # This marker is published before the receipt unlink.  Therefore
            # either side of a crash can be distinguished without discarding
            # the proof that an exact tuple was installed.
            write_remove_state "${phase}" "${kernel}" "${version}" \
                "${patched_src}" "${patched_hashes}" "${backup}" \
                "${dkms_prestate}" "${dkms_attempted}" "${firmware_prestate}" \
                "${firmware_attempted}" "${firmware_stock_hash}" \
                "${firmware_patched_hash}" "1" "${stock_hashes}" \
                "${dkms_install_attempted}" "${dkms_built_hashes}" \
                "${dkms_preinstall_manifest}" "${dkms_arch}"
            receipt_committed=1
        fi

        if parse_dkms_receipt "${kernel}" "${version}"; then
            [[ "${DKMS_ARCH}" == "${dkms_arch}" ]] || \
                die "DKMS receipt architecture changed before commit for ${kernel}"
            ensure_dkms_tool
            query_dkms_tuple "${DKMS_VERSION}" "${DKMS_KERNEL}" "${DKMS_ARCH}" && \
                [[ "${DKMS_TUPLE_STATE}" == "installed" ]] || \
                die "Refusing to discard DKMS receipt before its exact tuple is installed"
            receipt="${DKMS_PATH}"
            durable_remove_file "${receipt}" || die "Could not commit DKMS receipt cleanup"
        else
            parse_rc=$?
            (( parse_rc == 2 )) || die "Invalid DKMS receipt while committing ${kernel}"
            [[ "${receipt_committed}" == "1" ]] || \
                die "DKMS receipt disappeared before its commit marker for ${kernel}"
        fi
    done
}

commit_remove_states() {
    local path
    local -A seen=()
    for path in "${CLEANUP_STATE_PATHS[@]}"; do
        [[ -z "${seen[${path}]+x}" ]] || continue
        seen["${path}"]=1
        durable_remove_file "${path}" || die "Could not commit removal state cleanup ${path}"
    done
}

refresh_clean_stock_boot_artifacts() {
    local i

    ensure_recovery_tools
    for i in "${!KERNELS[@]}"; do
        depmod -a "${KERNELS[$i]}" || \
            die "Final depmod failed for ${KERNELS[$i]} after configuration cleanup"
        verify_stock_module_set "${KERNELS[$i]}" "${EXPECTED_VERSIONS[$i]}" \
            "${PATCHED_CORE_SRCS[$i]}" "${PATCHED_HASH_SETS[$i]}" \
            "${STOCK_HASH_SETS[$i]}" || \
            die "Final stock module proof failed for ${KERNELS[$i]}"
        rebuild_kernel_initramfs "${KERNELS[$i]}" || \
            die "Final clean initramfs rebuild failed for ${KERNELS[$i]}"
    done
    for i in "${!RESUME_KERNELS[@]}"; do
        depmod -a "${RESUME_KERNELS[$i]}" || \
            die "Final depmod failed for ${RESUME_KERNELS[$i]} after configuration cleanup"
        verify_stock_module_set "${RESUME_KERNELS[$i]}" "${RESUME_VERSIONS[$i]}" \
            "${RESUME_PATCHED_SRCS[$i]}" "${RESUME_PATCHED_HASH_SETS[$i]}" \
            "${RESUME_STOCK_HASH_SETS[$i]}" || \
            die "Final stock module proof failed for ${RESUME_KERNELS[$i]}"
        rebuild_kernel_initramfs "${RESUME_KERNELS[$i]}" || \
            die "Final clean initramfs rebuild failed for ${RESUME_KERNELS[$i]}"
    done
    sync || die "Could not persist final clean stock boot artifacts"
}

cleanup_legacy_install_dir() {
    [[ -e "${INSTALL_DIR}" || -L "${INSTALL_DIR}" ]] || return 0
    python3 - "${INSTALL_DIR}" <<'PY'
import os
import pathlib
import re
import stat
import sys

path = pathlib.Path(sys.argv[1])
if path != pathlib.Path("/opt/cmpunlocker"):
    raise SystemExit("unexpected legacy install path")
parent = path.parent.resolve(strict=True)
resolved = path.resolve(strict=True)
if resolved != path or resolved.parent != parent:
    raise SystemExit("symlinked legacy install directory")
pst = os.lstat(parent)
st = os.lstat(resolved)
if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != 0 or pst.st_gid != 0 or stat.S_IMODE(pst.st_mode) & 0o022
        or not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != 0 or st.st_gid != 0 or stat.S_IMODE(st.st_mode) & 0o022
        or st.st_dev != pst.st_dev):
    raise SystemExit("unsafe legacy install directory")

def reject_mounts():
    exact = os.path.normpath(os.fspath(resolved))
    prefix = exact + os.sep
    with open("/proc/self/mountinfo", "rb") as stream:
        for raw in stream:
            fields = raw.rstrip(b"\n").split(b" ")
            if len(fields) < 5:
                raise SystemExit("malformed mountinfo")
            decoded = re.sub(rb"\\([0-7]{3})",
                             lambda match: bytes((int(match.group(1), 8),)),
                             fields[4])
            mount = os.path.normpath(os.fsdecode(decoded))
            if mount == exact or mount.startswith(prefix):
                raise SystemExit(f"mount blocks legacy install cleanup: {mount}")

reject_mounts()
entries = list(os.scandir(resolved))
if entries:
    # Historical installers copied their entire source checkout, including
    # mutable logs and possibly user-added files, without a durable manifest.
    # No leaf in a nonempty legacy directory is therefore deletion-authorized.
    raise SystemExit(
        f"nonempty unreceipted legacy install directory requires manual reconciliation: {entries[0].path}"
    )
reject_mounts()
os.rmdir(resolved)
dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
              | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
PY
}

step "Removing receipt-owned services and restoring boot configuration"
if (( STOCK_READY == 1 )); then
    cleanup_namespaced_services
    cleanup_gen2_owned
    prepare_iommu_source_restoration
    cleanup_firmware_sidecars
    cleanup_legacy_install_dir || \
        die "Legacy ${INSTALL_DIR} has no exact deletion manifest; preserving it"
    commit_dkms_receipts
    # Gen2/IOMMU cleanup changes boot inputs, and DKMS receipt reconciliation
    # can change the selected stock module tree.  Rebuild every affected image
    # only after both are final, while stock-ready receipts still make failure
    # retryable.
    refresh_clean_stock_boot_artifacts
    # kernel-install and similar generators must publish only after the exact
    # clean initramfs has been rebuilt; otherwise an old Gen2 configuration can
    # be copied into a UKI or loader entry.
    finish_iommu_boot_restoration
    commit_remove_states
    ok "Committed service, firmware, DKMS, and boot-configuration cleanup"
else
    info "No proven stock transition; no configuration was changed"
fi

step "Verifying final state and deferring activation"
collect_cmp_residuals
if (( ${#RESIDUALS[@]} > 0 )); then
    err "Removal did not reach a residue-free committed state:"
    printf '  %s\n' "${RESIDUALS[@]}" >&2
    die "Residual cmpunlocker state remains; no success claim is made"
fi

if lsmod | awk '$1 ~ /^nvidia/ {found=1} END {exit !found}'; then
    warn "The patched NVIDIA driver may remain loaded in memory until power-off"
else
    info "No NVIDIA modules are currently loaded"
fi
if (( STOCK_READY == 1 )); then
    ok "Verified stock modules and boot artifacts are ready on disk"
else
    info "Idempotent removal verified: no cmpunlocker residual was found"
fi

step "Done"
banner
echo "cmpunlocker has been removed from the on-disk boot path."
echo "Log saved to: ${LOG_FILE}"
echo ""
if (( STOCK_READY == 1 )); then
    echo "A complete power cycle is required; a module reload or warm reboot is not sufficient:"
    echo -e "  ${CYAN}sudo shutdown -h now${NC}"
    echo "Then power the machine on."
else
    echo "No new module transition was performed."
fi
echo ""
