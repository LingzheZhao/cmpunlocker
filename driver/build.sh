#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/VERSION")
declare -A SOURCE_TARBALL_SHA256=(
    ["610.57.04"]="619d7b5ce1f79c3211afdbf87d02b2174d268b10d005c5b8f994be22299be681"
    ["610.43.03"]="9df87d753cd9c05aa0eedc462af9b35debb549a657136e863282f94c96ee2640"
    ["610.43.02"]="62fbbe29527e30be32cb38b30dfad2e94db1ca87f77a58090e563c7669857e60"
)
DEFAULT_VERSION="${SUPPORTED_VERSIONS[0]:-}"
VERSION="${CMPUNLOCKER_DRIVER_VERSION:-${DEFAULT_VERSION}}"
PATCH_DIR="${SCRIPT_DIR}/patches"
GEOMETRY_TOOL="${SCRIPT_DIR}/../tools/configure-memory-geometry.py"
GEOMETRY_CONSISTENCY_TEST="${SCRIPT_DIR}/../tools/test-memory-geometry-consistency.py"
BUILD_ROOT="${CMPUNLOCKER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
SRC_NAME="open-gpu-kernel-modules-${VERSION}"
SRC_DIR="${BUILD_ROOT}/${SRC_NAME}"
TARBALL="${BUILD_ROOT}/${SRC_NAME}.tar.gz"
TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VERSION}.tar.gz"
KVER="$(uname -r)"
KSRC="/lib/modules/${KVER}/build"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"
DEPMOD_OVERRIDE_FILE="/etc/depmod.d/cmpunlocker.conf"
MODPROBE_OPTIONS_FILE="/etc/modprobe.d/cmp-pcie-gen2.conf"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
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
[[ "${CMPUNLOCKER_INSTALL_GATES_OK:-0}" == "1" ]] || \
    die "driver/build.sh installs kernel modules and must be invoked by the hardware-gated install.sh"
[[ -n "${CMPUNLOCKER_GPU_INVENTORY:-}" ]] || \
    die "Validated GPU inventory is required for a fail-closed module install"
if [[ "${CMPUNLOCKER_LOCK_HELD:-0}" != "1" ]]; then
    command -v flock &>/dev/null || die "flock is required to serialize module changes"
    exec 8>/run/lock/cmpunlocker.lock
    flock -n 8 || die "Another cmpunlocker install/remove operation is already running"
fi
[[ -n "${VERSION}" ]] || die "No driver version set (driver/VERSION empty and CMPUNLOCKER_DRIVER_VERSION unset)"
version_supported "${VERSION}" || die "Unsupported driver version '${VERSION}' (supported: ${SUPPORTED_VERSIONS[*]})"
EXPECTED_TARBALL_SHA256="${SOURCE_TARBALL_SHA256[${VERSION}]-}"
[[ -n "${EXPECTED_TARBALL_SHA256}" ]] || \
    die "No pinned source archive hash for ${VERSION}"
[[ -d "${PATCH_DIR}" ]] || die "Missing patches directory: ${PATCH_DIR}"
[[ -d "${KSRC}" ]] || die "Kernel headers not found at ${KSRC}. Install linux-headers-${KVER} (or kernel-devel)."
command -v python3 &>/dev/null || die "python3 is required to apply the card memory profile"
command -v gcc &>/dev/null || die "gcc is required to build modules and run safety checks"
for required_command in awk curl depmod install mktemp modinfo readlink sha256sum tar; do
    command -v "${required_command}" &>/dev/null || \
        die "${required_command} is required for transactional module installation"
done
[[ -f "${GEOMETRY_TOOL}" ]] || die "Missing memory geometry configurator: ${GEOMETRY_TOOL}"
[[ -f "${GEOMETRY_CONSISTENCY_TEST}" ]] || \
    die "Missing memory geometry consistency test: ${GEOMETRY_CONSISTENCY_TEST}"
python3 "${GEOMETRY_CONSISTENCY_TEST}" || \
    die "Memory geometry constants and consumers have drifted"
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

PROFILE="${CMPUNLOCKER_CARD_PROFILE:-8gb}"
TEN_GB_TARGET="${CMPUNLOCKER_10GB_TARGET:-40gb}"
case "${TEN_GB_TARGET}" in
    40gb|40GB)
        TEN_GB_TARGET="40gb"
        BUILD_FINGERPRINT="cmpunlocker-safety-v5-2082-40g"
        ;;
    80gb|80GB)
        TEN_GB_TARGET="80gb"
        BUILD_FINGERPRINT="cmpunlocker-safety-v5-2082-80g-experimental"
        ;;
    *) die "Unknown CMPUNLOCKER_10GB_TARGET='${TEN_GB_TARGET}' (use 40gb or 80gb)" ;;
esac

