#!/bin/bash
set -euo pipefail

# Normalize a root invocation's real/effective group before the first write.
# This covers sudo -g without leaving mkdir/O_EXCL/mktemp/redirect objects in
# a permanently rejected root:nonroot hard-cut state.  The decision uses the
# actual process credentials, never a forgeable environment marker.
if [[ "${EUID}" -eq 0 && "$(id -g)" != "0" ]]; then
    command -v python3 &>/dev/null || {
        echo "[FAIL]  python3 is required to normalize root credentials" >&2
        exit 1
    }
    exec python3 - "$0" "$@" <<'PY'
import os
import sys

script = sys.argv[1]
args = sys.argv[2:]
if os.geteuid() != 0 or os.getegid() == 0:
    raise SystemExit("unexpected credential-normalization state")
os.setgid(0)
if os.getgid() != 0 or os.getegid() != 0:
    raise SystemExit("could not normalize root group credentials")
os.execve("/bin/bash", ["bash", script, *args], os.environ)
PY
fi

# Every transaction inode must be born with a recoverable private mode even
# when the caller supplied a hostile umask.  Public installed payloads and
# metadata receive their explicit final modes below.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/VERSION")
DEFAULT_VERSION="${SUPPORTED_VERSIONS[0]:-}"
VERSION="${CMPUNLOCKER_DRIVER_VERSION:-${DEFAULT_VERSION}}"
PATCH_DIR="${SCRIPT_DIR}/patches"
BUILD_ROOT="${CMPUNLOCKER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
SRC_NAME="open-gpu-kernel-modules-${VERSION}"
SRC_DIR="${BUILD_ROOT}/${SRC_NAME}"
TARBALL="${BUILD_ROOT}/${SRC_NAME}.tar.gz"
TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VERSION}.tar.gz"
KVER="$(uname -r)"
KSRC="/lib/modules/${KVER}/build"
INSTALL_PARENT="/lib/modules/${KVER}/updates"
INSTALL_MOD_DIR="${INSTALL_PARENT}/cmpunlocker"
TARGET_MODULES=(
    nvidia.ko
    nvidia-modeset.ko
    nvidia-uvm.ko
    nvidia-drm.ko
    nvidia-peermem.ko
)
MODULE_NAMES=(nvidia nvidia-modeset nvidia-uvm nvidia-drm nvidia-peermem)

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
die()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ${SCRIPT_DIR}/build.sh"
command -v python3 &>/dev/null || die "python3 is required to apply the card memory profile"
command -v modinfo &>/dev/null || die "modinfo is required to validate built modules"
command -v depmod &>/dev/null || die "depmod is required to install built modules"
command -v readlink &>/dev/null || die "readlink is required to verify module resolution"
command -v flock &>/dev/null || die "flock is required for the module installation transaction"
command -v sync &>/dev/null || die "sync is required for durable module transactions"
command -v stat &>/dev/null || die "stat is required to verify transaction filesystem identity"
command -v cmp &>/dev/null || die "cmp is required to verify committed transaction metadata"

prepare_sources() {
[[ -n "${VERSION}" ]] || die "No driver version set (driver/VERSION empty and CMPUNLOCKER_DRIVER_VERSION unset)"
version_supported "${VERSION}" || die "Unsupported driver version '${VERSION}' (supported: ${SUPPORTED_VERSIONS[*]})"
[[ -d "${PATCH_DIR}" ]] || die "Missing patches directory: ${PATCH_DIR}"
[[ -d "${KSRC}" ]] || die "Kernel headers not found at ${KSRC}. Install linux-headers-${KVER} (or kernel-devel)."
command -v sha256sum &>/dev/null || die "sha256sum is required"
command -v grep &>/dev/null || die "grep is required to verify module provenance"
info "Building against open-gpu-kernel-modules ${VERSION}"

PATCH_ORDER=(
    sec2-postbl-plm-ss-cfg.patch
    booter-verify.patch
    late-pma.patch
    bar0-pramin-clamp.patch
    ce-scrub-workarounds.patch
    persistent-sw-state.patch
    pcie-gen2.patch
    pcie-gen2-probe-retrain.patch
    name-string.patch
    sec2-payload-safety.patch
)
PATCH_FILES=()
for name in "${PATCH_ORDER[@]}"; do
    p="${PATCH_DIR}/${name}"
    [[ -f "${p}" ]] || die "Missing patch: ${p}"
    PATCH_FILES+=("${p}")
done
PATCH_HASH="$(cat "${PATCH_FILES[@]}" | sha256sum | cut -d' ' -f1)"

PROFILE="${CMPUNLOCKER_CARD_PROFILE:-8gb}"
SKIP_GEOMETRY_REWRITE=0
case "${PROFILE}" in
    8gb|8GB)
        PROFILE="8gb"
        CFG1="0x02779000"
        LMR="0x0000020B"
        FB_BYTES="0x0000001000000000"
        UNLOCK_LABEL="64GB"
        ;;
    10gb|10GB)
        PROFILE="10gb"
        CFG1="0x02669000"
        LMR="0x0000028A"
        FB_BYTES="0x0000000A00000000"
        UNLOCK_LABEL="40GB"
        ;;
    mixed|MIXED)
        PROFILE="mixed"
        CFG1="0x02779000"
        LMR="0x0000020B"
        FB_BYTES="0x0000001000000000"
        UNLOCK_LABEL="mixed"
        SKIP_GEOMETRY_REWRITE=1
        ;;
    *)
        die "Unknown CMPUNLOCKER_CARD_PROFILE='${PROFILE}' (use 8gb, 10gb, or mixed)"
        ;;
esac

BUILD_STAMP="${VERSION}:${KVER}:${PROFILE}:${PATCH_HASH}:$(sha256sum "${SCRIPT_DIR}/build.sh" | cut -d' ' -f1)"

mkdir -p "${BUILD_ROOT}"

if [[ ! -f "${TARBALL}" ]]; then
    info "Downloading open-gpu-kernel-modules ${VERSION}..."
    curl -L --fail -o "${TARBALL}.partial" "${TARBALL_URL}"
    mv "${TARBALL}.partial" "${TARBALL}"
    ok "Downloaded ${TARBALL}"
else
    ok "Using cached tarball ${TARBALL}"
fi

STAMP_FILE="${SRC_DIR}/.cmpunlocker-stamp"
if [[ -d "${SRC_DIR}" ]] && [[ "$(cat "${STAMP_FILE}" 2>/dev/null || true)" == "${BUILD_STAMP}" ]]; then
    SKIP_PREP=1
    ok "Source tree already extracted and patched for this exact build; reusing it"
else
    SKIP_PREP=0
    info "Extracting sources..."
    rm -rf "${SRC_DIR}"
    tar -xzf "${TARBALL}" -C "${BUILD_ROOT}"
    if [[ ! -d "${SRC_DIR}" ]]; then
        extracted="$(find "${BUILD_ROOT}" -maxdepth 1 -type d -name "${SRC_NAME}*" | head -1)"
        [[ -n "${extracted}" ]] || die "Extracted source tree not found"
        mv "${extracted}" "${SRC_DIR}"
    fi
    ok "Sources ready: ${SRC_DIR}"

    info "Applying unlock patches..."
    cd "${SRC_DIR}"
    for i in "${!PATCH_ORDER[@]}"; do
        info "  ${PATCH_ORDER[$i]}"
        patch --fuzz=0 --batch --forward -p1 < "${PATCH_FILES[$i]}"
    done
    ok "All patches applied"

    GSP_C="${SRC_DIR}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
    [[ -f "${GSP_C}" ]] || die "Missing ${GSP_C} after patching"

    info "Applying memory profile ${PROFILE} (${UNLOCK_LABEL} geometry)..."
    if [[ "${SKIP_GEOMETRY_REWRITE}" -eq 1 ]]; then
        info "mixed profile: runtime device-id geometry (no build-time CFG1/LMR rewrite)"
    else
        python3 - "${GSP_C}" "${CFG1}" "${LMR}" "${FB_BYTES}" "${UNLOCK_LABEL}" <<'PY'
import pathlib, re, sys
path, cfg1, lmr, fb, label = sys.argv[1:6]
text = pathlib.Path(path).read_text()
if (
    "SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID" in text
    and "SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID" in text
    and "0x02779000U" in text
    and "0x02669000U" in text
    and "0x0000001000000000ULL" in text
    and "0x0000000A00000000ULL" in text
):
    print(f"runtime device-id geometry (profile metadata={label})")
    raise SystemExit(0)

text2, n1 = re.subn(
    r"(NvU32 cfg1Value = )0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{cfg1}\g<2>",
    text,
    count=1,
)
text2, n2 = re.subn(
    r"(NvU32 lmrValue\s*=\s*)0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{lmr}\g<2>",
    text2,
    count=1,
)
text2, n3 = re.subn(
    r"(NvU64 targetFbBytes = )0x[0-9A-Fa-f]+ULL;\s*/\*[^*]*\*/",
    rf"\g<1>{fb}ULL;  /* {label} */",
    text2,
    count=1,
)
if n1 != 1 or n2 != 1 or n3 != 1:
    raise SystemExit(
        f"geometry rewrite failed (cfg1={n1} lmr={n2} fb={n3}); check kernel_gsp.c markers"
    )
pathlib.Path(path).write_text(text2)
print(f"cfg1={cfg1} lmr={lmr} fb={fb} ({label})")
PY
    fi
    ok "Memory profile ${PROFILE}: unlock_geometry=${UNLOCK_LABEL}"

    printf '%s\n' "${BUILD_STAMP}" > "${STAMP_FILE}"
fi

GSP_C="${SRC_DIR}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
MEM_MGR_C="${SRC_DIR}/src/nvidia/src/kernel/gpu/mem_mgr/mem_mgr.c"
FB_REGION_VALIDATOR_TEST="${SCRIPT_DIR}/../tools/test-fb-region-validator.py"
PMA_GUARD_TEST="${SCRIPT_DIR}/../tools/test-pma-guard.py"
[[ -f "${GSP_C}" ]] || die "Missing ${GSP_C} after source preparation"
[[ -f "${MEM_MGR_C}" ]] || die "Missing ${MEM_MGR_C} after source preparation"
[[ -f "${FB_REGION_VALIDATOR_TEST}" ]] || \
    die "Missing FB-region validator self-test: ${FB_REGION_VALIDATOR_TEST}"
