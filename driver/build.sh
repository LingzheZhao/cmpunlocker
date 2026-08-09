#!/bin/bash
set -euo pipefail

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
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"

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
[[ -n "${VERSION}" ]] || die "No driver version set (driver/VERSION empty and CMPUNLOCKER_DRIVER_VERSION unset)"
version_supported "${VERSION}" || die "Unsupported driver version '${VERSION}' (supported: ${SUPPORTED_VERSIONS[*]})"
[[ -d "${PATCH_DIR}" ]] || die "Missing patches directory: ${PATCH_DIR}"
[[ -d "${KSRC}" ]] || die "Kernel headers not found at ${KSRC}. Install linux-headers-${KVER} (or kernel-devel)."
command -v python3 &>/dev/null || die "python3 is required to apply the card memory profile"
command -v gcc &>/dev/null || die "gcc is required to build modules and run safety checks"
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

mkdir -p "${BUILD_ROOT}"

if [[ ! -f "${TARBALL}" ]]; then
    info "Downloading open-gpu-kernel-modules ${VERSION}..."
    curl -L --fail -o "${TARBALL}.partial" "${TARBALL_URL}"
    mv "${TARBALL}.partial" "${TARBALL}"
    ok "Downloaded ${TARBALL}"
else
    ok "Using cached tarball ${TARBALL}"
fi

info "Extracting a clean source tree; safety builds never reuse patched sources or objects"
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

python3 - "${MEM_MGR_C}" "${GSP_C}" "${SRC_DIR}" <<'PY'
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

mem_text = mem_mgr.read_text(encoding="utf-8")
guard = mem_text.find("SEC2_DEBUG_PMA_GUARD")
first_registration = mem_text.find("status = memmgrPmaRegisterRegions(")
required_guard_markers = (
    "build=cmpunlocker-safety-v4",
    "GSP_FW_WPR_META_MAGIC",
    "gspFwHeapSize",
    "pRegion->limit >= pWprMeta->gspFwRsvdStart",
    "refusing PMA registration",
)
if guard < 0 or first_registration < 0 or guard >= first_registration:
    raise SystemExit("PMA safety guard is missing or occurs after PMA registration")
if any(marker not in mem_text for marker in required_guard_markers):
    raise SystemExit("PMA safety guard is missing a fail-closed invariant")

gsp_text = gsp_source.read_text(encoding="utf-8")
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
mkdir -p "${INSTALL_MOD_DIR}"
printf '%s\n' "${VERSION}" > "${INSTALL_MOD_DIR}/driver_version"
printf '%s\n' "${PROFILE}" > "${INSTALL_MOD_DIR}/card_profile"
printf '%s\n' "${UNLOCK_LABEL}" > "${INSTALL_MOD_DIR}/unlock_geometry"
if [[ -n "${CMPUNLOCKER_GPU_INVENTORY:-}" ]]; then
    printf '%s\n' "${CMPUNLOCKER_GPU_INVENTORY}" > "${INSTALL_MOD_DIR}/gpu_inventory"
    ok "Wrote gpu_inventory ($(echo "${CMPUNLOCKER_GPU_INVENTORY}" | grep -c . || true) GPU(s))"
else
    : > "${INSTALL_MOD_DIR}/gpu_inventory"
fi

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
grep -aFq 'cmpunlocker-safety-v4' "${CORE_MODULE}" || \
    die "Built nvidia.ko lacks the required cmpunlocker-safety-v4 marker"
ok "Built core module contains the cmpunlocker safety-v4 provenance marker"
if command -v ccache &>/dev/null; then
    ccache -s 2>/dev/null | sed 's/^/  /' || true
fi
info "Installing modules to ${INSTALL_MOD_DIR}..."
mkdir -p "${INSTALL_MOD_DIR}"

mapfile -t KO_FILES < <(find "${SRC_DIR}" -type f \( \
    -name 'nvidia.ko' -o -name 'nvidia-modeset.ko' -o -name 'nvidia-uvm.ko' \
    -o -name 'nvidia-drm.ko' -o -name 'nvidia-peermem.ko' \) \
    ! -path '*/conftest/*' | sort -u)
[[ ${#KO_FILES[@]} -gt 0 ]] || die "No built nvidia*.ko found"

for ko in "${KO_FILES[@]}"; do
    base="$(basename "${ko}")"
    install -m 0644 "${ko}" "${INSTALL_MOD_DIR}/${base}"
    ok "Installed ${base}"
done

depmod -a "${KVER}"
ok "depmod complete"
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

rebuild_initramfs || \
    die "Could not rebuild initramfs; patched modules are not safe to activate"
resolved="$(modprobe -n -v nvidia 2>/dev/null | awk '/insmod/ {print $2; exit}' || true)"
[[ -n "${resolved}" ]] || \
    die "modprobe cannot resolve the installed nvidia module for ${KVER}"
info "modprobe will load: ${resolved}"
[[ "${resolved}" == *"/updates/cmpunlocker/"* ]] || \
    die "modprobe resolves outside updates/cmpunlocker: ${resolved}"
echo ""
ok "Patched modules installed on disk; the running NVIDIA driver was left untouched"
warn "Do not hot-reload or warm-reboot this geometry/WPR-changing driver"
info "Required next step: sudo shutdown -h now, then power the machine on"
echo ""
