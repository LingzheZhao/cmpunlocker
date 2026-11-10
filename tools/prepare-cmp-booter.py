#!/usr/bin/env python3
"""Prepare the opt-in 615.78.08 / CMP 20c2 Booter compatibility experiment."""

import argparse
import hashlib
from pathlib import Path
import re


LEGACY_SHA256 = "49fb8759c238ba32308ed604d5932d5cb2e0f496650063fbc064bbbdd4fdfaf2"
GENERATED = Path("src/nvidia/generated")
GSP = Path("src/nvidia/src/kernel/gpu/gsp")
OLD_ARCHIVE = "g_bindata_kgspGetBinArchiveBooterLoadUcode_GA100.c"
NEW_ARCHIVE = "g_bindata_kgspGetBinArchiveCmpBooterLoadUcode_GA100.c"
MARKER = "CMP_BOOTER_COMPAT"

HELPER = r'''
/* CMP_BOOTER_COMPAT: experimental 610.57.04 privilege Booter for 20c2 only. */
extern const BINDATA_ARCHIVE *kgspGetBinArchiveCmpBooterLoadUcode_GA100(struct KernelGsp *);
NV_STATUS kgspCmpSelectBooter(OBJGPU *, KernelGsp *, NvBool);

NV_STATUS
kgspCmpSelectBooter
(
    OBJGPU *pGpu,
    KernelGsp *pKernelGsp,
    NvBool bLegacy
)
{
    const BINDATA_ARCHIVE *pArchive;
    KernelGspFlcnUcode *pReplacement = NULL;
    NV_STATUS status;

    NV_ASSERT_OR_RETURN(pGpu != NULL && pKernelGsp != NULL, NV_ERR_INVALID_ARGUMENT);
    if (pGpu->idInfo.PCIDeviceID != 0x20c210deU)
        return NV_OK;

    pArchive = bLegacy ? kgspGetBinArchiveCmpBooterLoadUcode_GA100(pKernelGsp)
                       : kgspGetBinArchiveBooterLoadUcode_HAL(pKernelGsp);
    NV_ASSERT_OR_RETURN(pArchive != NULL, NV_ERR_NOT_SUPPORTED);
    status = s_allocateUcodeFromBinArchive(pGpu, pKernelGsp, pArchive, &pReplacement);
    if (status != NV_OK)
    {
        kgspFreeFlcnUcode(pReplacement);
        return status;
    }
    NV_ASSERT_OR_RETURN(pReplacement != NULL, NV_ERR_INVALID_STATE);

    kgspFreeFlcnUcode(pKernelGsp->pBooterLoadUcode);
    pKernelGsp->pBooterLoadUcode = pReplacement;
    NV_PRINTF(LEVEL_ERROR, "CMP_BOOTER_COMPAT: %s Booter selected for 20c2\n",
              bLegacy ? "610.57.04 privilege" : "615.78.08 normal");
    return NV_OK;
}
'''


def replace_once(text, before, after, label):
    if text.count(before) != 1:
        raise ValueError(f"Expected one {label} anchor, found {text.count(before)}")
    return text.replace(before, after, 1)