case "${PROFILE}" in
    8gb|8GB)
        PROFILE="8gb"
        UNLOCK_LABEL="64GB"
        ;;
    10gb|10GB)
        PROFILE="10gb"
        if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
            UNLOCK_LABEL="80GB-experimental"
        else
            UNLOCK_LABEL="40GB"
        fi
        ;;
    mixed|MIXED)
        PROFILE="mixed"
        if [[ "${TEN_GB_TARGET}" == "80gb" ]]; then
            UNLOCK_LABEL="64GB+80GB-experimental"
        else
            UNLOCK_LABEL="64GB+40GB"
        fi
        ;;
    *)
        die "Unknown CMPUNLOCKER_CARD_PROFILE='${PROFILE}' (use 8gb, 10gb, or mixed)"
        ;;
esac

mkdir -p "${BUILD_ROOT}"

if [[ ! -f "${TARBALL}" ]]; then
    info "Downloading open-gpu-kernel-modules ${VERSION}..."
    curl --proto '=https' --proto-redir '=https' -L --fail \
        -o "${TARBALL}.partial" "${TARBALL_URL}"
    mv "${TARBALL}.partial" "${TARBALL}"
    ok "Downloaded ${TARBALL}"
else
    ok "Using cached tarball ${TARBALL}"
fi
actual_tarball_sha256="$(sha256sum "${TARBALL}" | awk '{print $1}')"
[[ "${actual_tarball_sha256}" == "${EXPECTED_TARBALL_SHA256}" ]] || \
    die "Source archive checksum mismatch for ${VERSION}: got ${actual_tarball_sha256}"
ok "Source archive checksum verified"

info "Extracting a clean source tree; safety builds never reuse patched sources or objects"
rm -rf "${SRC_DIR}"
tar --no-same-owner --no-same-permissions -xzf "${TARBALL}" -C "${BUILD_ROOT}"
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

info "Configuring runtime geometry: 20c2=64GB, 2082=${TEN_GB_TARGET}"
python3 "${GEOMETRY_TOOL}" "${SRC_DIR}" --ten-gb-target "${TEN_GB_TARGET}" || \
    die "Could not configure a consistent 10 GB geometry across boot and allocator paths"
ok "Memory profile ${PROFILE}: unlock_geometry=${UNLOCK_LABEL}"

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
HOSTCC=gcc python3 "${FB_REGION_VALIDATOR_TEST}" "${GSP_C}" || \
    die "Native FB-region validator source/semantic self-test failed"
ok "Native FB-region validator passed compiled boundary-value tests"
HOSTCC=gcc python3 "${PMA_GUARD_TEST}" "${MEM_MGR_C}" || \
    die "Materialized FB/PMA guard source/semantic self-test failed"
ok "Materialized FB/PMA guard passed compiled fail-closed tests"

python3 - "${MEM_MGR_C}" "${GSP_C}" "${SRC_DIR}" "${BUILD_FINGERPRINT}" <<'PY'
import pathlib
import re
import sys


def matching_brace(text, opening):
    depth = 0
    index = opening
    state = "code"
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if char == "/" and following == "/":
                state = "line_comment"
                index += 2
                continue
            if char == "/" and following == "*":
                state = "block_comment"
                index += 2
                continue
            if char == '"':
                state = "string"
            elif char == "'":
                state = "character"
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return index
        elif state == "line_comment":
            if char == "\n":
                state = "code"
        elif state == "block_comment":
            if char == "*" and following == "/":
                state = "code"
                index += 2
                continue
        elif state in {"string", "character"}:
            if char == "\\":
                index += 2
                continue
            if (state == "string" and char == '"') or (
                state == "character" and char == "'"
            ):
                state = "code"
        index += 1
    raise SystemExit("unterminated brace-delimited source block")


def function_text(text, name):
    match = re.search(rf"(?m)^\s*{re.escape(name)}\s*\(", text)
    if match is None:
        raise SystemExit(f"missing function {name}")
    opening = text.find("{", match.end())
    if opening < 0:
        raise SystemExit(f"missing function body for {name}")
    return text[match.start() : matching_brace(text, opening) + 1]


def if_block(text, marker, start=0):
    condition = text.find(marker, start)
    if condition < 0:
        raise SystemExit(f"missing refusal condition: {marker}")
    opening = text.find("{", condition + len(marker))
    if opening < 0:
        raise SystemExit(f"missing refusal body: {marker}")
    closing = matching_brace(text, opening)
    return condition, opening, closing, text[opening : closing + 1]


def mask_c_comments_and_literals(text):
    masked = list(text)
    index = 0
    state = "code"
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if char == "/" and following == "/":
                masked[index] = masked[index + 1] = " "
                state = "line_comment"
                index += 2
                continue
            if char == "/" and following == "*":
                masked[index] = masked[index + 1] = " "
                state = "block_comment"
                index += 2
                continue
            if char == '"':
                masked[index] = " "
                state = "string"
            elif char == "'":
                masked[index] = " "
                state = "character"
        elif state == "line_comment":
            if char == "\n":
                state = "code"
            else:
                masked[index] = " "
        elif state == "block_comment":
            if char == "*" and following == "/":
                masked[index] = masked[index + 1] = " "
                state = "code"
                index += 2
                continue
            if char != "\n":
                masked[index] = " "
        elif state in {"string", "character"}:
            if char == "\\":
                masked[index] = " "
                if index + 1 < len(text) and text[index + 1] != "\n":
                    masked[index + 1] = " "
                index += 2
                continue
            if (state == "string" and char == '"') or (
                state == "character" and char == "'"
            ):
                state = "code"
            if char != "\n":
                masked[index] = " "
        index += 1
    return "".join(masked)