[[ -f "${PMA_GUARD_TEST}" ]] || \
    die "Missing materialized FB/PMA guard self-test: ${PMA_GUARD_TEST}"
if ! python3 "${FB_REGION_VALIDATOR_TEST}" "${GSP_C}"; then
    die "Native FB-region validator source/semantic self-test failed"
fi
ok "Native FB-region validator passed compiled boundary-value tests"
if ! python3 "${PMA_GUARD_TEST}" "${MEM_MGR_C}"; then
    die "Materialized FB/PMA guard source/semantic self-test failed"
fi
ok "Materialized FB/PMA guard passed compiled fail-closed tests"
python3 - "${MEM_MGR_C}" "${GSP_C}" "${SRC_DIR}" <<'PY'
import pathlib
import sys

mem_mgr = pathlib.Path(sys.argv[1])
gsp_source = pathlib.Path(sys.argv[2])
source_root = pathlib.Path(sys.argv[3])
text = mem_mgr.read_text(encoding="utf-8")
guard = text.find("SEC2_DEBUG_PMA_GUARD")
first_registration = text.find("status = memmgrPmaRegisterRegions(")
required = (
    "build=cmpunlocker-safety-v3",
    "GSP_FW_WPR_META_MAGIC",
    "gspFwHeapSize",
    "pRegion->limit >= pWprMeta->gspFwRsvdStart",
    "refusing PMA registration",
)
if guard < 0 or first_registration < 0 or guard >= first_registration:
    raise SystemExit("PMA safety guard is missing or occurs after PMA registration")
if any(marker not in text for marker in required):
    raise SystemExit("PMA safety guard is missing a fail-closed invariant")

gsp_text = gsp_source.read_text(encoding="utf-8")
payload_required = (
    "_kgspSec2PostblTimingEnsurePayloadMemdesc",
    "MEMORY_DESCRIPTOR *pNewSignatureMemdesc = NULL",
    "SEC2 reset before post-BL payload refill",
    "retaining current payload",
    "SEC2 reset before stock payload rebuild",
    "retaining post-BL payload",
    "signatureSize < SEC2_POSTBL_TIMING_SIGNATURE_SIZE",
    "i + sizeof(NvU32) <= SEC2_POSTBL_TIMING_SIGNATURE_SIZE",
)
if any(marker not in gsp_text for marker in payload_required):
    raise SystemExit("SEC2 retry payload bounds/reallocation guard is missing")

ensure_start = gsp_text.find("_kgspSec2PostblTimingEnsurePayloadMemdesc")
ensure_end = gsp_text.find("static void\n_kgspSec2PostblTimingPutU32", ensure_start)
if ensure_start < 0 or ensure_end < 0:
    raise SystemExit("SEC2 retry payload allocator boundaries are missing")
ensure_text = gsp_text[ensure_start:ensure_end]
release = ensure_text.find("memdescFree(pKernelGsp->pSignatureMemdesc)")
if release < 0:
    raise SystemExit("SEC2 retry allocator does not release the undersized old memdesc")

refill_start = gsp_text.find("NV_STATUS\nkgspSec2PostblTimingRefillPayload(")
refill_end = gsp_text.find(
    "NV_STATUS\nkgspSec2PostblTimingRebuildStockSignature(", refill_start
)
if refill_start < 0 or refill_end < 0:
    raise SystemExit("SEC2 retry refill function boundaries are missing")
refill_text = gsp_text[refill_start:refill_end]
refill_reset = refill_text.find("status = kflcnReset_HAL")
ensure_call = refill_text.find("_kgspSec2PostblTimingEnsurePayloadMemdesc")
if refill_reset < 0 or ensure_call < 0 or refill_reset >= ensure_call:
    raise SystemExit(
        "SEC2 must be reset successfully before the retry allocator can release the old memdesc"
    )

stock_start = gsp_text.find("NV_STATUS\nkgspSec2PostblTimingRebuildStockSignature(")
stock_end = gsp_text.find(
    "\nNV_STATUS\n",
    stock_start + len("NV_STATUS\nkgspSec2PostblTimingRebuildStockSignature("),
)
if stock_start < 0 or stock_end < 0:
    raise SystemExit("SEC2 stock-payload rebuild function boundaries are missing")
stock_text = gsp_text[stock_start:stock_end]
stock_reset = stock_text.find("status = kflcnReset_HAL")
stock_release = stock_text.find("memdescFree(pKernelGsp->pSignatureMemdesc)")
if stock_reset < 0 or stock_release < 0 or stock_reset >= stock_release:
    raise SystemExit(
        "SEC2 must be reset successfully before releasing the old stock payload memdesc"
    )

boot_attempt_start = gsp_text.find("_kgspBootGspRm(")
boot_attempt_end = gsp_text.find("// Fail early if WPR2 is up", boot_attempt_start)
if boot_attempt_start < 0 or boot_attempt_end < 0:
    raise SystemExit("GSP boot-attempt reset guard boundaries are missing")
boot_attempt_text = gsp_text[boot_attempt_start:boot_attempt_end]
attempt_reset = boot_attempt_text.find("status = kflcnReset_HAL")
attempt_reject = boot_attempt_text.find("if (status != NV_OK)", attempt_reset)
attempt_retain = boot_attempt_text.find("refusing metadata mutation", attempt_reject)
attempt_return = boot_attempt_text.find("return status", attempt_retain)
if not (0 <= attempt_reset < attempt_reject < attempt_retain < attempt_return):
    raise SystemExit(
        "Every GSP boot attempt must reset SEC2 and fail before WPR metadata mutation"
    )

destruct_start = gsp_text.find("kgspDestruct_IMPL")
destruct_end = gsp_text.find("// set VBIOS version string back", destruct_start)
if destruct_start < 0 or destruct_end < 0:
    raise SystemExit("KernelGsp destructor DMA-retention guard boundaries are missing")
destruct_text = gsp_text[destruct_start:destruct_end]
if "if (resetStatus != NV_OK)" not in destruct_text:
    raise SystemExit("KernelGsp destructor must accept only NV_OK from the SEC2 reset")
for marker in (
    "cannot quiesce SEC2 during teardown",
    "SEC2 teardown reset failed",
):
    branch = destruct_text.find(marker)
    stop_polling = destruct_text.find("_kgspStopLogPolling", branch)
    deregister = destruct_text.find("nvlogDeregisterFlushCb", stop_polling)
    retain_return = destruct_text.find("return;", deregister)
    if not (0 <= branch < stop_polling < deregister < retain_return):
        raise SystemExit(
            f"Destructor branch '{marker}' must stop log polling and deregister "
            "the flush callback before retaining DMA buffers"
        )

booter_source = (
    source_root
    / "src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_booter_tu102.c"
)
booter_text = booter_source.read_text(encoding="utf-8")
execute = booter_text.find("status = s_executeBooterUcode_TU102")
failure = booter_text.find("if (status != NV_OK)", execute)
failure_reset = booter_text.find("resetStatus = kflcnReset_HAL", failure)
strict_reset = booter_text.find("if (resetStatus != NV_OK)", failure_reset)
not_quiesced = booter_text.find("Booter DMA state is not quiesced", strict_reset)
reject_reset = booter_text.find("return resetStatus", not_quiesced)
if not (
    0 <= execute < failure < failure_reset < strict_reset < not_quiesced < reject_reset
):
    raise SystemExit(
        "Booter failure must reset SEC2 and accept only NV_OK before returning"
    )

tu102_source = (
    source_root
    / "src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
)
tu102_text = tu102_source.read_text(encoding="utf-8")
if "portMemFree(pKernelGsp->pStockSignatureData)" not in tu102_text:
    raise SystemExit("SEC2 stock-signature cleanup is missing")

for tree in (source_root / "src" / "nvidia", source_root / "kernel-open"):
    for path in tree.rglob("*"):
        if path.suffix not in {".c", ".h"}:
            continue
        candidate = path.read_text(encoding="utf-8", errors="replace")
        if (
            "memmgrSec2DebugLateExtendHighPmaRegion" in candidate
            or "SEC2_DEBUG_LATE_PMA" in candidate
        ):
            raise SystemExit(f"unsafe late-PMA source remains in {path}")
PY
ok "PMA/payload safety invariants are ordered correctly; late-PMA source is absent"
}

validate_module() {
    local ko="$1"
    local expected_name="$2"
    local expected_internal module_internal module_version vermagic srcversion

    case "${expected_name}" in
        nvidia.ko)         expected_internal="nvidia" ;;
        nvidia-modeset.ko) expected_internal="nvidia_modeset" ;;
        nvidia-uvm.ko)     expected_internal="nvidia_uvm" ;;
        nvidia-drm.ko)     expected_internal="nvidia_drm" ;;
        nvidia-peermem.ko) expected_internal="nvidia_peermem" ;;
        *) die "No internal module-name mapping for ${expected_name}" ;;
    esac

    [[ -f "${ko}" ]] || die "Missing required module ${expected_name}: ${ko}"
    [[ "$(basename "${ko}")" == "${expected_name}" ]] || \
        die "Unexpected module filename: ${ko} (wanted ${expected_name})"
    if ! module_internal="$(modinfo -F name -- "${ko}" 2>/dev/null)"; then
        die "Cannot read internal module name from ${ko}"
    fi
    [[ "${module_internal}" == "${expected_internal}" ]] || \
        die "${expected_name} contains module '${module_internal:-missing}', expected '${expected_internal}'"
    if [[ "${expected_name}" == "nvidia.ko" ]] && \
       ! grep -aFq 'cmpunlocker-safety-v3' "${ko}"; then
        die "${expected_name} lacks the required cmpunlocker safety-v3 provenance marker"
    fi
    if ! module_version="$(modinfo -F version -- "${ko}" 2>/dev/null)"; then
        die "Cannot read version from ${ko}"
    fi
    [[ "${module_version}" == "${VERSION}" ]] || \
        die "${expected_name} version ${module_version:-missing} != ${VERSION}"
    if ! vermagic="$(modinfo -F vermagic -- "${ko}" 2>/dev/null)"; then
        die "Cannot read vermagic from ${ko}"
    fi
    [[ "${vermagic}" == "${KVER}" || "${vermagic}" == "${KVER} "* ]] || \
        die "${expected_name} vermagic '${vermagic:-missing}' does not target ${KVER}"
    if ! srcversion="$(modinfo -F srcversion -- "${ko}" 2>/dev/null)"; then
        die "Cannot read srcversion from ${ko}"
    fi
    [[ -n "${srcversion}" ]] || die "${expected_name} has an empty srcversion"
}