def plan(source, legacy):
    source = Path(source)
    legacy = Path(legacy).read_bytes()
    if hashlib.sha256(legacy).hexdigest() != LEGACY_SHA256:
        raise ValueError("Legacy archive is not the pinned official 610.57.04 GA100 BooterLoad")
    version = (source / "version.mk").read_text()
    if re.search(r"^NVIDIA_VERSION\s*=\s*615\.78\.08\s*$", version, re.M) is None:
        raise ValueError("This experiment supports only NVIDIA 615.78.08 source")

    index_path = source / GENERATED / "g_bindata.c"
    booter_path = source / GSP / "kernel_gsp_booter.c"
    kernel_path = source / GSP / "kernel_gsp.c"
    new_archive_path = source / GENERATED / NEW_ARCHIVE
    index, booter, kernel = (p.read_text() for p in (index_path, booter_path, kernel_path))
    if new_archive_path.exists() or any(MARKER in s for s in (index, booter, kernel)):
        raise ValueError("CMP Booter experiment is already present; use a fresh source tree")
    if "signatureSize >= SEC2_POSTBL_TIMING_SIGNATURE_SIZE" not in kernel:
        raise ValueError("Payload bounds safety patch is required first")
    if "!_kgspSec2PostblTimingEnabled(pGpu))" not in kernel:
        raise ValueError("CMP bootstrap retry safety patch is required first")

    renamed = legacy.decode().replace("kgspBinArchiveBooterLoadUcode_GA100",
                                      "kgspBinArchiveCmpBooterLoadUcode_GA100")
    renamed = renamed.replace("kgspGetBinArchiveBooterLoadUcode_GA100",
                              "kgspGetBinArchiveCmpBooterLoadUcode_GA100")
    labels = re.findall(r"^    (__idx_kgspBinArchiveBooterLoadUcode_GA100_\w+)\s*=\s*\d+,", index, re.M)
    if len(labels) != 10:
        raise ValueError("Expected the ten GA100 BooterLoad bindata slots")
    all_slots = re.findall(r"^    __idx_\w+\s*=\s*(\d+),", index, re.M)
    first_slot = max(map(int, all_slots)) + 1
    additions = "".join(
        f"    {label.replace('BooterLoadUcode', 'CmpBooterLoadUcode')} = {first_slot + i},\n"
        for i, label in enumerate(labels)
    )
    index = replace_once(index, "    BINDATA_INDEX_END", additions + "\n    BINDATA_INDEX_END", "index end")
    # Append in every expansion phase so the new indices match storage-array order.
    final_include = '#include "g_bindata_spdmGetBinArchiveIndividualL3Certificate_GR102.c"'
    if index.count(final_include) != 4:
        raise ValueError("Unexpected bindata expansion phase layout")
    index = index.replace(final_include, final_include + '\n#include "' + NEW_ARCHIVE + '"')
    old_fingerprint = re.search(r"const NvU64 g_bindata_fingerprint = (0x[0-9a-f]+)ull;", index)
    if old_fingerprint is None:
        raise ValueError("Missing bindata fingerprint")
    fingerprint = hashlib.sha256((old_fingerprint[1] + additions).encode()).hexdigest()[:16]
    index = index[:old_fingerprint.start(1)] + "0x" + fingerprint + index[old_fingerprint.end(1):]
    index = "/* CMP_BOOTER_COMPAT: appended private legacy GA100 archive. */\n" + index

    booter = replace_once(booter, "NV_STATUS\nkgspAllocateBooterLoadUcodeImage_IMPL", HELPER + "\nNV_STATUS\nkgspAllocateBooterLoadUcodeImage_IMPL", "Booter allocator")
    declaration = "NV_STATUS kgspCmpSelectBooter(OBJGPU *pGpu, KernelGsp *pKernelGsp, NvBool bLegacy);\n"
    kernel = replace_once(kernel, "NV_STATUS kgspSec2PostblTimingRefillPayload", "/* CMP_BOOTER_COMPAT */\n" + declaration + "NV_STATUS kgspSec2PostblTimingRefillPayload", "refill declaration")
    kernel = replace_once(kernel, "        NvU32 wpr2Lo = GPU_REG_RD32(pGpu, 0x001fa824U);", "        NV_CHECK_OK_OR_RETURN(LEVEL_ERROR, kgspCmpSelectBooter(pGpu, pKernelGsp, NV_TRUE));\n\n        NvU32 wpr2Lo = GPU_REG_RD32(pGpu, 0x001fa824U);", "privilege pass start")
    kernel = replace_once(kernel, "                if (plmIdx < 4)\n                    return NV_ERR_INVALID_STATE;", "                if (plmIdx < 4)\n                {\n                    NV_CHECK_OK_OR_RETURN(LEVEL_ERROR, kgspCmpSelectBooter(pGpu, pKernelGsp, NV_FALSE));\n                    return NV_ERR_INVALID_STATE;\n                }", "primary PLM failure")
    kernel = replace_once(kernel, "        plmStatus = kgspSec2PostblTimingRebuildStockSignature(pGpu, pKernelGsp);", "        NV_CHECK_OK_OR_RETURN(LEVEL_ERROR, kgspCmpSelectBooter(pGpu, pKernelGsp, NV_FALSE));\n\n        plmStatus = kgspSec2PostblTimingRebuildStockSignature(pGpu, pKernelGsp);", "normal Booter restore")
    return {index_path: index, booter_path: booter, kernel_path: kernel, new_archive_path: renamed}


def prepare(source, legacy):
    changes = plan(source, legacy)
    for path, content in changes.items():
        path.write_text(content)
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("legacy_archive", type=Path)
    args = parser.parse_args()
    try:
        changes = prepare(args.source, args.legacy_archive)
    except (OSError, ValueError) as error:
        parser.exit(1, f"CMP Booter preparation failed: {error}\n")
    print("CMP_BOOTER_COMPAT: prepared 20c2-only 610.57.04 privilege / 615.78.08 normal Booter switching")
    print(f"Prepared {len(changes)} source files; no modules loaded or installed")


if __name__ == "__main__":
    main()