def terminal_top_level_statement(text, opening, closing, pattern):
    code = mask_c_comments_and_literals(text)
    for match in re.finditer(pattern, code[opening + 1 : closing]):
        position = opening + 1 + match.start()
        depth = 1
        paren_depth = 0
        statement_start = opening + 1
        for index in range(opening + 1, position):
            char = code[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 1:
                    statement_start = index + 1
            elif depth == 1:
                if char == "(":
                    paren_depth += 1
                elif char == ")" and paren_depth > 0:
                    paren_depth -= 1
                elif char == ";" and paren_depth == 0:
                    statement_start = index + 1
        statement_end = opening + 1 + match.end()
        prefix = code[opening + 1 : position]
        suffix = code[statement_end:closing]
        top_level_prefix = list(prefix)
        prefix_depth = 1
        for offset, char in enumerate(prefix):
            if char == "{":
                top_level_prefix[offset] = " "
                prefix_depth += 1
            elif char == "}":
                top_level_prefix[offset] = " "
                prefix_depth -= 1
            elif prefix_depth != 1 and char != "\n":
                top_level_prefix[offset] = " "
        prior_transfer = re.search(
            r"\b(?:break|continue|goto|return)\b", "".join(top_level_prefix)
        )
        if (
            depth == 1
            and not code[statement_start:position].strip()
            and not suffix.strip()
            and prior_transfer is None
            and "#" not in prefix
        ):
            return position
    return -1

mem_mgr = pathlib.Path(sys.argv[1])
gsp_source = pathlib.Path(sys.argv[2])
source_root = pathlib.Path(sys.argv[3])
build_fingerprint = sys.argv[4]

mem_text = mem_mgr.read_text(encoding="utf-8")
gsp_text = gsp_source.read_text(encoding="utf-8")
guard = mem_text.find("SEC2_DEBUG_PMA_GUARD")
first_registration = mem_text.find("status = memmgrPmaRegisterRegions(")
required_guard_markers = (
    f"build={build_fingerprint}",
    "GSP_FW_WPR_META_MAGIC",
    "gspFwHeapSize",
    "pRegion->limit >= pWprMeta->gspFwRsvdStart",
    "refusing PMA registration",
)
if guard < 0 or first_registration < 0 or guard >= first_registration:
    raise SystemExit("PMA safety guard is missing or occurs after PMA registration")
if any(marker not in mem_text for marker in required_guard_markers):
    raise SystemExit("PMA safety guard is missing a fail-closed invariant")
if f'"{build_fingerprint}"' not in gsp_text:
    raise SystemExit("GSP build fingerprint does not match the configured geometry")

required_payload_markers = (
    "_kgspSec2PostblTimingEnsurePayloadMemdesc",
    "MEMORY_DESCRIPTOR *pNewSignatureMemdesc = NULL",
    "NvU8 *pNewStockSignatureData = NULL",
    "newStockSignatureSize = pGspFw->signatureSize",
    "SEC2 reset before post-BL payload refill",
    "retaining current payload",
    "SEC2 reset before stock payload rebuild",
    "retaining post-BL payload",
    "signatureSize < SEC2_POSTBL_TIMING_SIGNATURE_SIZE",
    "i + sizeof(NvU32) <= SEC2_POSTBL_TIMING_SIGNATURE_SIZE",
)
if any(marker not in gsp_text for marker in required_payload_markers):
    raise SystemExit("SEC2 retry payload bounds/reallocation guard is missing")
forbidden_external_payload_markers = (
    "SEC2_POSTBL_TIMING_DMEM_PATH",
    "os_open_and_read_file(",
    '"/lib/firmware/nvidia/ga100/gsp/dmem.bin"',
)
if any(marker in gsp_text for marker in forbidden_external_payload_markers):
    raise SystemExit("unverified external SEC2 payload override remains enabled")

signature_start = gsp_text.find("_kgspCreateSignatureMemdesc\n(")
signature_end = gsp_text.find(
    "kgspSec2PostblTimingRebuildStockSignature", signature_start
)
if signature_start < 0 or signature_end < 0:
    raise SystemExit("SEC2 signature creation boundaries are missing")
signature_text = gsp_text[signature_start:signature_end]
backup_alloc = signature_text.find(
    "pNewStockSignatureData = portMemAllocNonPaged"
)
backup_copy = signature_text.find("portMemCopy(pNewStockSignatureData", backup_alloc)
payload_map = signature_text.find("pSignatureVa = memdescMapInternal", backup_copy)
payload_unmap = signature_text.find("memdescUnmapInternal", payload_map)
backup_swap = signature_text.find(
    "pKernelGsp->pStockSignatureData = pNewStockSignatureData", payload_unmap
)
old_backup_free = signature_text.find(
    "portMemFree(pOldStockSignatureData)", backup_swap
)
failure_label = signature_text.find("fail_alloc:", old_backup_free)
temporary_free = signature_text.find(
    "portMemFree(pNewStockSignatureData)", failure_label
)
if not (
    0 <= backup_alloc < backup_copy < payload_map < payload_unmap
    < backup_swap < old_backup_free < failure_label < temporary_free
):
    raise SystemExit(
        "Stock signature backup must be prepared atomically and retained on failure"
    )

ensure_start = gsp_text.find("_kgspSec2PostblTimingEnsurePayloadMemdesc")
ensure_end = gsp_text.find("static void\n_kgspSec2PostblTimingPutU32", ensure_start)
if ensure_start < 0 or ensure_end < 0:
    raise SystemExit("SEC2 retry payload allocator boundaries are missing")
ensure_text = gsp_text[ensure_start:ensure_end]
if "memdescFree(pKernelGsp->pSignatureMemdesc)" not in ensure_text:
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
    raise SystemExit("SEC2 must reset before replacing the retry DMA payload")

stock_start = gsp_text.find("NV_STATUS\nkgspSec2PostblTimingRebuildStockSignature(")
stock_end = gsp_text.find("\nNV_STATUS\n", stock_start + 10)
if stock_start < 0 or stock_end < 0:
    raise SystemExit("SEC2 stock-payload rebuild function boundaries are missing")
stock_text = gsp_text[stock_start:stock_end]
stock_reset = stock_text.find("status = kflcnReset_HAL")
stock_release = stock_text.find("memdescFree(pKernelGsp->pSignatureMemdesc)")
if stock_reset < 0 or stock_release < 0 or stock_reset >= stock_release:
    raise SystemExit("SEC2 must reset before releasing the stock DMA payload")

boot_start = gsp_text.find("_kgspBootGspRm(")
boot_end = gsp_text.find("// Fail early if WPR2 is up", boot_start)
boot_text = gsp_text[boot_start:boot_end]
reset = boot_text.find("status = kflcnReset_HAL")
reject = boot_text.find("if (status != NV_OK)", reset)
retain = boot_text.find("refusing metadata mutation", reject)
return_status = boot_text.find("return status", retain)
if boot_start < 0 or boot_end < 0 or not (0 <= reset < reject < retain < return_status):
    raise SystemExit("Every GSP boot attempt must quiesce SEC2 before metadata mutation")

booter_source = source_root / "src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_booter_tu102.c"
booter_text = booter_source.read_text(encoding="utf-8")
tu102_source = source_root / "src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
tu102_text = tu102_source.read_text(encoding="utf-8")
if "portMemFree(pKernelGsp->pStockSignatureData)" not in tu102_text:
    raise SystemExit("SEC2 stock-signature cleanup is missing")

bootstrap = function_text(tu102_text, "kgspBootstrap_TU102")
_, verification_open, verification_close, verification_failure = if_block(
    bootstrap, "if (featPlm != 0xffffffffU"
)
if terminal_top_level_statement(
    bootstrap,
    verification_open,
    verification_close,
    r"\breturn\s+NV_ERR_RESET_REQUIRED\s*;",
) < 0:
    raise SystemExit("Post-Booter register mismatch is not terminal")
if (
    "kgspExecuteBooterUnloadIfNeeded_HAL" in verification_failure
    or "kflcnReset_HAL" in verification_failure
):
    raise SystemExit("Post-Booter cleanup must wait until API/GPU locks are reacquired")

boot_function = function_text(gsp_text, "_kgspBootGspRm")
retry_gate = re.search(
    r"if\s*\(\s*!_kgspSec2PostblTimingEnabled\(pGpu\)\s*&&\s*"
    r"\(\s*gpuCheckEccCounts_HAL\(pGpu\)\s*\|\|\s*bEccDisabled\s*\)\s*\)",
    boot_function,
)
if retry_gate is None:
    raise SystemExit("Target retry gate must use !target && (ECC-failure || ECC-disabled)")
retry_condition, _, _, retry_block = if_block(
    boot_function, retry_gate.group(0)
)
retry_assignment = boot_function.find("*pbRetry = NV_TRUE;")
if (
    boot_function.count("*pbRetry = NV_TRUE;") != 1
    or retry_assignment < retry_condition
    or "*pbRetry = NV_TRUE;" not in retry_block
):
    raise SystemExit("Target GSP bootstrap failure can still request an automatic retry")

reacquire = boot_function.find("_kgspBootReacquireLocks")
lock_failure_condition, _, _, lock_failure = if_block(
    boot_function, "if (lockStatus != NV_OK)", reacquire
)
if not all(
    marker in lock_failure
    for marker in ("*pbRetry = NV_FALSE;", "bFatalError = NV_TRUE;")
):
    raise SystemExit("Lock-reacquire failure does not stop target retry and retention")
if terminal_top_level_statement(
    lock_failure, 0, len(lock_failure) - 1, r"\breturn\s+lockStatus\s*;"
) < 0:
    raise SystemExit("Lock-reacquire failure does not return its error terminally")

cleanup_condition, _, cleanup_close, cleanup = if_block(
    boot_function,
    "if (_kgspSec2PostblTimingEnabled(pGpu) && status != NV_OK)",
)
if not (0 <= reacquire < lock_failure_condition < cleanup_condition):
    raise SystemExit("Target bootstrap cleanup occurs before API/GPU locks are reacquired")
cleanup_reset = cleanup.find("cleanupStatus = kflcnReset_HAL")
if (
    "cleanupStatus = kflcnReset_HAL(\n"
    "            pGpu, staticCast(pKernelGsp, KernelFalcon));"
    not in cleanup
):
    raise SystemExit("Target cleanup does not reset the GSP Falcon")
reset_failure_condition, _, reset_failure_close, reset_failure = if_block(
    cleanup, "if (cleanupStatus != NV_OK)", cleanup_reset
)
booter_unload = cleanup.find(
    "cleanupStatus = kgspExecuteBooterUnloadIfNeeded_HAL", reset_failure_close
)
if (
    "cleanupStatus = kgspExecuteBooterUnloadIfNeeded_HAL(\n"
    "            pGpu, pKernelGsp, 0ULL);"
    not in cleanup
):
    raise SystemExit("Target cleanup must request a normal Booter Unload")
unload_failure_condition, _, unload_failure_close, unload_failure = if_block(
    cleanup, "if (cleanupStatus != NV_OK)", booter_unload
)
wpr_condition, _, _, wpr_failure = if_block(
    cleanup, "if (kgspIsWpr2Up_HAL", unload_failure_close
)
if not (
    0 <= cleanup_reset < reset_failure_condition < reset_failure_close
    < booter_unload < unload_failure_condition < unload_failure_close < wpr_condition
):
    raise SystemExit("Target cleanup is not ordered GSP reset, Booter Unload, WPR2-down")
for label, branch, required_return in (
    ("GSP reset", reset_failure, r"\breturn\s+cleanupStatus\s*;"),
    ("Booter Unload", unload_failure, r"\breturn\s+cleanupStatus\s*;"),
    ("WPR2-down", wpr_failure, r"\breturn\s+NV_ERR_RESET_REQUIRED\s*;"),
):
    if (
        "bFatalError = NV_TRUE;" not in branch
        or terminal_top_level_statement(
            branch, 0, len(branch) - 1, required_return
        )
        < 0
    ):
        raise SystemExit(f"{label} cleanup failure can continue or free DMA resources")
if "*pbRetry = NV_FALSE;" not in cleanup:
    raise SystemExit("Target bootstrap cleanup does not suppress retry")
if re.fullmatch(
    r"\s*return\s+status\s*;\s*}\s*",
    boot_function[cleanup_close + 1 :],
) is None:
    raise SystemExit("Target cleanup must propagate the original bootstrap failure")

def require_retention(branch, label):
    required = ("_kgspStopLogPolling", "nvlogDeregisterFlushCb")
    positions = [branch.find(marker) for marker in required]
    terminal_return = terminal_top_level_statement(
        branch, 0, len(branch) - 1, r"\breturn\s*;"
    )
    if (
        positions != sorted(positions)
        or any(position < 0 for position in positions)
        or terminal_return < positions[-1]
    ):
        raise SystemExit(f"Destructor {label} branch does not retain DMA resources")


destruct = function_text(gsp_text, "kgspDestruct_IMPL")
target_condition, _, target_close, target_destruct = if_block(
    destruct, "if (_kgspSec2PostblTimingEnabled(pGpu))"
)
first_free = destruct.find("kgspFreeFlcnUcode")
gsp_reset = target_destruct.find("resetStatus = kflcnReset_HAL")
if (
    "resetStatus = kflcnReset_HAL(\n"
    "            pGpu, staticCast(pKernelGsp, KernelFalcon));"
    not in target_destruct
):
    raise SystemExit("Destructor does not reset the GSP Falcon before release")
_, _, gsp_failure_close, gsp_failure = if_block(
    target_destruct, "if (resetStatus != NV_OK)", gsp_reset
)
sec2_missing_condition, _, sec2_missing_close, sec2_missing = if_block(
    target_destruct, "if (pKernelSec2 == NULL)", gsp_failure_close
)
sec2_reset = target_destruct.find("resetStatus = kflcnReset_HAL", sec2_missing_close)
if (
    "resetStatus = kflcnReset_HAL(pGpu, staticCast(pKernelSec2, KernelFalcon));"
    not in target_destruct
):
    raise SystemExit("Destructor does not reset the SEC2 Falcon before release")
_, _, sec2_failure_close, sec2_failure = if_block(
    target_destruct, "if (resetStatus != NV_OK)", sec2_reset
)
wpr_condition, _, _, destruct_wpr = if_block(
    target_destruct, "if (kgspIsWpr2Up_HAL", sec2_failure_close
)
if not (
    0 <= target_condition < target_close < first_free
    and 0 <= gsp_reset < gsp_failure_close < sec2_missing_condition
    < sec2_missing_close < sec2_reset < sec2_failure_close < wpr_condition
):
    raise SystemExit("Destructor must stop GSP and SEC2 before WPR2/free decisions")
for label, branch in (
    ("GSP reset", gsp_failure),
    ("missing SEC2", sec2_missing),
    ("SEC2 reset", sec2_failure),
    ("WPR2 active", destruct_wpr),
):
    require_retention(branch, label)

booter_load = function_text(booter_text, "kgspExecuteBooterLoad_TU102")
load_execute = booter_load.find("status = s_executeBooterUcode_TU102")
_, _, _, load_failure = if_block(
    booter_load, "if (status != NV_OK)", load_execute
)
load_post_reset = load_failure.find(
    "resetStatus = kflcnReset_HAL(pGpu, staticCast(pKernelSec2, KernelFalcon));"
)
_, _, load_reset_close, load_reset_failure = if_block(
    load_failure, "if (resetStatus != NV_OK)", load_post_reset
)
load_return = terminal_top_level_statement(
    load_failure, 0, len(load_failure) - 1, r"\breturn\s+status\s*;"
)
if not (
    0 <= load_post_reset < load_reset_close < load_return
    and "return resetStatus;" in load_reset_failure
):
    raise SystemExit("Booter Load failure does not quiesce SEC2 before returning")
if terminal_top_level_statement(
    load_reset_failure,
    0,
    len(load_reset_failure) - 1,
    r"\breturn\s+resetStatus\s*;",
) < 0:
    raise SystemExit("Booter Load reset failure is not terminal")

booter_unload_function = function_text(
    booter_text, "kgspExecuteBooterUnloadIfNeeded_TU102"
)
unload_execute = booter_unload_function.find("status = s_executeBooterUcode_TU102")
pre_reset = booter_unload_function.find("resetStatus = kflcnReset_HAL")
if (
    booter_unload_function.count(
        "resetStatus = kflcnReset_HAL(pGpu, staticCast(pKernelSec2, KernelFalcon));"
    )
    != 2
):
    raise SystemExit("Booter Unload must reset SEC2 before execution and after failure")
_, _, pre_reset_close, pre_reset_failure = if_block(
    booter_unload_function, "if (resetStatus != NV_OK)", pre_reset
)
_, _, _, execute_failure = if_block(
    booter_unload_function, "if (status != NV_OK)", unload_execute
)
post_reset = execute_failure.find("resetStatus = kflcnReset_HAL")
_, _, post_reset_close, post_reset_failure = if_block(
    execute_failure, "if (resetStatus != NV_OK)", post_reset
)
if not (
    0 <= pre_reset < pre_reset_close < unload_execute
    and 0 <= post_reset < post_reset_close
    and terminal_top_level_statement(
        pre_reset_failure,
        0,
        len(pre_reset_failure) - 1,
        r"\breturn\s+resetStatus\s*;",
    )
    >= 0
    and terminal_top_level_statement(
        post_reset_failure,
        0,
        len(post_reset_failure) - 1,
        r"\breturn\s+resetStatus\s*;",
    )
    >= 0
    and terminal_top_level_statement(
        execute_failure,
        0,
        len(execute_failure) - 1,
        r"\breturn\s+status\s*;",
    )
    >= 0
):
    raise SystemExit("Booter Unload does not strictly reset SEC2 around failure")

bus_source = (
    source_root
    / "src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm107.c"
)
bus_text = bus_source.read_text(encoding="utf-8")
if (
    bus_text.count("_kbusCmpDefaultBar0Offset(pGpu, pMemoryManager)") != 3
    or "(pMemoryManager->Ram.fbAddrSpaceSizeMb << 20) - DRF_SIZE(NV_PRAMIN)"
    in bus_text
    or "nativeFbSizeMb = 0x2000ULL" not in bus_text
    or "nativeFbSizeMb = 0x2800ULL" not in bus_text
):
    raise SystemExit("BAR0 PRAMIN clamp is not consistent across load/resume/destroy")

for tree in (source_root / "src" / "nvidia", source_root / "kernel-open"):
    for path in tree.rglob("*"):
        if path.suffix not in {".c", ".h"}:
            continue
        candidate = path.read_text(encoding="utf-8", errors="replace")
        if "memmgrSec2DebugLateExtendHighPmaRegion" in candidate or "SEC2_DEBUG_LATE_PMA" in candidate:
            raise SystemExit(f"unsafe late-PMA source remains in {path}")
PY
ok "PMA and payload invariants are ordered correctly; unsafe late-PMA source is absent"

cd "${SRC_DIR}"
info "Building modules for kernel ${KVER}..."
find . -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
rm -rf src/nvidia/_out src/nvidia-modeset/_out kernel-open/conftest 2>/dev/null || true

JOBS="$(nproc)"
CC_CMD="gcc"
if command -v ccache &>/dev/null; then
    CC_CMD="ccache gcc"
    info "ccache detected — compiler output will be cached for faster rebuilds"
fi
make -j"${JOBS}" modules SYSSRC="${KSRC}" CC="${CC_CMD}"
ok "Modules built"
CORE_MODULE="${SRC_DIR}/kernel-open/nvidia.ko"
[[ -f "${CORE_MODULE}" ]] || die "Missing canonical built core module: ${CORE_MODULE}"
grep -aFq "${BUILD_FINGERPRINT}" "${CORE_MODULE}" || \
    die "Built nvidia.ko lacks the required ${BUILD_FINGERPRINT} marker"
if grep -aEoq 'cmpunlocker-safety-v5-2082-(40g|80g-experimental)' "${CORE_MODULE}"; then
    marker_count="$(grep -aEo 'cmpunlocker-safety-v5-2082-(40g|80g-experimental)' \
        "${CORE_MODULE}" | sort -u | wc -l)"
    [[ "${marker_count}" -eq 1 ]] || \
        die "Built nvidia.ko contains conflicting cmpunlocker geometry markers"
else
    die "Built nvidia.ko contains no recognized cmpunlocker geometry marker"
fi
ok "Built core module contains geometry-bound marker ${BUILD_FINGERPRINT}"
if command -v ccache &>/dev/null; then
    ccache -s 2>/dev/null | sed 's/^/  /' || true
fi
rebuild_initramfs() {
    if command -v update-initramfs &>/dev/null; then
        info "Rebuilding initramfs (update-initramfs)..."
        update-initramfs -u -k "${KVER}" || return 1
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v dracut &>/dev/null; then
        info "Rebuilding initramfs (dracut)..."
        dracut --force --kver "${KVER}" || return 1
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v mkinitcpio &>/dev/null; then
        info "Rebuilding initramfs (mkinitcpio)..."
        mkinitcpio -P || return 1
        ok "initramfs rebuilt"
        return 0
    fi
    warn "No initramfs tool found — rebuild manually before rebooting"
    return 1
}

MODULE_NAMES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm nvidia_peermem)
MODULE_FILES=(nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko)
for i in "${!MODULE_FILES[@]}"; do
    built_module="${SRC_DIR}/kernel-open/${MODULE_FILES[$i]}"
    [[ -f "${built_module}" ]] || die "Missing canonical built module: ${built_module}"
    vermagic="$(modinfo -F vermagic "${built_module}" 2>/dev/null || true)"
    [[ "${vermagic%% *}" == "${KVER}" ]] || \
        die "${MODULE_FILES[$i]} vermagic '${vermagic}' does not match ${KVER}"