resolve_installed_module() {
    local module_name="$1"
    local expected_file="$2"
    local resolved resolved_canonical expected_canonical

    if ! resolved="$(modinfo -k "${KVER}" -n "${module_name}" 2>/dev/null)" || \
       [[ -z "${resolved}" ]]; then
        return 1
    fi
    resolved_canonical="$(readlink -f -- "${resolved}" 2>/dev/null)" || return 1
    expected_canonical="$(readlink -f -- "${expected_file}" 2>/dev/null)" || return 1
    printf '%s\n' "${resolved_canonical}"
    [[ "${resolved_canonical}" == "${expected_canonical}" ]] || return 2
}

select_mkinitcpio_target() {
    local preset="/etc/mkinitcpio.d/${INITRAMFS_PRESET}.preset"
    local values=()

    mapfile -t values < <(python3 - "${preset}" "${KVER}" \
        "/lib/modules/${KVER}/vmlinuz" <<'PY'
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
        # PRESETS selected only default, so fallback/other preset scalars are
        # inert and may use option strings that are not single shell words.
        continue
    if any(token in encoded for token in ("$", "`", ";", "(", ")")):
        raise SystemExit(f"dynamic preset value on line {number}")
    values = shlex.split(encoded, posix=True)
    if not values and encoded == "":
        assignments[key] = ""
        continue
    if len(values) != 1:
        raise SystemExit(f"ambiguous preset value on line {number}")
    assignments[key] = values[0]

if presets != ["default"]:
    raise SystemExit("mkinitcpio preset must select exactly one auditable default image")
if assignments.get("default_uki") or assignments.get("default_efi_image"):
    raise SystemExit("default preset UKI output is not supported safely")
if assignments.get("default_options", "") or assignments.get("ALL_options", ""):
    raise SystemExit("mkinitcpio preset options could override the exact kernel")

for field in ("cmdline", "splash", "kerneldest"):
    effective = assignments.get(f"default_{field}", "") or assignments.get(f"ALL_{field}", "")
    if effective:
        raise SystemExit(f"mkinitcpio effective {field} is not reproduced safely")

kernel_spec = assignments.get("default_kver", "") or assignments.get("ALL_kver", "")
if kernel_spec and kernel_spec != kver:
    kernel_path = pathlib.Path(kernel_spec)
    if not kernel_path.is_absolute():
        raise SystemExit("mkinitcpio kver is neither the exact release nor an absolute image")
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
        raise SystemExit("mkinitcpio preset kernel image does not match target KVER")

image = assignments.get("default_image", "")
# Match mkinitcpio's effective default-preset selection exactly: a non-empty
# default_config overrides ALL_config, otherwise ALL_config is inherited.
config = assignments.get("default_config", "") or assignments.get("ALL_config", "")
for label, value in (("image", image),):
    path = pathlib.Path(value)
    if not value or not path.is_absolute():
        raise SystemExit(f"mkinitcpio {label} is not an absolute path")
if config:
    config_path = pathlib.Path(config)
    if not config_path.is_absolute():
        raise SystemExit("mkinitcpio config is not an absolute path")
    cst = os.lstat(config_path)
    if not stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode):
        raise SystemExit("unsafe mkinitcpio config")
parent = pathlib.Path(image).parent
dst = os.lstat(parent)
if not stat.S_ISDIR(dst.st_mode) or stat.S_ISLNK(dst.st_mode):
    raise SystemExit("unsafe mkinitcpio output parent")
try:
    ist = os.lstat(image)
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
        [[ "${INITRAMFS_PRESET}" =~ ^[A-Za-z0-9._+-]+$ && \
           -f "/etc/mkinitcpio.d/${INITRAMFS_PRESET}.preset" ]] || return 1
        select_mkinitcpio_target || return 1
    else
        return 1
    fi
}

rebuild_initramfs() {
    local -a mkinitcpio_args=()
    case "${INITRAMFS_TOOL}" in
        update-initramfs)
            info "Rebuilding initramfs (update-initramfs)..."
            if ! update-initramfs -u -k "${KVER}"; then
                return 1
            fi
            ;;
        dracut)
            info "Rebuilding initramfs (dracut)..."
            if ! dracut --force --kver "${KVER}"; then
                return 1
            fi
            ;;
        mkinitcpio)
            info "Rebuilding ${INITRAMFS_IMAGE} explicitly for ${KVER} (mkinitcpio)..."
            mkinitcpio_args=(-k "${KVER}" -g "${INITRAMFS_IMAGE}")
            if [[ "${INITRAMFS_CONFIG}" != "absent" ]]; then
                mkinitcpio_args+=(-c "${INITRAMFS_CONFIG}")
            fi
            if ! mkinitcpio "${mkinitcpio_args[@]}"; then
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
    ok "initramfs rebuilt with ${INITRAMFS_TOOL}"
}

TRANSACTION_ROOT="/lib/modules/.cmpunlocker-transactions"
STATE_ROOT="/var/lib/cmpunlocker"
LIFECYCLE_LOCK="${STATE_ROOT}/lifecycle.lock"
TRANSACTION_MARKER=".cmpunlocker-transaction"
TRANSACTION_JOURNAL="${TRANSACTION_ROOT}/${KVER}.journal"
LEGACY_JOURNAL="${TRANSACTION_ROOT}/${KVER}.legacy.pending"
STAGING_DIR=""
ROLLBACK_DIR=""
TRANSACTION_ACTIVE=0
ORIGINAL_PRESENT=0
TX_LOCK_FD=""
BUILD_LOCK_FD=""
LIFECYCLE_LOCK_FD=""
LEGACY_QUARANTINED=0
LEGACY_INDEX_REPAIRED=0
LEGACY_REPAIR_SAFE=0
TX_LOCK_HELD=0

validate_transaction_state_bytes() {
    local kind="$1"
    local path="$2"
    local first="${3:-}"
    local second="${4:-}"

    python3 - "${kind}" "${path}" "${first}" "${second}" <<'PY'
import os
import re
import stat
import sys

kind, path, first, second = sys.argv[1:]
limit = 4096

try:
    before = os.lstat(path)
except FileNotFoundError:
    raise SystemExit("transaction state file is missing")
if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
        or before.st_uid != 0 or before.st_gid != 0
        or before.st_nlink != 1
        or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_size > limit):
    raise SystemExit("unsafe transaction state inode")

flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, flags)
try:
    opened = os.fstat(fd)
    if ((opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != 0 or opened.st_gid != 0
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_size > limit):
        raise SystemExit("transaction state inode changed during open")
    chunks = []
    total = 0
    while True:
        block = os.read(fd, min(4096, limit + 1 - total))
        if not block:
            break
        chunks.append(block)
        total += len(block)
        if total > limit:
            raise SystemExit("transaction state file is too large")
    raw = b"".join(chunks)
    after = os.fstat(fd)
    if ((after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
            or after.st_size != len(raw)
            or after.st_mtime_ns != opened.st_mtime_ns
            or after.st_ctime_ns != opened.st_ctime_ns):
        raise SystemExit("transaction state changed while being read")
finally:
    os.close(fd)

if not raw or not raw.endswith(b"\n") or b"\x00" in raw or b"\r" in raw:
    raise SystemExit("transaction state has invalid byte framing")
try:
    text = raw.decode("ascii")
    first_ascii = first.encode("ascii")
    second_ascii = second.encode("ascii")
except UnicodeError:
    raise SystemExit("transaction state is not ASCII")

if kind == "legacy":
    expected = b"format=1\nkernel=" + first_ascii + b"\n"
    if raw != expected:
        raise SystemExit("legacy transaction state does not match")
elif kind == "marker":
    expected = b"id=" + first_ascii + b"\noriginal=" + second_ascii + b"\n"
    if raw != expected:
        raise SystemExit("module transaction marker does not match")
elif kind == "journal":
    match = re.fullmatch(
        r"format=1\nid=([A-Za-z0-9._-]+)\noriginal=([01])\n"
        r"phase=(prepared|discarding|restoring|committing)\n",
        text,
    )
    if match is None:
        raise SystemExit("invalid transaction journal grammar")
    tx_id, original, phase = match.groups()
    if phase == "discarding" and original != "0":
        raise SystemExit("invalid discarding journal")
    print(tx_id, original, phase, sep="\t")
else:
    raise SystemExit("unknown transaction state kind")
PY
}

ensure_legacy_journal() {
    local temporary
    if [[ -e "${LEGACY_JOURNAL}" || -L "${LEGACY_JOURNAL}" ]]; then
        validate_transaction_state_bytes legacy "${LEGACY_JOURNAL}" "${KVER}" || return 1
        LEGACY_QUARANTINED=1
        return 0
    fi
    temporary="$(mktemp "${TRANSACTION_ROOT}/.${KVER}.legacy.tmp.XXXXXX")" || return 1
    chown root:root "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    chmod 0600 "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    if ! printf 'format=1\nkernel=%s\n' "${KVER}" > "${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    sync -f "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    mv -T "${temporary}" "${LEGACY_JOURNAL}" || {
        rm -f -- "${temporary}"
        return 1
    }
    sync -f "${TRANSACTION_ROOT}" || return 1
    LEGACY_QUARANTINED=1
}

repair_legacy_quarantine_index() {
    depmod -a "${KVER}" || return 1
    rebuild_initramfs || return 1
    sync || return 1
    LEGACY_INDEX_REPAIRED=1
}

prepare_private_namespace() {
    python3 - "$1" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
parent = path.parent
if os.geteuid() != 0:
    raise SystemExit("private namespace creation requires effective uid 0")
pst = os.lstat(parent)
if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != 0 or pst.st_gid != 0):
    raise SystemExit("unsafe private namespace parent")

# Make the very first mkdir syscall create root:root even under sudo -g.
# Existing wrong-owner objects are never repaired by this helper.
os.setegid(0)
old_umask = os.umask(0o077)
created = False
try:
    try:
        os.mkdir(path, 0o700)
        created = True
    except FileExistsError:
        pass
finally:
    os.umask(old_umask)

st = os.lstat(path)
if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != 0 or st.st_gid != 0
        or stat.S_IMODE(st.st_mode) != 0o700):
    raise SystemExit("unsafe private namespace")