done
ok "All five canonical modules have matching vermagic"

verify_module_resolution() {
    local i module_name module_file resolved expected
    for i in "${!MODULE_NAMES[@]}"; do
        module_name="${MODULE_NAMES[$i]}"
        module_file="${MODULE_FILES[$i]}"
        resolved="$(modinfo -k "${KVER}" -n "${module_name}" 2>/dev/null || true)"
        [[ -n "${resolved}" ]] || \
            die "modinfo cannot resolve ${module_name} for ${KVER}"
        resolved="$(readlink -e -- "${resolved}" 2>/dev/null || true)"
        expected="$(readlink -e -- "${INSTALL_MOD_DIR}/${module_file}" 2>/dev/null || true)"
        [[ -n "${resolved}" && -n "${expected}" && "${resolved}" == "${expected}" ]] || \
            die "${module_name} resolves to '${resolved:-?}', expected '${expected:-?}'"
        info "${module_name} resolves to ${resolved}"
    done
}

# Keep transaction copies outside /lib/modules/$KVER.  depmod recursively scans
# that tree, so even a harmless-looking *.new/rollback directory can become a
# selectable duplicate after an interrupted install.
INSTALL_STAGE="/lib/modules/.cmpunlocker-stage-${KVER}.$$"
INSTALL_BACKUP="/lib/modules/.cmpunlocker-rollback-${KVER}.$$"
TRANSACTION_STATE="$(mktemp -d /var/tmp/cmpunlocker-install.XXXXXX)" || \
    die "Could not create installation transaction state"
transaction_active=0
had_install_dir=0
had_depmod_override=0
had_modprobe_options=0

rollback_install() {
    local rollback_rc=0
    set +e
    warn "Installation did not complete; restoring the previous module selection"
    if [[ -d "${INSTALL_BACKUP}" ]]; then
        rm -rf -- "${INSTALL_MOD_DIR}" || rollback_rc=1
        if (( rollback_rc == 0 )); then
            mv -- "${INSTALL_BACKUP}" "${INSTALL_MOD_DIR}" || rollback_rc=1
        fi
    elif (( had_install_dir == 0 )) && \
         [[ ! -d "${INSTALL_STAGE}" && -d "${INSTALL_MOD_DIR}" ]]; then
        rm -rf -- "${INSTALL_MOD_DIR}" || rollback_rc=1
    fi
    if (( had_depmod_override == 1 )); then
        install -m 0644 "${TRANSACTION_STATE}/depmod.conf" \
            "${DEPMOD_OVERRIDE_FILE}" || rollback_rc=1
    else
        rm -f -- "${DEPMOD_OVERRIDE_FILE}" || rollback_rc=1
    fi
    if (( had_modprobe_options == 1 )); then
        install -m 0644 "${TRANSACTION_STATE}/modprobe.conf" \
            "${MODPROBE_OPTIONS_FILE}" || rollback_rc=1
    else
        rm -f -- "${MODPROBE_OPTIONS_FILE}" || rollback_rc=1
    fi
    depmod -a "${KVER}" || rollback_rc=1
    rebuild_initramfs || rollback_rc=1
    if (( rollback_rc == 0 )); then
        warn "Previous on-disk NVIDIA module selection restored; running modules were untouched"
    else
        warn "Automatic rollback was incomplete; rebuild depmod/initramfs before rebooting"
    fi
    set -e
    return "${rollback_rc}"
}