dfd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
if created:
    pfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(pfd)
    finally:
        os.close(pfd)
PY
}

prepare_public_module_parent() {
    python3 - "${INSTALL_PARENT}" "${KVER}" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
kver = sys.argv[2]
if path.name != "updates":
    raise SystemExit("unexpected module-parent basename")
parent = path.parent.resolve(strict=True)
if parent.name != kver:
    raise SystemExit("module-parent path does not bind the exact kernel")
pst = os.lstat(parent)
if (not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode)
        or pst.st_uid != 0 or pst.st_gid != 0
        or stat.S_IMODE(pst.st_mode) & 0o022):
    raise SystemExit("unsafe canonical kernel module root")
if path.resolve(strict=False) != parent / "updates":
    raise SystemExit("module-parent path resolves unexpectedly")

os.setegid(0)
old_umask = os.umask(0o022)
created = False
try:
    try:
        os.mkdir(path, 0o755)
        created = True
    except FileExistsError:
        pass
finally:
    os.umask(old_umask)

st = os.lstat(path)
if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid != 0 or st.st_gid != 0
        or stat.S_IMODE(st.st_mode) != 0o755
        or st.st_dev != pst.st_dev):
    raise SystemExit("unsafe public kernel updates directory")
dfd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
if created:
    pfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(pfd)
    finally:
        os.close(pfd)
PY
}

prepare_lock_file() {
    local lock_path="$1"
    local namespace="${2:-${TRANSACTION_ROOT}}"
    python3 - "${lock_path}" "${namespace}" <<'PY'
import os
import stat
import sys

path = os.fsencode(sys.argv[1])
root = os.fsencode(sys.argv[2])
if os.geteuid() != 0:
    raise SystemExit("transaction lock creation requires effective uid 0")
rst = os.lstat(root)
if (not stat.S_ISDIR(rst.st_mode) or stat.S_ISLNK(rst.st_mode)
        or rst.st_uid != 0 or rst.st_gid != 0
        or stat.S_IMODE(rst.st_mode) != 0o700):
    raise SystemExit("unsafe transaction lock namespace")
# Make the O_EXCL inode root:root at creation time under sudo -g, eliminating
# the otherwise unrecoverable open-to-fchown hard-cut window.
os.setegid(0)
flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
created = False
old_umask = os.umask(0o077)
try:
    try:
        fd = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
        created = True
    except FileExistsError:
        lst = os.lstat(path)
        if (not stat.S_ISREG(lst.st_mode) or stat.S_ISLNK(lst.st_mode)
                or lst.st_uid != 0 or lst.st_gid != 0 or lst.st_nlink != 1
                or stat.S_IMODE(lst.st_mode) != 0o600):
            raise SystemExit("unsafe preexisting transaction lock object")
        fd = os.open(path, flags)
finally:
    os.umask(old_umask)
try:
    if created:
        # A root process may deliberately run with a non-root effective group
        # (for example, sudo -g).  Normalize only the inode created by this
        # invocation; a pre-existing wrong-owner object remains a hard error.
        os.fchown(fd, 0, 0)
        fst = os.fstat(fd)
        if stat.S_IMODE(fst.st_mode) != 0o600:
            os.fchmod(fd, 0o600)
    else:
        fst = os.fstat(fd)
        if ((fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino)
                or not stat.S_ISREG(fst.st_mode)
                or fst.st_uid != 0 or fst.st_gid != 0
                or fst.st_nlink != 1
                or stat.S_IMODE(fst.st_mode) != 0o600):
            raise SystemExit("preexisting transaction lock changed during open")
    fst = os.fstat(fd)
    if (not stat.S_ISREG(fst.st_mode) or fst.st_uid != 0 or fst.st_gid != 0
            or fst.st_nlink != 1 or stat.S_IMODE(fst.st_mode) != 0o600):
        raise SystemExit("unsafe final transaction lock object")
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

sanitize_transaction_root() {
    local object base suffix cleaned=0

    while IFS= read -r -d '' object; do
        base="${object##*/}"

        # These are unpublished mktemp outputs.  A killed writer can leave
        # one behind, but no durable recovery decision can reference it.
        # Prove the complete protocol name and inode identity before unlinking
        # it from the already-private transaction namespace.
        if [[ "${base}" =~ ^\.[A-Za-z0-9][A-Za-z0-9._+-]*\.(journal|legacy)\.tmp\.[A-Za-z0-9]{6}$ ]]; then
            [[ -f "${object}" && ! -L "${object}" && \
               "$(stat -c '%u:%g:%a:%h' -- "${object}" 2>/dev/null)" == "0:0:600:1" ]] || {
                err "Unsafe unpublished transaction temporary: ${object}"
                return 1
            }
            rm -f -- "${object}" || return 1
            [[ ! -e "${object}" && ! -L "${object}" ]] || return 1
            cleaned=1
            continue
        fi

        case "${base}" in
            *.lock)
                suffix="${base%.lock}"
                [[ "${suffix}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && \
                   "${base}" == "${suffix}.lock" && -f "${object}" && ! -L "${object}" && \
                   "$(stat -c '%u:%g:%a:%h' -- "${object}" 2>/dev/null)" == "0:0:600:1" ]] || {
                    err "Unsafe transaction lock object: ${object}"
                    return 1
                }
                ;;
            "${KVER}.journal"|"${KVER}.legacy.pending")
                [[ -f "${object}" && ! -L "${object}" && \
                   "$(stat -c '%u:%g:%a' -- "${object}" 2>/dev/null)" == "0:0:600" ]] || {
                    err "Unsafe durable transaction state object: ${object}"
                    return 1
                }
                ;;
            "${KVER}.stage."*)
                suffix="${base#"${KVER}.stage."}"
                [[ -n "${suffix}" && "${suffix}" =~ ^[A-Za-z0-9._-]+$ && \
                   -d "${object}" && ! -L "${object}" ]] || {
                    err "Unsafe module transaction stage: ${object}"
                    return 1
                }
                ;;
            "${KVER}.legacy."*)
                suffix="${base#"${KVER}.legacy."}"
                [[ -n "${suffix}" && "${suffix}" =~ ^[A-Za-z0-9._+-]+$ && \
                   -d "${object}" && ! -L "${object}" ]] || {
                    err "Unsafe legacy transaction quarantine: ${object}"
                    return 1
                }
                ;;
            *)
                err "Unknown or unrecovered transaction-root object: ${object}"
                return 1
                ;;
        esac
    done < <(find -P "${TRANSACTION_ROOT}" -mindepth 1 -maxdepth 1 -print0)

    if (( cleaned == 1 )); then
        sync -f "${TRANSACTION_ROOT}" || return 1
    fi
}

prepare_lifecycle_lock() {
    local inherited_fd="${CMPUNLOCKER_LIFECYCLE_LOCK_FD:-}"
    local inherited_target expected_target

    prepare_private_namespace "${STATE_ROOT}" || \
        die "State root must be a root-owned real directory with mode 0700: ${STATE_ROOT}"
    prepare_lock_file "${LIFECYCLE_LOCK}" "${STATE_ROOT}" || \
        die "Unsafe cmpunlocker lifecycle lock object"

    if [[ -n "${inherited_fd}" ]]; then
        [[ "${inherited_fd}" =~ ^[0-9]+$ && -e "/proc/$$/fd/${inherited_fd}" ]] || \
            die "Invalid inherited lifecycle lock descriptor"
        inherited_target="$(readlink -f -- "/proc/$$/fd/${inherited_fd}" 2>/dev/null || true)"
        expected_target="$(readlink -f -- "${LIFECYCLE_LOCK}" 2>/dev/null || true)"
        [[ -n "${expected_target}" && "${inherited_target}" == "${expected_target}" ]] || \
            die "Inherited lifecycle lock descriptor targets the wrong file"
        [[ -f "/proc/$$/fd/${inherited_fd}" && \
           "$(stat -Lc '%u:%g:%a' "/proc/$$/fd/${inherited_fd}")" == "0:0:600" ]] || \
            die "Unsafe inherited lifecycle lock descriptor"
        flock -n "${inherited_fd}" || die "Inherited lifecycle lock is not held"
        LIFECYCLE_LOCK_FD="${inherited_fd}"
    else
        exec {LIFECYCLE_LOCK_FD}<>"${LIFECYCLE_LOCK}"
        flock -n "${LIFECYCLE_LOCK_FD}" || \
            die "Another cmpunlocker install/remove/build lifecycle is active"
    fi
}

safe_remove_transaction_dir() {
    local tx_path="$1"
    case "${tx_path}" in
        "${TRANSACTION_ROOT}/${KVER}.stage."*) ;;
        *)
            warn "Refusing unexpected transaction path: ${tx_path}"
            return 1
            ;;
    esac
    [[ -d "${tx_path}" && ! -L "${tx_path}" ]] || return 1
    python3 - "${tx_path}" "${TRANSACTION_ROOT}" <<'PY' || return 1
import os
import pathlib
import re
import stat
import sys

target_arg = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2]).resolve(strict=True)
target = target_arg.resolve(strict=True)
lst = os.lstat(target_arg)
if not stat.S_ISDIR(lst.st_mode) or stat.S_ISLNK(lst.st_mode):
    raise SystemExit("unsafe transaction cleanup root")
if target.parent != root:
    raise SystemExit("transaction cleanup root escaped its private namespace")

def decode_mount_path(value):
    raw = os.fsencode(value)
    raw = re.sub(
        br"\\([0-7]{3})",
        lambda match: bytes((int(match.group(1), 8),)),
        raw,
    )
    return os.path.normpath(os.path.abspath(os.fsdecode(raw)))