finish_transaction() {
    local rc=$?
    local rollback_succeeded=1
    trap - EXIT INT TERM
    if (( transaction_active == 1 )); then
        if ! rollback_install; then
            rollback_succeeded=0
        fi
    fi
    rm -rf -- "${INSTALL_STAGE}"
    if (( transaction_active == 0 || rollback_succeeded == 1 )); then
        rm -rf -- "${INSTALL_BACKUP}" "${TRANSACTION_STATE}"
    else
        warn "Preserved rollback evidence: ${INSTALL_BACKUP} and ${TRANSACTION_STATE}"
    fi
    exit "${rc}"
}
trap finish_transaction EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rm -rf -- "${INSTALL_STAGE}" "${INSTALL_BACKUP}"
mkdir -p "${INSTALL_STAGE}"
for i in "${!MODULE_FILES[@]}"; do
    install -m 0644 "${SRC_DIR}/kernel-open/${MODULE_FILES[$i]}" \
        "${INSTALL_STAGE}/${MODULE_FILES[$i]}"
done
printf '%s\n' "${VERSION}" > "${INSTALL_STAGE}/driver_version"
printf '%s\n' "${PROFILE}" > "${INSTALL_STAGE}/card_profile"
printf '%s\n' "${TEN_GB_TARGET}" > "${INSTALL_STAGE}/ten_gb_target"
printf '%s\n' "${UNLOCK_LABEL}" > "${INSTALL_STAGE}/unlock_geometry"
printf '%s\n' "${BUILD_FINGERPRINT}" > "${INSTALL_STAGE}/build_fingerprint"
if [[ -n "${CMPUNLOCKER_GPU_INVENTORY:-}" ]]; then
    printf '%s\n' "${CMPUNLOCKER_GPU_INVENTORY}" > "${INSTALL_STAGE}/gpu_inventory"