with open("/proc/self/mountinfo", "rb") as stream:
    for raw_line in stream:
        line = raw_line.rstrip(b"\n")
        if not line:
            continue
        fields = line.split(b" - ", 1)[0].split()
        if len(fields) < 5:
            raise SystemExit("malformed mountinfo while validating transaction cleanup")
        mountpoint = decode_mount_path(os.fsdecode(fields[4]))
        if mountpoint == os.fspath(root) or mountpoint.startswith(os.fspath(root) + os.sep):
            raise SystemExit(f"mounted object inside transaction cleanup root: {mountpoint}")
PY
    rm -rf -- "${tx_path}" || return 1
    [[ ! -e "${tx_path}" && ! -L "${tx_path}" ]]
}

atomic_exchange_dirs() {
    python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

left, right = (os.fsencode(value) for value in sys.argv[1:3])
libc = ctypes.CDLL(None, use_errno=True)
try:
    renameat2 = libc.renameat2
except AttributeError:
    raise SystemExit("libc does not expose renameat2")
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                      ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, left, -100, right, 2) != 0:  # RENAME_EXCHANGE
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err), os.fsdecode(left), os.fsdecode(right))
PY
}

atomic_move_noreplace() {
    python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

source, target = (os.fsencode(value) for value in sys.argv[1:3])
libc = ctypes.CDLL(None, use_errno=True)
try:
    renameat2 = libc.renameat2
except AttributeError:
    raise SystemExit("libc does not expose renameat2")
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                      ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, source, -100, target, 1) != 0:  # RENAME_NOREPLACE
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err), os.fsdecode(source), os.fsdecode(target))
PY
}