else
    : > "${INSTALL_STAGE}/gpu_inventory"
fi
(
    cd "${INSTALL_STAGE}"
    sha256sum "${MODULE_FILES[@]}" driver_version card_profile ten_gb_target \
        unlock_geometry build_fingerprint gpu_inventory > modules.sha256
    sha256sum -c modules.sha256 >/dev/null
)
ok "Staged and checksummed all patched modules and installation metadata"

mkdir -p "$(dirname "${DEPMOD_OVERRIDE_FILE}")" \
         "$(dirname "${MODPROBE_OPTIONS_FILE}")"
if [[ -e "${DEPMOD_OVERRIDE_FILE}" ]]; then
    cp -a -- "${DEPMOD_OVERRIDE_FILE}" "${TRANSACTION_STATE}/depmod.conf"
    had_depmod_override=1
fi
if [[ -e "${MODPROBE_OPTIONS_FILE}" ]]; then
    cp -a -- "${MODPROBE_OPTIONS_FILE}" "${TRANSACTION_STATE}/modprobe.conf"
    had_modprobe_options=1
fi
printf '%s\n' \
    'override nvidia * updates/cmpunlocker' \
    'override nvidia_modeset * updates/cmpunlocker' \
    'override nvidia_uvm * updates/cmpunlocker' \
    'override nvidia_drm * updates/cmpunlocker' \
    'override nvidia_peermem * updates/cmpunlocker' \
    > "${TRANSACTION_STATE}/depmod.conf.new"