write_transaction_marker() {
    local directory="$1"
    local tx_id="$2"
    local original="$3"
    local marker="${directory}/${TRANSACTION_MARKER}"
    local temporary

    [[ "${tx_id}" =~ ^[A-Za-z0-9._-]+$ && "${original}" =~ ^[01]$ ]] || return 1
    [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
    [[ ! -e "${marker}" && ! -L "${marker}" ]] || return 1
    temporary="$(mktemp "${directory}/.cmpunlocker-marker.tmp.XXXXXX")" || return 1
    chown root:root "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    chmod 0600 "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    if ! printf 'id=%s\noriginal=%s\n' "${tx_id}" "${original}" > "${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    sync -f "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    validate_transaction_state_bytes marker "${temporary}" "${tx_id}" "${original}" || {
        rm -f -- "${temporary}"
        return 1
    }
    atomic_move_noreplace "${temporary}" "${marker}" || {
        rm -f -- "${temporary}"
        return 1
    }
    sync -f "${directory}"
}

validate_unmarked_stage_candidate() {
    local stage="$1"

    python3 - "${stage}" "${TRANSACTION_ROOT}" "${KVER}" \
        "${TRANSACTION_MARKER}" "${TARGET_MODULES[@]}" <<'PY'
import os
import pathlib
import re
import stat
import sys

stage = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
kver = sys.argv[3]
marker_name = sys.argv[4]
module_names = set(sys.argv[5:])
metadata_names = {"driver_version", "card_profile", "unlock_geometry", "gpu_inventory"}

rst = os.lstat(root)
sst = os.lstat(stage)
if (not stat.S_ISDIR(rst.st_mode) or stat.S_ISLNK(rst.st_mode)
        or rst.st_uid != 0 or rst.st_gid != 0
        or stat.S_IMODE(rst.st_mode) != 0o700):
    raise SystemExit("unsafe transaction root")
if (not stat.S_ISDIR(sst.st_mode) or stat.S_ISLNK(sst.st_mode)
        or sst.st_uid != 0 or sst.st_gid != 0
        or sst.st_dev != rst.st_dev
        or stat.S_IMODE(sst.st_mode) not in (0o700, 0o755)):
    raise SystemExit("unsafe unpublished stage directory")
if stage.parent.resolve(strict=True) != root.resolve(strict=True):
    raise SystemExit("unpublished stage escaped the transaction root")
expected_prefix = f"{kver}.stage."
if (not stage.name.startswith(expected_prefix)
        or not re.fullmatch(r"[A-Za-z0-9._-]+", stage.name[len(expected_prefix):])):
    raise SystemExit("unsafe unpublished stage name")
if os.path.lexists(stage / marker_name):
    raise SystemExit("authoritative marker exists in unpublished-stage validator")

marker_temps = 0
for entry in os.scandir(stage):
    path = pathlib.Path(entry.path)
    est = os.lstat(path)
    if (not stat.S_ISREG(est.st_mode) or stat.S_ISLNK(est.st_mode)
            or est.st_uid != 0 or est.st_gid != 0 or est.st_nlink != 1
            or est.st_dev != sst.st_dev
            or stat.S_IMODE(est.st_mode) not in (0o600, 0o644)):
        raise SystemExit(f"unsafe object in unpublished stage: {path}")
    if path.name in module_names or path.name in metadata_names:
        continue
    if re.fullmatch(r"\.cmpunlocker-marker\.tmp\.[A-Za-z0-9]{6}", path.name):
        marker_temps += 1
        if marker_temps > 1:
            raise SystemExit("multiple unpublished marker temporaries")
        continue
    raise SystemExit(f"unknown object in unpublished stage: {path}")
PY
}

transaction_marker_state() {
    local directory="$1"
    local expected_id="$2"
    local expected_original="$3"
    local marker="${directory}/${TRANSACTION_MARKER}"

    if [[ ! -e "${marker}" && ! -L "${marker}" ]]; then
        return 1
    fi
    validate_transaction_state_bytes marker "${marker}" \
        "${expected_id}" "${expected_original}" || return 2
}

write_transaction_journal() {
    local tx_id="$1"
    local original="$2"
    local phase="$3"
    local temporary

    [[ "${tx_id}" =~ ^[A-Za-z0-9._-]+$ && "${original}" =~ ^[01]$ ]] || return 1
    [[ "${phase}" == "prepared" || "${phase}" == "discarding" || \
       "${phase}" == "restoring" || "${phase}" == "committing" ]] || return 1
    [[ "${phase}" != "discarding" || "${original}" == "0" ]] || return 1
    if [[ -e "${TRANSACTION_JOURNAL}" || -L "${TRANSACTION_JOURNAL}" ]]; then
        [[ -f "${TRANSACTION_JOURNAL}" && ! -L "${TRANSACTION_JOURNAL}" ]] || return 1
    fi
    temporary="$(mktemp "${TRANSACTION_ROOT}/.${KVER}.journal.tmp.XXXXXX")" || return 1
    chown root:root "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    chmod 0600 "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    if ! printf 'format=1\nid=%s\noriginal=%s\nphase=%s\n' \
        "${tx_id}" "${original}" "${phase}" > "${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    sync -f "${temporary}" || { rm -f -- "${temporary}"; return 1; }
    mv -T "${temporary}" "${TRANSACTION_JOURNAL}" || {
        rm -f -- "${temporary}"
        return 1
    }
    sync -f "${TRANSACTION_ROOT}"
}

read_transaction_journal() {
    local parsed extra

    parsed="$(validate_transaction_state_bytes journal "${TRANSACTION_JOURNAL}")" || return 1
    [[ -n "${parsed}" && "${parsed}" != *$'\n'* ]] || return 1
    IFS=$'\t' read -r JOURNAL_ID JOURNAL_ORIGINAL JOURNAL_PHASE extra <<< "${parsed}"
    [[ -z "${extra}" ]] || return 1
    [[ "${JOURNAL_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "${JOURNAL_ORIGINAL}" =~ ^[01]$ ]] || return 1
    [[ "${JOURNAL_PHASE}" == "prepared" || "${JOURNAL_PHASE}" == "discarding" || \
       "${JOURNAL_PHASE}" == "restoring" || "${JOURNAL_PHASE}" == "committing" ]] || return 1
    [[ "${JOURNAL_PHASE}" != "discarding" || "${JOURNAL_ORIGINAL}" == "0" ]] || return 1
}

remove_transaction_journal() {
    [[ -f "${TRANSACTION_JOURNAL}" && ! -L "${TRANSACTION_JOURNAL}" ]] || return 1
    rm -f -- "${TRANSACTION_JOURNAL}" || return 1
    sync -f "${TRANSACTION_ROOT}"
}

validate_clean_install_dir() {
    local allow_marker="${1:-0}"
    local require_safety_marker="${2:-0}"
    local metadata metadata_name name expected_internal internal module_version vermagic srcversion
    local parent_dev canonical_parent canonical_live entry expected_entry_count
    local found_entries=() found_modules=()

    [[ "${allow_marker}" =~ ^[01]$ && "${require_safety_marker}" =~ ^[01]$ ]] || return 1
    if [[ ! -e "${INSTALL_MOD_DIR}" && ! -L "${INSTALL_MOD_DIR}" ]]; then
        [[ "${require_safety_marker}" == "0" ]] || return 1
        return 0
    fi
    [[ -d "${INSTALL_MOD_DIR}" && ! -L "${INSTALL_MOD_DIR}" ]] || return 1
    if [[ "${require_safety_marker}" == "1" ]]; then
        [[ -d "${INSTALL_PARENT}" && ! -L "${INSTALL_PARENT}" && \
           "$(stat -c '%u:%g:%a' -- "${INSTALL_PARENT}" 2>/dev/null)" == "0:0:755" ]] || return 1
        canonical_parent="$(readlink -f -- "${INSTALL_PARENT}" 2>/dev/null)" || return 1
        canonical_live="$(readlink -f -- "${INSTALL_MOD_DIR}" 2>/dev/null)" || return 1
        [[ "${canonical_live}" == "${canonical_parent}/cmpunlocker" ]] || return 1
        parent_dev="$(stat -c '%d' -- "${INSTALL_PARENT}" 2>/dev/null)" || return 1
        [[ "$(stat -c '%u:%g:%a:%d' -- "${INSTALL_MOD_DIR}" 2>/dev/null)" == \
               "0:0:755:${parent_dev}" ]] || return 1
    fi
    if [[ "${allow_marker}" == "0" ]]; then
        [[ ! -e "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" && \
           ! -L "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" ]] || return 1
    fi
    [[ -f "${INSTALL_MOD_DIR}/driver_version" && \
       ! -L "${INSTALL_MOD_DIR}/driver_version" ]] || return 1
    metadata="$(tr -d '[:space:]' < "${INSTALL_MOD_DIR}/driver_version" 2>/dev/null)" || return 1
    [[ "${metadata}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    if [[ "${require_safety_marker}" == "1" ]]; then
        for metadata_name in driver_version card_profile unlock_geometry gpu_inventory; do
            [[ -f "${INSTALL_MOD_DIR}/${metadata_name}" && \
               ! -L "${INSTALL_MOD_DIR}/${metadata_name}" && \
               "$(stat -c '%u:%g:%a:%h:%d' -- "${INSTALL_MOD_DIR}/${metadata_name}" 2>/dev/null)" == \
                   "0:0:644:1:${parent_dev}" ]] || return 1
        done
        cmp -s -- "${INSTALL_MOD_DIR}/driver_version" <(printf '%s\n' "${VERSION}") || return 1
        if cmp -s -- "${INSTALL_MOD_DIR}/card_profile" <(printf '8gb\n'); then
            cmp -s -- "${INSTALL_MOD_DIR}/unlock_geometry" <(printf '64GB\n') || return 1
        elif cmp -s -- "${INSTALL_MOD_DIR}/card_profile" <(printf '10gb\n'); then
            cmp -s -- "${INSTALL_MOD_DIR}/unlock_geometry" <(printf '40GB\n') || return 1
        elif cmp -s -- "${INSTALL_MOD_DIR}/card_profile" <(printf 'mixed\n'); then
            cmp -s -- "${INSTALL_MOD_DIR}/unlock_geometry" <(printf 'mixed\n') || return 1
        else
            return 1
        fi
        mapfile -t found_entries < <(find "${INSTALL_MOD_DIR}" -mindepth 1 -type f \
            -printf '%P\n' | sort)
        expected_entry_count=9
        if [[ -e "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" || \
              -L "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" ]]; then
            [[ "${allow_marker}" == "1" && \
               -f "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" && \
               ! -L "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" && \
               "$(stat -c '%u:%g:%a:%h:%d' -- \
                   "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" 2>/dev/null)" == \
                   "0:0:600:1:${parent_dev}" ]] || return 1
            expected_entry_count=10
        fi
        [[ ${#found_entries[@]} -eq ${expected_entry_count} ]] || return 1
        for entry in "${found_entries[@]}"; do
            case "${entry}" in
                driver_version|card_profile|unlock_geometry|gpu_inventory|\
                nvidia.ko|nvidia-modeset.ko|nvidia-uvm.ko|nvidia-drm.ko|nvidia-peermem.ko)
                    ;;
                "${TRANSACTION_MARKER}") [[ "${allow_marker}" == "1" ]] || return 1 ;;
                *) return 1 ;;
            esac
        done
    fi
    # depmod follows directory entries deeply enough that even a non-module
    # symlink can expose an external *.ko.  Permit regular files only and keep
    # the module payload to the exact five top-level names below.
    if find "${INSTALL_MOD_DIR}" -mindepth 1 ! -type f -print -quit | grep -q .; then
        return 1
    fi
    mapfile -t found_modules < <(find "${INSTALL_MOD_DIR}" -mindepth 1 -type f \
        \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
        -printf '%P\n' | sort)
    [[ ${#found_modules[@]} -eq ${#TARGET_MODULES[@]} ]] || return 1
    for name in "${found_modules[@]}"; do
        [[ " ${TARGET_MODULES[*]} " == *" ${name} "* ]] || return 1
    done
    for name in "${TARGET_MODULES[@]}"; do
        case "${name}" in
            nvidia.ko)         expected_internal="nvidia" ;;
            nvidia-modeset.ko) expected_internal="nvidia_modeset" ;;
            nvidia-uvm.ko)     expected_internal="nvidia_uvm" ;;
            nvidia-drm.ko)     expected_internal="nvidia_drm" ;;
            nvidia-peermem.ko) expected_internal="nvidia_peermem" ;;
            *) return 1 ;;
        esac
        [[ -f "${INSTALL_MOD_DIR}/${name}" && ! -L "${INSTALL_MOD_DIR}/${name}" ]] || return 1
        if [[ "${require_safety_marker}" == "1" && \
              "$(stat -c '%u:%g:%a:%h:%d' -- "${INSTALL_MOD_DIR}/${name}" 2>/dev/null)" != \
                  "0:0:644:1:${parent_dev}" ]]; then
            return 1
        fi
        if [[ "${require_safety_marker}" == "1" && "${name}" == "nvidia.ko" ]] && \
           ! grep -aFq 'cmpunlocker-safety-v3' "${INSTALL_MOD_DIR}/${name}"; then
            return 1
        fi
        internal="$(modinfo -F name -- "${INSTALL_MOD_DIR}/${name}" 2>/dev/null)" || return 1
        module_version="$(modinfo -F version -- "${INSTALL_MOD_DIR}/${name}" 2>/dev/null)" || return 1
        vermagic="$(modinfo -F vermagic -- "${INSTALL_MOD_DIR}/${name}" 2>/dev/null)" || return 1
        srcversion="$(modinfo -F srcversion -- "${INSTALL_MOD_DIR}/${name}" 2>/dev/null)" || return 1
        [[ "${internal}" == "${expected_internal}" && "${module_version}" == "${metadata}" ]] || return 1
        [[ "${vermagic}" == "${KVER}" || "${vermagic}" == "${KVER} "* ]] || return 1
        [[ -n "${srcversion}" ]] || return 1
    done
}

prepare_transaction_root() {
    local root_dev install_dev stale legacy quarantine

    prepare_lifecycle_lock
    prepare_public_module_parent || \
        die "Kernel updates directory must be a root-owned real directory with mode 0755: ${INSTALL_PARENT}"

    prepare_private_namespace "${TRANSACTION_ROOT}" || \
        die "Transaction root must be a root-owned real directory with mode 0700: ${TRANSACTION_ROOT}"
    root_dev="$(stat -c %d "${TRANSACTION_ROOT}")"
    install_dev="$(stat -c %d "${INSTALL_PARENT}")"
    [[ "${root_dev}" == "${install_dev}" ]] || \
        die "Transaction root and module destination are not on the same filesystem"

    prepare_lock_file "${TRANSACTION_ROOT}/build.lock" || \
        die "Unsafe shared build lock object"
    exec {BUILD_LOCK_FD}<>"${TRANSACTION_ROOT}/build.lock"
    flock -n "${BUILD_LOCK_FD}" || die "Another cmpunlocker build is using the shared source/output tree"
    prepare_lock_file "${TRANSACTION_ROOT}/${KVER}.lock" || \
        die "Unsafe per-kernel transaction lock object"
    exec {TX_LOCK_FD}<>"${TRANSACTION_ROOT}/${KVER}.lock"
    flock -n "${TX_LOCK_FD}" || die "Another cmpunlocker install transaction is active for ${KVER}"
    TX_LOCK_HELD=1

    sanitize_transaction_root || \
        die "Unsafe or unrecovered object in ${TRANSACTION_ROOT}"

    if [[ -e "${LEGACY_JOURNAL}" || -L "${LEGACY_JOURNAL}" ]]; then
        ensure_legacy_journal || die "Invalid legacy quarantine journal ${LEGACY_JOURNAL}"
    fi

    # Old releases staged .ko files below updates/, where depmod can index them.
    # Quarantine every known legacy shape outside the kernel tree, rebuild the
    # index, and stop for explicit inspection instead of guessing ownership.
    while IFS= read -r -d '' legacy; do
        [[ -d "${legacy}" && ! -L "${legacy}" ]] || \
            die "Unsafe legacy module transaction object: ${legacy}"
        ensure_legacy_journal || die "Could not publish the legacy quarantine journal"
        quarantine="${TRANSACTION_ROOT}/${KVER}.legacy.$(basename "${legacy}").$$.${RANDOM}"
        atomic_move_noreplace "${legacy}" "${quarantine}" || \
            die "Could not quarantine legacy module transaction ${legacy}"
        LEGACY_QUARANTINED=1
    done < <(find "${INSTALL_PARENT}" -maxdepth 1 -mindepth 1 \
        \( -name '.cmpunlocker.stage.*' -o -name '.cmpunlocker.backup.*' \
           -o -name '.cmpunlocker.failed.*' \) -print0)
    if (( LEGACY_QUARANTINED == 1 && LEGACY_INDEX_REPAIRED == 0 )); then
        sync -f "${INSTALL_PARENT}" || die "Could not persist legacy transaction quarantine"
        sync -f "${TRANSACTION_ROOT}" || die "Could not persist legacy transaction quarantine"
    fi
    if find "${TRANSACTION_ROOT}" -maxdepth 1 -mindepth 1 \
        -name "${KVER}.legacy.*" -print -quit | grep -q .; then
        ensure_legacy_journal || die "Could not publish the legacy quarantine journal"
    fi

    # Reject non-directory/symlink debris; valid stale directories are handled
    # against the durable external journal.
    while IFS= read -r -d '' stale; do
        [[ -d "${stale}" && ! -L "${stale}" ]] || \
            die "Unsafe stale transaction object: ${stale}"
    done < <(find "${TRANSACTION_ROOT}" -maxdepth 1 -mindepth 1 \
        -name "${KVER}.stage.*" -print0)
}

recover_stale_transaction() {
    local stale live_state stage_state stale_id orphan_state
    local stale_dirs=()

    if [[ ! -e "${TRANSACTION_JOURNAL}" && ! -L "${TRANSACTION_JOURNAL}" ]]; then
        # A marked original=0 stage can only be an unpublished first-install
        # set whose journal was durably cleared before cleanup.  Reclaim it
        # independently of any foreign object that may now occupy the live
        # path; that object is validated (and never altered) below.
        mapfile -d '' -t stale_dirs < <(find "${TRANSACTION_ROOT}" -maxdepth 1 \
            -mindepth 1 -type d -name "${KVER}.stage.*" -print0)
        for stale in "${stale_dirs[@]}"; do
            stale_id="${stale##*/}"
            stale_id="${stale_id#${KVER}.stage.}"
            if [[ ! -e "${stale}/${TRANSACTION_MARKER}" && \
                  ! -L "${stale}/${TRANSACTION_MARKER}" ]]; then
                # This is either an interrupted prepublication construction
                # or, after replacement exchange, the old live set.  Validate
                # its closed shape now but defer deletion until live itself is
                # proven marker-free and coherent below.
                validate_unmarked_stage_candidate "${stale}" || {
                    err "Unsafe unmarked transaction stage: ${stale}"
                    return 1
                }
                # Do not delete it yet.  After a replacement exchange, the
                # old live set occupies this same unmarked path.  A lost or
                # damaged journal must never destroy that only rollback copy
                # while the new live set still carries its marker.  The
                # second pass below runs only after live is marker-free and
                # coherent.
                continue
            fi
            if transaction_marker_state "${stale}" "${stale_id}" 0; then
                safe_remove_transaction_dir "${stale}" || return 1
                sync -f "${TRANSACTION_ROOT}" || return 1
            else
                orphan_state=$?
                if (( orphan_state == 2 )); then
                    # A valid original=1 marker is the aborted new set left
                    # after a replacement rollback restored old live and
                    # retired the journal.  Defer it to the generic cleanup,
                    # which first proves that restored live is coherent.
                    transaction_marker_state "${stale}" "${stale_id}" 1 || {
                        err "Invalid orphaned module transaction marker: ${stale}"
                        return 1
                    }
                fi
            fi
        done
        if [[ -e "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" || \
              -L "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" ]]; then
            err "Live module transaction marker exists without its external journal"
            return 1
        fi
        validate_clean_install_dir || {
            err "Existing ${INSTALL_MOD_DIR} is incomplete or has unverifiable identity"
            return 1
        }
        mapfile -d '' -t stale_dirs < <(find "${TRANSACTION_ROOT}" -maxdepth 1 \
            -mindepth 1 -type d -name "${KVER}.stage.*" -print0)
        for stale in "${stale_dirs[@]}"; do
            safe_remove_transaction_dir "${stale}" || return 1
        done
        return 0
    fi

    read_transaction_journal || {
        err "Invalid external module transaction journal ${TRANSACTION_JOURNAL}"
        return 1
    }
    stale="${TRANSACTION_ROOT}/${KVER}.stage.${JOURNAL_ID}"
    warn "Recovering interrupted module transaction ${JOURNAL_ID} (${JOURNAL_PHASE})"
    if transaction_marker_state "${INSTALL_MOD_DIR}" "${JOURNAL_ID}" "${JOURNAL_ORIGINAL}"; then
        live_state=0
    else
        live_state=$?
    fi
    if transaction_marker_state "${stale}" "${JOURNAL_ID}" "${JOURNAL_ORIGINAL}"; then
        stage_state=0
    else
        stage_state=$?
    fi

    # If a first-install stage still exists, atomic publication did not occur.
    # Persist a distinct forward-cleanup decision before deleting anything;
    # every recursive-unlink crash then retries against the exact journal path.
    if [[ "${JOURNAL_ORIGINAL}" == "0" && "${JOURNAL_PHASE}" == "prepared" && \
          ${live_state} -ne 0 && ( -e "${stale}" || -L "${stale}" ) ]]; then
        [[ -d "${stale}" && ! -L "${stale}" ]] || {
            err "Unsafe unpublished first-install transaction object: ${stale}"
            return 1
        }
        [[ ${stage_state} -eq 0 ]] || {
            err "Unpublished first-install transaction has an invalid marker"
            return 1
        }
        write_transaction_journal "${JOURNAL_ID}" 0 discarding || return 1
        JOURNAL_PHASE="discarding"
    fi
    if [[ "${JOURNAL_ORIGINAL}" == "0" && "${JOURNAL_PHASE}" == "discarding" ]]; then
        [[ ${live_state} -ne 0 ]] || {
            err "Discarding journal conflicts with a published live transaction marker"
            return 1
        }
        [[ ${stage_state} -ne 2 ]] || {
            err "Discarding journal has an invalid transaction marker"
            return 1
        }
        if [[ -e "${stale}" || -L "${stale}" ]]; then
            [[ -d "${stale}" && ! -L "${stale}" ]] || {
                err "Unsafe first-install discard object: ${stale}"
                return 1
            }
            safe_remove_transaction_dir "${stale}" || return 1
            sync -f "${TRANSACTION_ROOT}" || return 1
        fi
        remove_transaction_journal || return 1
        TRANSACTION_ACTIVE=0
        STAGING_DIR=""
        ROLLBACK_DIR=""
        validate_clean_install_dir || {
            err "First-install destination has invalid foreign identity; left it untouched"
            return 1
        }
        ok "Discarded an unpublished first-install transaction"
        return 0
    fi

    if [[ "${JOURNAL_PHASE}" == "committing" ]]; then
        [[ -d "${INSTALL_MOD_DIR}" && ! -L "${INSTALL_MOD_DIR}" && ${live_state} -ne 2 ]] || {
            err "Committed module directory is missing or has an invalid marker"
            return 1
        }
        validate_clean_install_dir 1 1 || {
            err "Committed module directory is incomplete or has unverifiable identity"
            return 1
        }
        if [[ -e "${stale}" || -L "${stale}" ]]; then
            [[ -d "${stale}" && ! -L "${stale}" && ${stage_state} -eq 1 ]] || {
                err "Commit cleanup contains an ambiguous transaction directory"
                return 1
            }
        fi
        depmod -a "${KVER}" || return 1
        rebuild_initramfs || return 1
        for i in "${!TARGET_MODULES[@]}"; do
            resolve_installed_module "${MODULE_NAMES[$i]}" \
                "${INSTALL_MOD_DIR}/${TARGET_MODULES[$i]}" >/dev/null || return 1
        done
        sync || return 1
        if [[ ${live_state} -eq 0 ]]; then
            rm -f -- "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" || return 1
            sync -f "${INSTALL_MOD_DIR}" || return 1
        fi
        if [[ -d "${stale}" && ! -L "${stale}" ]]; then
            safe_remove_transaction_dir "${stale}" || return 1
            sync -f "${TRANSACTION_ROOT}" || return 1
        fi
        remove_transaction_journal || return 1
        TRANSACTION_ACTIVE=0
        STAGING_DIR=""
        ROLLBACK_DIR=""
        validate_clean_install_dir 0 1 || return 1
        ok "Completed an interrupted module transaction commit"
        return 0
    fi

    if [[ "${JOURNAL_ORIGINAL}" == "1" ]]; then
        [[ -d "${INSTALL_MOD_DIR}" && ! -L "${INSTALL_MOD_DIR}" && \
           -d "${stale}" && ! -L "${stale}" ]] || {
            err "Replacement transaction does not retain both complete directories"
            return 1
        }
        if [[ "${JOURNAL_PHASE}" == "prepared" && ${live_state} -eq 1 && ${stage_state} -eq 0 ]]; then
            validate_clean_install_dir || return 1
            remove_transaction_journal || return 1
            safe_remove_transaction_dir "${stale}" || return 1
            sync -f "${TRANSACTION_ROOT}" || return 1
            ok "Discarded a transaction that had not been published"
            return 0
        fi
        if [[ "${JOURNAL_PHASE}" == "prepared" ]]; then
            [[ ${live_state} -eq 0 && ${stage_state} -eq 1 ]] || {
                err "Ambiguous prepared replacement transaction; preserving both directories"
                return 1
            }
            write_transaction_journal "${JOURNAL_ID}" 1 restoring || return 1
        fi
        if [[ ${live_state} -eq 0 && ${stage_state} -eq 1 ]]; then
            atomic_exchange_dirs "${INSTALL_MOD_DIR}" "${stale}" || return 1
        elif [[ ${live_state} -ne 1 || ${stage_state} -ne 0 ]]; then
            err "Ambiguous restoring replacement transaction; preserving both directories"
            return 1
        fi
    else
        if [[ "${JOURNAL_PHASE}" == "prepared" ]]; then
            [[ ${live_state} -eq 0 && ${stage_state} -eq 1 && \
               ! -e "${stale}" && ! -L "${stale}" ]] || {
                err "Ambiguous prepared first-install transaction; preserving it"
                return 1
            }
            write_transaction_journal "${JOURNAL_ID}" 0 restoring || return 1
        fi
        if [[ ${live_state} -eq 0 && ! -e "${stale}" && ! -L "${stale}" ]]; then
            atomic_move_noreplace "${INSTALL_MOD_DIR}" "${stale}" || return 1
        elif [[ ! -e "${INSTALL_MOD_DIR}" && ! -L "${INSTALL_MOD_DIR}" && ${stage_state} -eq 0 ]]; then
            :
        else
            err "Ambiguous restoring first-install transaction; preserving it"
            return 1
        fi
    fi

    depmod -a "${KVER}" || return 1
    rebuild_initramfs || return 1
    sync || return 1
    # Commit the restored boot state before deleting the aborted new set.  If
    # cleanup is interrupted, a journal-free stale directory is unambiguously
    # disposable on the next run.
    remove_transaction_journal || return 1
    TRANSACTION_ACTIVE=0
    STAGING_DIR=""
    ROLLBACK_DIR=""
    safe_remove_transaction_dir "${stale}" || return 1
    sync -f "${TRANSACTION_ROOT}" || return 1
    validate_clean_install_dir || return 1
    ok "Recovered the previous on-disk module and initramfs state"

}

rollback_install() {
    warn "Rolling back the on-disk module directory; the running driver remains untouched"
    recover_stale_transaction
}

transaction_exit() {
    local rc=$?
    trap - EXIT
    if (( TX_LOCK_HELD != 1 )); then
        exit "${rc}"
    fi
    if [[ -e "${TRANSACTION_JOURNAL}" || -L "${TRANSACTION_JOURNAL}" ]]; then
        rollback_install || warn "Durable rollback is incomplete; do not power-cycle and retry this script"
    elif (( TRANSACTION_ACTIVE == 1 )); then
        warn "Transaction state was lost; preserving all module directories for inspection"
    elif [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
        safe_remove_transaction_dir "${STAGING_DIR}" || true
    fi
    if (( LEGACY_QUARANTINED == 1 && LEGACY_INDEX_REPAIRED == 0 )); then
        if (( LEGACY_REPAIR_SAFE == 1 && TRANSACTION_ACTIVE == 0 )) && \
           [[ ! -e "${TRANSACTION_JOURNAL}" && ! -L "${TRANSACTION_JOURNAL}" ]] && \
           validate_clean_install_dir; then
            repair_legacy_quarantine_index || \
                warn "Legacy quarantine boot-index repair is incomplete; do not power-cycle"
        else
            warn "Legacy quarantine remains pending because module-tree safety was not proven; do not power-cycle"
        fi
    fi
    exit "${rc}"
}
trap transaction_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

select_initramfs_tool || \
    die "No supported initramfs tool found (need update-initramfs, dracut, or mkinitcpio); nothing was installed"

prepare_transaction_root
recover_stale_transaction || die "Could not recover the previous module transaction; no build was started"
LEGACY_REPAIR_SAFE=1
if (( LEGACY_QUARANTINED == 1 )); then
    repair_legacy_quarantine_index || \
        die "Could not repair depmod/initramfs after legacy module quarantine"
    die "Legacy module transaction files are quarantined under ${TRANSACTION_ROOT}; inspect them before retrying"
fi
prepare_sources

cd "${SRC_DIR}"
info "Building the complete five-module set for kernel ${KVER}..."
find . -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
if [[ "${SKIP_PREP}" -eq 0 ]]; then
    rm -rf src/nvidia/_out src/nvidia-modeset/_out kernel-open/conftest 2>/dev/null || true
else
    info "Reusing compatible object output for relinking"
fi

# Never accept stale final module files as evidence that this make completed.
for name in "${TARGET_MODULES[@]}"; do
    rm -f -- "${SRC_DIR}/kernel-open/${name}"
done

JOBS="$(nproc)"
CC_CMD="gcc"
if command -v ccache &>/dev/null; then
    CC_CMD="ccache gcc"
    info "ccache detected — compiler output will be cached for faster rebuilds"
fi
make -j"${JOBS}" modules SYSSRC="${KSRC}" CC="${CC_CMD}"
if command -v ccache &>/dev/null; then
    ccache -s 2>/dev/null | sed 's/^/  /' || true
fi

BUILT_MODULES=()
for name in "${TARGET_MODULES[@]}"; do
    ko="${SRC_DIR}/kernel-open/${name}"
    validate_module "${ko}" "${name}"
    BUILT_MODULES+=("${ko}")
done
[[ ${#BUILT_MODULES[@]} -eq ${#TARGET_MODULES[@]} ]] || \
    die "Internal error: incomplete target module set"
ok "Built and validated exactly ${#TARGET_MODULES[@]} target modules (version, vermagic, srcversion)"

STAGING_DIR="$(mktemp -d "${TRANSACTION_ROOT}/${KVER}.stage.XXXXXX")"
chown root:root "${STAGING_DIR}"
chmod 0755 "${STAGING_DIR}"
info "Staging the validated module set in ${STAGING_DIR}..."
for i in "${!TARGET_MODULES[@]}"; do
    install -o root -g root -m 0644 \
        "${BUILT_MODULES[$i]}" "${STAGING_DIR}/${TARGET_MODULES[$i]}"
done
printf '%s\n' "${VERSION}" > "${STAGING_DIR}/driver_version"
printf '%s\n' "${PROFILE}" > "${STAGING_DIR}/card_profile"
printf '%s\n' "${UNLOCK_LABEL}" > "${STAGING_DIR}/unlock_geometry"
if [[ -n "${CMPUNLOCKER_GPU_INVENTORY:-}" ]]; then
    printf '%s\n' "${CMPUNLOCKER_GPU_INVENTORY}" > "${STAGING_DIR}/gpu_inventory"
    inventory_count="$(grep -c . "${STAGING_DIR}/gpu_inventory" || true)"
    ok "Staged gpu_inventory (${inventory_count} GPU(s))"
else
    : > "${STAGING_DIR}/gpu_inventory"
fi
chown root:root "${STAGING_DIR}/driver_version" "${STAGING_DIR}/card_profile" \
    "${STAGING_DIR}/unlock_geometry" "${STAGING_DIR}/gpu_inventory"
chmod 0644 "${STAGING_DIR}/driver_version" "${STAGING_DIR}/card_profile" \
    "${STAGING_DIR}/unlock_geometry" "${STAGING_DIR}/gpu_inventory"

if [[ -e "${INSTALL_MOD_DIR}" || -L "${INSTALL_MOD_DIR}" ]]; then
    [[ -d "${INSTALL_MOD_DIR}" && ! -L "${INSTALL_MOD_DIR}" ]] || \
        die "Refusing to replace non-directory or symlink ${INSTALL_MOD_DIR}"
    ORIGINAL_PRESENT=1
fi
transaction_id="${STAGING_DIR##*/}"
transaction_id="${transaction_id#${KVER}.stage.}"
[[ "${transaction_id}" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "Unsafe generated module transaction identifier"
write_transaction_marker "${STAGING_DIR}" "${transaction_id}" "${ORIGINAL_PRESENT}" || \
    die "Could not atomically publish the staged module transaction marker"

mapfile -t STAGED_KO < <(find "${STAGING_DIR}" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sort)
[[ ${#STAGED_KO[@]} -eq ${#TARGET_MODULES[@]} ]] || \
    die "Staging directory contains ${#STAGED_KO[@]} modules; expected ${#TARGET_MODULES[@]}"
for name in "${TARGET_MODULES[@]}"; do
    validate_module "${STAGING_DIR}/${name}" "${name}"
done
ok "Staged module set is complete and internally consistent"

# Persist every staged payload and publish an external journal before the
# directory handoff.  The journal remains outside depmod's kernel tree and is
# authoritative even when the live directory is absent.
sync || die "Could not persist the staged module transaction"
write_transaction_journal "${transaction_id}" "${ORIGINAL_PRESENT}" prepared || \
    die "Could not publish the durable module transaction journal"
TRANSACTION_ACTIVE=1

# Ignore asynchronous termination only across the single renameat2 call and
# its in-memory ownership publication.  SIGKILL/power loss is recovered from
# the already-durable external journal.
trap '' HUP INT TERM
if (( ORIGINAL_PRESENT == 1 )); then
    # renameat2(RENAME_EXCHANGE) is the only permitted replacement path: the
    # destination is never absent and there is no partially published set.
    if ! atomic_exchange_dirs "${STAGING_DIR}" "${INSTALL_MOD_DIR}"; then
        trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
        die "Atomic directory exchange is unavailable; refusing a non-atomic replacement"
    fi
    ROLLBACK_DIR="${STAGING_DIR}"
    STAGING_DIR=""
else
    if ! atomic_move_noreplace "${STAGING_DIR}" "${INSTALL_MOD_DIR}"; then
        trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
        die "First-install destination appeared concurrently; refusing to replace it"
    fi
    STAGING_DIR=""
fi
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
sync -f "${INSTALL_PARENT}" || die "Could not persist the module directory handoff"
sync -f "${TRANSACTION_ROOT}" || die "Could not persist the transaction handoff"
ok "Atomically activated the complete module directory"

for name in "${TARGET_MODULES[@]}"; do
    validate_module "${INSTALL_MOD_DIR}/${name}" "${name}"
done
if ! depmod -a "${KVER}"; then
    die "depmod failed; the previous module directory is being restored"
fi
ok "depmod complete"
if ! rebuild_initramfs; then
    die "initramfs rebuild failed; the previous module directory is being restored"
fi

for i in "${!MODULE_NAMES[@]}"; do
    expected="${INSTALL_MOD_DIR}/${TARGET_MODULES[$i]}"
    if resolved="$(resolve_installed_module "${MODULE_NAMES[$i]}" "${expected}")"; then
        info "${MODULE_NAMES[$i]} resolves exactly to ${resolved}"
        continue
    else
        resolve_rc=$?
    fi
    if (( resolve_rc == 2 )); then
        die "${MODULE_NAMES[$i]} resolves to ${resolved}, not ${expected}"
    fi
    die "modinfo could not resolve ${MODULE_NAMES[$i]} for kernel ${KVER}"
done

# Publish the commit decision only after initramfs and all five canonical
# resolver checks succeed.  Recovery completes, rather than rolls back, this
# phase and repeats the boot-image postconditions before clearing the journal.
sync || die "Could not persist the installed module and initramfs state"
write_transaction_journal "${transaction_id}" "${ORIGINAL_PRESENT}" committing || \
    die "Could not publish the durable module transaction commit decision"
rm -f -- "${INSTALL_MOD_DIR}/${TRANSACTION_MARKER}" || \
    die "Could not remove the module transaction marker"
sync -f "${INSTALL_MOD_DIR}" || die "Could not persist module transaction commit"
if [[ -n "${ROLLBACK_DIR}" && -d "${ROLLBACK_DIR}" ]]; then
    safe_remove_transaction_dir "${ROLLBACK_DIR}" || \
        die "Installed successfully but could not remove ${ROLLBACK_DIR}"
    sync -f "${TRANSACTION_ROOT}" || \
        die "Installed successfully but could not persist rollback cleanup"
    ROLLBACK_DIR=""
fi
remove_transaction_journal || \
    die "Could not durably clear the committed module transaction journal"
TRANSACTION_ACTIVE=0
running_src="$(cat /sys/module/nvidia/srcversion 2>/dev/null || true)"
patched_src="$(modinfo -F srcversion "${INSTALL_MOD_DIR}/nvidia.ko")"

echo ""
ok "Patched modules installed transactionally on disk; the running NVIDIA driver was left untouched"
if [[ -n "${running_src}" ]]; then
    if [[ "${running_src}" == "${patched_src}" ]]; then
        warn "A module with the same srcversion is already loaded, but GPU/WPR state is not safe to reuse"
    else
        info "Running srcversion: ${running_src}"
        info "Installed srcversion: ${patched_src}"
    fi
fi
warn "Do not hot-reload this geometry/WPR-changing driver"
info "Required next step: sudo shutdown -h now, then power the machine on"
echo ""