printf '%s\n' \
    'options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"' \
    > "${TRANSACTION_STATE}/modprobe.conf.new"

transaction_active=1
if [[ -d "${INSTALL_MOD_DIR}" ]]; then
    had_install_dir=1
    mv -- "${INSTALL_MOD_DIR}" "${INSTALL_BACKUP}"
fi
mv -- "${INSTALL_STAGE}" "${INSTALL_MOD_DIR}"
install -m 0644 "${TRANSACTION_STATE}/depmod.conf.new" "${DEPMOD_OVERRIDE_FILE}"
install -m 0644 "${TRANSACTION_STATE}/modprobe.conf.new" "${MODPROBE_OPTIONS_FILE}"

depmod -a "${KVER}"
ok "depmod complete with an exact cmpunlocker override"
verify_module_resolution
rebuild_initramfs || \
    die "Could not rebuild initramfs; rolling back the patched module selection"
verify_module_resolution

transaction_active=0
rm -rf -- "${INSTALL_BACKUP}" "${TRANSACTION_STATE}"
trap - EXIT INT TERM
ok "Installed modules, depmod override, and initramfs committed successfully"
echo ""
ok "Patched modules installed on disk; the running NVIDIA driver was left untouched"
warn "Do not hot-reload or warm-reboot this geometry/WPR-changing driver"
info "Required next step: sudo shutdown -h now, then power the machine on"
echo ""
