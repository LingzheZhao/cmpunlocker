#!/usr/bin/env python3
"""Compile and exercise cmpunlocker's FB-region validators from patched source.

The validator implementations are extracted from the final kernel_gsp.c with a
brace-aware scanner.  A small userspace C harness supplies only the NVIDIA
types used by those functions, so the tests execute the same C bodies that will
be compiled into the kernel module.  The source tree itself is never modified.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


PURE_VALIDATOR = "_kgspSec2PostblTimingValidateFbRegionTable"
LAYOUT_VALIDATOR = "_kgspSec2PostblTimingValidateFbLayout"
ENABLE_GATE = "_kgspSec2PostblTimingEnabled"
TEN_GB_FB_40 = "0x0000000A00000000ULL"
TEN_GB_FB_80 = "0x0000001400000000ULL"


def die(message: str) -> "NoReturn":
    raise SystemExit(f"FB-region validator self-test: {message}")


def find_matching_brace(text: str, opening: int) -> int:
    """Return the matching closing brace, ignoring comments and literals."""

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

    die("unterminated function body")


def mask_c_comments_and_literals(text: str) -> str:
    """Replace comments and literals with spaces while preserving offsets."""

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


def extract_function(text: str, name: str, return_type: str = "NV_STATUS") -> str:
    """Extract a static function definition with the requested return type."""

    name_match = re.search(rf"(?m)^\s*{re.escape(name)}\s*\(", text)
    if name_match is None:
        die(f"missing {name} definition")

    return_types = list(
        re.finditer(
            rf"(?m)^(?:static\s+)?{re.escape(return_type)}\s*$",
            text[: name_match.start()],
        )
    )
    if not return_types:
        die(f"cannot locate {return_type} return type for {name}")
    start = return_types[-1].start()
    opening = text.find("{", name_match.end())
    if opening < 0:
        die(f"cannot locate opening brace for {name}")
    closing = find_matching_brace(text, opening)
    return text[start : closing + 1]


def validate_source_shape(
    text: str,
    gate: str,
    pure: str,
    wrapper: str,
    expected_fingerprint: str,
) -> None:
    source_code = mask_c_comments_and_literals(text)
    required_source_markers = (
        "SEC2_DEBUG_FB_LAYOUT: validated",
        "SEC2_DEBUG_FB_LAYOUT: rejected",
    )
    missing = [marker for marker in required_source_markers if marker not in text]
    if missing:
        die(f"missing source marker: {missing[0]}")

    for macro, value_pattern, expected in (
        (
            "SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID",
            r"0x20C2(?:U)?",
            "0x20C2",
        ),
        (
            "SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID",
            r"0x2082(?:U)?",
            "0x2082",
        ),
        (
            "SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_SUBDEVICE_ID",
            r"0x155710DE(?:U)?",
            "0x155710DE",
        ),
        (
            "SEC2_POSTBL_TIMING_FB_REGION_ALIGNMENT",
            r"0x00010000ULL",
            "0x00010000ULL",
        ),
        (
            "SEC2_POSTBL_TIMING_STOCK_8GB_FB_BYTES",
            r"0x0000000200000000ULL",
            "0x0000000200000000ULL",
        ),
        (
            "SEC2_POSTBL_TIMING_STOCK_10GB_FB_BYTES",
            r"0x0000000280000000ULL",
            "0x0000000280000000ULL",
        ),
        (
            "SEC2_POSTBL_TIMING_MAX_NATIVE_NONPUBLIC_BYTES",
            r"0x0000000080000000ULL",
            "0x0000000080000000ULL",
        ),
        (
            "SEC2_POSTBL_TIMING_FB_REGION_SETUP_HEADROOM",
            r"6U",
            "6U",
        ),
    ):
        any_definition = re.compile(
            rf"(?m)^[ \t]*#[ \t]*define[ \t]+{re.escape(macro)}(?:[ \t]|$)"
        )
        exact_definition = re.compile(
            rf"(?im)^[ \t]*#[ \t]*define[ \t]+{re.escape(macro)}[ \t]+"
            rf"{value_pattern}[ \t]*$"
        )
        undefinition = re.compile(
            rf"(?m)^[ \t]*#[ \t]*undef[ \t]+{re.escape(macro)}(?:[ \t]|$)"
        )
        if (
            len(any_definition.findall(source_code)) != 1
            or exact_definition.search(source_code) is None
            or undefinition.search(source_code) is not None
        ):
            die(f"{macro} must have one active definition equal to {expected}")

    fingerprint = "SEC2_POSTBL_TIMING_BUILD_FINGERPRINT"
    fingerprint_definitions = list(
        re.finditer(
            rf"(?m)^[ \t]*#[ \t]*define[ \t]+{fingerprint}(?:[ \t]|$)",
            source_code,
        )
    )
    fingerprint_undefinition = re.search(
        rf"(?m)^[ \t]*#[ \t]*undef[ \t]+{fingerprint}(?:[ \t]|$)",
        source_code,
    )
    fingerprint_is_exact = False
    if len(fingerprint_definitions) == 1:
        line_start = fingerprint_definitions[0].start()
        line_end = text.find("\n", line_start)
        if line_end < 0:
            line_end = len(text)
        fingerprint_is_exact = re.fullmatch(
            rf"[ \t]*#[ \t]*define[ \t]+{fingerprint}[ \t]+"
            rf'"{re.escape(expected_fingerprint)}"[ \t]*',
            text[line_start:line_end],
        ) is not None
    if (
        not fingerprint_is_exact
        or fingerprint_undefinition is not None
    ):
        die(
            f'{fingerprint} must have one active definition equal to '
            f'"{expected_fingerprint}"'
        )

    gate_code = mask_c_comments_and_literals(gate)
    exact_gate = re.compile(
        rf"\s*static\s+NvBool\s+{re.escape(ENABLE_GATE)}\s*"
        r"\(\s*OBJGPU\s*\*\s*pGpu\s*\)\s*\{\s*"
        r"NvU32\s+devId\s*=\s*pGpu\s*->\s*idInfo\.PCIDeviceID\s*"
        r">>\s*16\s*;\s*NvU32\s+subDeviceId\s*=\s*"
        r"pGpu\s*->\s*idInfo\.PCISubDeviceID\s*;\s*"
        r"return\s*\(\s*devId\s*==\s*"
        r"SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID\s*\|\|\s*"
        r"\(\s*devId\s*==\s*SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID\s*"
        r"&&\s*subDeviceId\s*==\s*"
        r"SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_SUBDEVICE_ID\s*\)\s*"
        r"\)\s*;\s*\}\s*",
        re.DOTALL,
    )
    if exact_gate.fullmatch(gate_code) is None:
        die("target-device gate must contain exactly the 20c2/2082 allowlist")

    required_pure_markers = (
        "const NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS *pParams",
        "pRegion->base != expectedBase",
        "nextBase > metaFbSize",
        "pRegion->reserved != regionBytes",
        "pRegion->bProtected",
        "pRegion->regionTag != NV2080_FB_REGION_TAG_NONE",
        "pRegion->limit >= protectedStart",
        "MAX_FB_REGIONS -",
        "SEC2_POSTBL_TIMING_FB_REGION_SETUP_HEADROOM",
        "pTopRegion->base != protectedStart",
        "pTopRegion->reserved != protectedBytes",
        "pTopRegion->bProtected",
        "pTopRegion->regionTag != NV2080_FB_REGION_TAG_GSP_CARVEOUT",
        "publicBytes < minPublicBytes",
    )
    missing = [marker for marker in required_pure_markers if marker not in pure]
    if missing:
        die(f"pure validator is missing invariant: {missing[0]}")

    # A const declaration is not enough if a later cast or alias writes the
    # table.  Reject direct field writes and common bulk-copy mutation forms.
    direct_write = re.compile(
        r"\b(?:pParams|pRegion|pTopRegion)\s*->\s*\w+\s*"
        r"(?:=(?!=)|\+=|-=|\*=|/=|\+\+|--)"
    )
    if direct_write.search(pure):
        die("pure validator writes its input table")
    if re.search(r"\b(?:memcpy|memmove|portMemCopy|portMemSet)\s*\(", pure):
        die("pure validator contains a bulk-memory mutation")

    required_wrapper_markers = (
        "metaFbSize != expectedFbSize",
        "IS_VIRTUAL(pGpu)",
        "pWprMeta == NULL",
        "pKernelGsp->pWprMetaDescriptor == NULL",
        "pGSCI->fb_length != expectedFbSize",
        "protectedStart <= stockFbSize",
        "protectedStart != pWprMeta->nonWprHeapOffset",
        "NV_U64_MAX - pWprMeta->nonWprHeapSize",
        "pWprMeta->nonWprHeapOffset + pWprMeta->nonWprHeapSize !=",
        PURE_VALIDATOR,
        "status=safe build=%s",
        "return NV_ERR_INVALID_STATE",
    )
    missing = [marker for marker in required_wrapper_markers if marker not in wrapper]
    if missing:
        die(f"layout validator is missing invariant: {missing[0]}")

    init_rm = extract_function(text, "kgspInitRm_IMPL")
    init_code = mask_c_comments_and_literals(init_rm)
    rpc = init_code.find("NV_RM_RPC_GET_GSP_STATIC_INFO")
    rpc_check = init_code.find("if (status != NV_OK)", rpc)
    enabled_if = init_code.find(f"if ({ENABLE_GATE}(pGpu))", rpc_check)
    enabled_open = init_code.find("{", enabled_if + len(ENABLE_GATE))
    if enabled_if < 0 or enabled_open < 0:
        die("layout validation is missing its target-device gate")
    enabled_close = find_matching_brace(init_code, enabled_open)
    call = init_code.find(f"status = {LAYOUT_VALIDATOR}", rpc_check)
    call_check = init_code.find("if (status != NV_OK)", call)
    call_goto = init_code.find("goto done", call_check)
    trace = init_code.find("kgspInitGspTraceCrashBuffer", call_goto)
    guarded_validation = re.compile(
        rf"\s*status\s*=\s*{re.escape(LAYOUT_VALIDATOR)}\s*"
        r"\(\s*pGpu\s*,\s*pKernelGsp\s*\)\s*;\s*"
        r"if\s*\(\s*status\s*!=\s*NV_OK\s*\)\s*"
        r"(?:\{\s*goto\s+done\s*;\s*\}|goto\s+done\s*;)\s*",
        re.DOTALL,
    )
    if not (
        0
        <= rpc
        < rpc_check
        < enabled_if
        < enabled_open
        < call
        < call_check
        < call_goto
        < enabled_close
        < trace
    ):
        die(
            "layout validation call, failure check, and refusal must remain "
            "inside the target-device gate after GET_GSP_STATIC_INFO and "
            "before trace/MemoryManager consumers"
        )
    if guarded_validation.fullmatch(init_code[enabled_open + 1 : enabled_close]) is None:
        die(
            "target-device gate must directly call the layout validator and "
            "send its exact failure branch to done"
        )
    if init_code.count(f"status = {LAYOUT_VALIDATOR}") != 1:
        die("kgspInitRm_IMPL must contain exactly one layout-validator call")

    forbidden_init_mutations = (
        "pGSCI->fb_length =",
        "pLastRegion->limit =",
        "pLastRegion->reserved =",
    )
    for marker in forbidden_init_mutations:
        if marker in init_rm:
            die(f"forbidden native-table repair remains: {marker}")


def detect_ten_gb_target(wrapper: str, text: str) -> str:
    match = re.search(
        r"NvU64 expectedFbSize\s*=\s*"
        r"\(devId == SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID\)\s*"
        r"\?\s*0x0000001000000000ULL\s*:\s*"
        r"(0x(?:0000000A00000000|0000001400000000)ULL)\s*;",
        wrapper,
        re.DOTALL,
    )
    if match is None:
        die("10 GB target framebuffer expression is missing or unsupported")

    target = match.group(1)
    if target == TEN_GB_FB_40:
        cfg1 = "0x02669000U"
        lmr = "0x0000028AU"
    elif target == TEN_GB_FB_80:
        cfg1 = "0x02779000U"
        lmr = "0x0000028BU"
    else:  # pragma: no cover - constrained by the expression above
        die(f"unsupported 10 GB target {target}")

    pair = re.compile(
        r"else\s*\{\s*cfg1Value\s*=\s*"
        + re.escape(cfg1)
        + r"\s*;\s*lmrValue\s*=\s*"
        + re.escape(lmr)
        + r"\s*;\s*\}",
        re.DOTALL,
    )
    if pair.search(mask_c_comments_and_literals(text)) is None:
        die(f"10 GB target {target} is inconsistent with its CFG1/LMR pair")
    return target


def fingerprint_for_target(target: str) -> str:
    if target == TEN_GB_FB_40:
        return "cmpunlocker-safety-v5-2082-40g"
    if target == TEN_GB_FB_80:
        return "cmpunlocker-safety-v5-2082-80g-experimental"
    die(f"unsupported 10 GB target {target}")


HARNESS_PREFIX = r'''
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t NvBool;
typedef uint8_t NvU8;
typedef uint32_t NvU32;
typedef uint64_t NvU64;
typedef int NV_STATUS;

#define NV_FALSE 0U
#define NV_TRUE 1U
#define NV_OK 0
#define NV_ERR_INVALID_STATE 0x40
#define NV_U64_MAX UINT64_MAX
#define LEVEL_ERROR 0

#define NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MEM_TYPES 18U
#define NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MAX_ENTRIES 16U
#define MAX_FB_REGIONS 16U
#define ct_assert(condition) _Static_assert((condition), #condition)
#define NV2080_FB_REGION_TAG_NONE 0U
#define NV2080_FB_REGION_TAG_GSP_CARVEOUT 1U

typedef struct NV2080_CTRL_CMD_FB_GET_FB_REGION_FB_REGION_INFO {
    NvU64 base;
    NvU64 limit;
    NvU64 reserved;
    NvU32 performance;
    NvBool supportCompressed;
    NvBool supportISO;
    NvBool bProtected;
    NvBool blackList[NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MEM_TYPES];
    NvU32 regionTag;
} NV2080_CTRL_CMD_FB_GET_FB_REGION_FB_REGION_INFO;

typedef struct NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS {
    NvU32 numFBRegions;
    NV2080_CTRL_CMD_FB_GET_FB_REGION_FB_REGION_INFO
        fbRegion[NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MAX_ENTRIES];
} NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS;

typedef struct GspStaticConfigInfo {
    NvU64 fb_length;
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS fbRegionInfoParams;
} GspStaticConfigInfo;

typedef struct GspFwWprMeta {
    NvU64 magic;
    NvU64 revision;
    NvU64 sysmemAddrOfRadix3Elf;
    NvU64 sizeOfRadix3Elf;
    NvU64 sysmemAddrOfBootloader;
    NvU64 sizeOfBootloader;
    NvU64 bootloaderCodeOffset;
    NvU64 bootloaderDataOffset;
    NvU64 bootloaderManifestOffset;
    NvU64 bootloaderUnion[2];
    NvU64 gspFwRsvdStart;
    NvU64 nonWprHeapOffset;
    NvU64 nonWprHeapSize;
    NvU64 gspFwWprStart;
    NvU64 gspFwHeapOffset;
    NvU64 gspFwHeapSize;
    NvU64 gspFwOffset;
    NvU64 bootBinOffset;
    NvU64 frtsOffset;
    NvU64 frtsSize;
    NvU64 gspFwWprEnd;
    NvU64 fbSize;
    NvU64 vgaWorkspaceOffset;
    NvU64 vgaWorkspaceSize;
    NvU64 bootCount;
    NvU8 partitionUnion[32];
    NvU8 gspFwHeapVfPartitionCount;
    NvU8 flags;
    NvU8 padding[2];
    NvU32 pmuReservedSize;
    NvU64 verified;
} GspFwWprMeta;

typedef struct MEMORY_DESCRIPTOR {
    NvU64 size;
} MEMORY_DESCRIPTOR;

typedef struct OBJGPU {
    struct {
        NvU32 PCIDeviceID;
        NvU32 PCISubDeviceID;
    } idInfo;
    NvBool bVirtual;
} OBJGPU;

#define IS_VIRTUAL(pGpu) ((pGpu)->bVirtual)

typedef struct KernelGsp {
    GspStaticConfigInfo gspStaticInfo;
    GspFwWprMeta *pWprMeta;
    MEMORY_DESCRIPTOR *pWprMetaDescriptor;
} KernelGsp;

#define SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID 0x20C2U
#define SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID 0x2082U
#define SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_SUBDEVICE_ID 0x155710DEU
#define SEC2_POSTBL_TIMING_FB_REGION_ALIGNMENT 0x00010000ULL
#define SEC2_POSTBL_TIMING_STOCK_8GB_FB_BYTES 0x0000000200000000ULL
#define SEC2_POSTBL_TIMING_STOCK_10GB_FB_BYTES 0x0000000280000000ULL
#define SEC2_POSTBL_TIMING_MAX_NATIVE_NONPUBLIC_BYTES 0x0000000080000000ULL
#define SEC2_POSTBL_TIMING_FB_REGION_SETUP_HEADROOM 6U
#define SEC2_POSTBL_TIMING_BUILD_FINGERPRINT TEST_BUILD_FINGERPRINT
#define GSP_FW_WPR_META_MAGIC 0xdc3aae21371a60b3ULL
#define GSP_FW_WPR_META_REVISION 1ULL

_Static_assert(sizeof(GspFwWprMeta) == 256, "GspFwWprMeta size mismatch");
_Static_assert(offsetof(GspFwWprMeta, gspFwRsvdStart) == 88,
               "GspFwWprMeta layout mismatch");
_Static_assert(offsetof(GspFwWprMeta, fbSize) == 176,
               "GspFwWprMeta fbSize offset mismatch");

static NvU64 memdescGetSize(const MEMORY_DESCRIPTOR *pDesc)
{
    return pDesc->size;
}

static void testPrintf(const char *format, ...)
{
    (void)format;
}

#define NV_PRINTF(level, ...) do { (void)(level); testPrintf(__VA_ARGS__); } while (0)
'''


HARNESS_SUFFIX = r'''
#define ALIGNMENT 0x00010000ULL
#define FB_64G 0x0000001000000000ULL
#define FB_40G 0x0000000A00000000ULL
#define FB_80G 0x0000001400000000ULL
#define STOCK_8G 0x0000000200000000ULL
#define STOCK_10G 0x0000000280000000ULL
#define RSVD_64G 0x0000000FF7200000ULL
#define RSVD_40G 0x00000009F7200000ULL
#define RSVD_80G 0x00000013F7200000ULL
#define PROTECTED_BYTES 0x0000000008E00000ULL
#define MIN_PUBLIC_64G 0x0000000F80000000ULL
#define MIN_PUBLIC_40G 0x0000000980000000ULL
#define MIN_PUBLIC_80G 0x0000001380000000ULL
#define TARGET_10G_FB TEST_10GB_TARGET_FB
#define TARGET_10G_RSVD (TARGET_10G_FB - PROTECTED_BYTES)
#define TARGET_10G_MIN_PUBLIC (TARGET_10G_FB - 0x0000000080000000ULL)
#define LOW_RESERVED_END 0x0000000010080000ULL
#define SENTINEL_PUBLIC 0xA55AA55AA55AA55AULL
#define SENTINEL_RESERVED 0x5AA55AA55AA55AA5ULL

typedef struct TestContext {
    OBJGPU gpu;
    KernelGsp kgsp;
    GspFwWprMeta meta;
    MEMORY_DESCRIPTOR descriptor;
} TestContext;

static unsigned int failures;

static void expectGate(
    const char *name,
    NvU32 devId,
    NvU32 subDeviceId,
    NvBool expected)
{
    OBJGPU gpu = {0};
    NvBool actual;

    gpu.idInfo.PCIDeviceID = devId << 16;
    gpu.idInfo.PCISubDeviceID = subDeviceId;
    actual = _kgspSec2PostblTimingEnabled(&gpu);
    if (actual != expected)
    {
        fprintf(stderr, "%s: enable gate returned %u, expected %u\n",
                name, actual, expected);
        failures++;
    }
}

static void addRegion(
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS *pParams,
    NvU64 base,
    NvU64 end,
    NvU64 reserved,
    NvBool bProtected)
{
    NV2080_CTRL_CMD_FB_GET_FB_REGION_FB_REGION_INFO *pRegion;

    if (pParams->numFBRegions >= NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MAX_ENTRIES ||
        end == 0)
    {
        fprintf(stderr, "invalid test-vector construction\n");
        exit(2);
    }
    pRegion = &pParams->fbRegion[pParams->numFBRegions++];
    pRegion->base = base;
    pRegion->limit = end - 1;
    pRegion->reserved = reserved;
    pRegion->bProtected = bProtected;
}

static void addTopCarveout(
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS *pParams,
    NvU64 protectedStart,
    NvU64 fbSize)
{
    addRegion(pParams, protectedStart, fbSize, fbSize - protectedStart, NV_FALSE);
    pParams->fbRegion[pParams->numFBRegions - 1].regionTag =
        NV2080_FB_REGION_TAG_GSP_CARVEOUT;
}

static NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS nativeTable(
    NvU64 fbSize,
    NvU64 protectedStart)
{
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS params = {0};

    addRegion(&params, 0, LOW_RESERVED_END, LOW_RESERVED_END, NV_FALSE);
    addRegion(&params, LOW_RESERVED_END, protectedStart, 0, NV_FALSE);
    addTopCarveout(&params, protectedStart, fbSize);
    return params;
}

static void expectTable(
    const char *name,
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS *pParams,
    NvU64 fbLength,
    NvU64 metaFbSize,
    NvU64 protectedStart,
    NvU64 minPublicBytes,
    NvBool expectSuccess,
    NvU64 expectedPublic,
    NvU64 expectedReserved)
{
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS before = *pParams;
    NvU64 publicBytes = SENTINEL_PUBLIC;
    NvU64 reservedBytes = SENTINEL_RESERVED;
    NV_STATUS status = _kgspSec2PostblTimingValidateFbRegionTable(
        pParams, fbLength, metaFbSize, protectedStart, minPublicBytes,
        &publicBytes, &reservedBytes);
    NvBool succeeded = status == NV_OK;

    if (succeeded != expectSuccess)
    {
        fprintf(stderr, "%s: status=0x%x, expected %s\n", name, status,
                expectSuccess ? "success" : "failure");
        failures++;
    }
    if (memcmp(&before, pParams, sizeof(before)) != 0)
    {
        fprintf(stderr, "%s: validator mutated the region table\n", name);
        failures++;
    }
    if (expectSuccess &&
        (publicBytes != expectedPublic || reservedBytes != expectedReserved))
    {
        fprintf(stderr,
                "%s: bytes public=0x%llx reserved=0x%llx, expected 0x%llx/0x%llx\n",
                name, (unsigned long long)publicBytes,
                (unsigned long long)reservedBytes,
                (unsigned long long)expectedPublic,
                (unsigned long long)expectedReserved);
        failures++;
    }
    if (!expectSuccess &&
        (publicBytes != SENTINEL_PUBLIC || reservedBytes != SENTINEL_RESERVED))
    {
        fprintf(stderr, "%s: failure path published partial byte counts\n", name);
        failures++;
    }
}

static TestContext validContext(NvU32 devId, NvU64 fbSize, NvU64 protectedStart)
{
    TestContext context = {0};

    context.gpu.idInfo.PCIDeviceID = devId << 16;
    context.gpu.idInfo.PCISubDeviceID = 0x155710DEU;
    context.meta.magic = GSP_FW_WPR_META_MAGIC;
    context.meta.revision = GSP_FW_WPR_META_REVISION;
    context.meta.fbSize = fbSize;
    context.meta.gspFwRsvdStart = protectedStart;
    context.meta.nonWprHeapOffset = protectedStart;
    context.meta.nonWprHeapSize = 0x00100000ULL;
    context.meta.gspFwWprStart = protectedStart + 0x00100000ULL;
    context.meta.gspFwHeapOffset = protectedStart + 0x00200000ULL;
    context.meta.gspFwHeapSize = 0x06E00000ULL;
    context.meta.gspFwWprEnd = fbSize - 0x00100000ULL;
    context.descriptor.size = sizeof(context.meta);
    context.kgsp.gspStaticInfo.fb_length = fbSize;
    context.kgsp.gspStaticInfo.fbRegionInfoParams = nativeTable(fbSize, protectedStart);
    context.kgsp.pWprMeta = &context.meta;
    context.kgsp.pWprMetaDescriptor = &context.descriptor;
    return context;
}

static void expectLayoutWithMetadata(
    const char *name,
    TestContext *pContext,
    NvBool expectSuccess,
    NvBool supplyMetadata,
    NvBool supplyDescriptor)
{
    GspStaticConfigInfo staticBefore;
    GspFwWprMeta metaBefore;
    MEMORY_DESCRIPTOR descriptorBefore;
    NV_STATUS status;
    NvBool succeeded;

    /* validContext() returns by value, so repair only the pointers under test. */
    pContext->kgsp.pWprMeta = supplyMetadata ? &pContext->meta : NULL;
    pContext->kgsp.pWprMetaDescriptor =
        supplyDescriptor ? &pContext->descriptor : NULL;
    staticBefore = pContext->kgsp.gspStaticInfo;
    metaBefore = pContext->meta;
    descriptorBefore = pContext->descriptor;
    status = _kgspSec2PostblTimingValidateFbLayout(
        &pContext->gpu, &pContext->kgsp);
    succeeded = status == NV_OK;

    if (succeeded != expectSuccess)
    {
        fprintf(stderr, "%s: wrapper status=0x%x, expected %s\n", name, status,
                expectSuccess ? "success" : "failure");
        failures++;
    }
    if (memcmp(&staticBefore, &pContext->kgsp.gspStaticInfo,
               sizeof(staticBefore)) != 0 ||
        memcmp(&metaBefore, &pContext->meta, sizeof(metaBefore)) != 0 ||
        memcmp(&descriptorBefore, &pContext->descriptor,
               sizeof(descriptorBefore)) != 0)
    {
        fprintf(stderr, "%s: wrapper mutated firmware-owned inputs\n", name);
        failures++;
    }
}

static void expectLayout(const char *name, TestContext *pContext, NvBool expectSuccess)
{
    expectLayoutWithMetadata(
        name, pContext, expectSuccess, NV_TRUE, NV_TRUE);
}

int main(void)
{
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS params;
    TestContext context;
    NvU64 i;

    expectGate("20c2-enabled", 0x20C2U, 0U, NV_TRUE);
    expectGate("2082-enabled", 0x2082U, 0x155710DEU, NV_TRUE);
    expectGate("2082-wrong-subdevice", 0x2082U, 0x155810DEU, NV_FALSE);
    expectGate("other-device-disabled", 0x1234U, 0U, NV_FALSE);

    params = nativeTable(FB_64G, RSVD_64G);
    expectTable("20c2-native-crosses-8GiB", &params, FB_64G, FB_64G,
                RSVD_64G, MIN_PUBLIC_64G, NV_TRUE,
                0x0000000FE7180000ULL, 0x0000000018E80000ULL);

    params = nativeTable(FB_40G, RSVD_40G);
    expectTable("2082-native-40GiB", &params, FB_40G, FB_40G,
                RSVD_40G, MIN_PUBLIC_40G, NV_TRUE,
                0x00000009E7180000ULL, 0x0000000018E80000ULL);

    params = nativeTable(FB_80G, RSVD_80G);
    expectTable("2082-native-80GiB", &params, FB_80G, FB_80G,
                RSVD_80G, MIN_PUBLIC_80G, NV_TRUE,
                0x00000013E7180000ULL, 0x0000000018E80000ULL);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, STOCK_8G, 0, NV_FALSE);
    addRegion(&params, STOCK_8G, RSVD_64G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("public-candidate-starts-at-8GiB", &params, FB_64G, FB_64G,
                RSVD_64G, MIN_PUBLIC_64G, NV_TRUE,
                RSVD_64G, PROTECTED_BYTES);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, STOCK_10G, 0, NV_FALSE);
    addRegion(&params, STOCK_10G, RSVD_40G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_40G, FB_40G);
    expectTable("2082-public-starts-at-10GiB", &params, FB_40G, FB_40G,
                RSVD_40G, MIN_PUBLIC_40G, NV_TRUE,
                RSVD_40G, PROTECTED_BYTES);

    memset(&params, 0, sizeof(params));
    for (i = 0; i < 8; i++)
        addRegion(&params, i << 32, (i + 1) << 32, 0, NV_FALSE);
    addRegion(&params, 8ULL << 32, RSVD_64G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("native-validator-ten-region-upper-bound", &params,
                FB_64G, FB_64G,
                RSVD_64G, MIN_PUBLIC_64G, NV_TRUE,
                RSVD_64G, PROTECTED_BYTES);

    memset(&params, 0, sizeof(params));
    for (i = 0; i < 9; i++)
        addRegion(&params, i << 32, (i + 1) << 32, 0, NV_FALSE);
    addRegion(&params, 9ULL << 32, RSVD_64G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("eleven-regions-exhaust-headroom", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, ALIGNMENT, 1, NV_FALSE);
    addRegion(&params, ALIGNMENT, RSVD_64G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("partial-low-reservation-rejected", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, MIN_PUBLIC_64G, 0, NV_FALSE);
    addRegion(&params, MIN_PUBLIC_64G, RSVD_64G,
              RSVD_64G - MIN_PUBLIC_64G, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("public-floor-exact", &params, FB_64G, FB_64G,
                RSVD_64G, MIN_PUBLIC_64G, NV_TRUE,
                MIN_PUBLIC_64G, 0x0000000080000000ULL);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, MIN_PUBLIC_64G - ALIGNMENT, 0, NV_FALSE);
    addRegion(&params, MIN_PUBLIC_64G - ALIGNMENT, RSVD_64G,
              RSVD_64G - (MIN_PUBLIC_64G - ALIGNMENT), NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("public-floor-minus-64KiB", &params, FB_64G, FB_64G,
                RSVD_64G, MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, STOCK_8G, 0, NV_FALSE);
    addRegion(&params, STOCK_8G, RSVD_64G, RSVD_64G - STOCK_8G, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("fake-64GiB-only-stock-public", &params, FB_64G, FB_64G,
                RSVD_64G, MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.fbRegion[1].bProtected = NV_TRUE;
    expectTable("protected-region-cannot-satisfy-public-floor", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.fbRegion[2].reserved = 0;
    params.fbRegion[2].regionTag = NV2080_FB_REGION_TAG_NONE;
    expectTable("public-region-crosses-protectedStart", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, STOCK_8G, 0, NV_FALSE);
    addRegion(&params, STOCK_8G + ALIGNMENT, RSVD_64G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("gap", &params, FB_64G, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, STOCK_8G, 0, NV_FALSE);
    addRegion(&params, STOCK_8G - ALIGNMENT, RSVD_64G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("overlap", &params, FB_64G, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, ALIGNMENT + 1, 0, NV_FALSE);
    addRegion(&params, ALIGNMENT + 1, RSVD_64G, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G, FB_64G);
    expectTable("unaligned-contiguous", &params, FB_64G, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    params.numFBRegions = 1;
    params.fbRegion[0].base = 0;
    params.fbRegion[0].limit = NV_U64_MAX;
    expectTable("inclusive-limit-addition-overflow", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.fbRegion[2].limit -= ALIGNMENT;
    expectTable("does-not-cover-fbSize", &params, FB_64G, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, RSVD_64G - ALIGNMENT, 0, NV_FALSE);
    addTopCarveout(&params, RSVD_64G - ALIGNMENT, FB_64G);
    expectTable("top-carveout-starts-too-low", &params, FB_64G, FB_64G,
                RSVD_64G, MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    memset(&params, 0, sizeof(params));
    addRegion(&params, 0, RSVD_64G, 0, NV_FALSE);
    addRegion(&params, RSVD_64G, RSVD_64G + ALIGNMENT, ALIGNMENT, NV_TRUE);
    addTopCarveout(&params, RSVD_64G + ALIGNMENT, FB_64G);
    expectTable("top-carveout-split", &params, FB_64G, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.fbRegion[2].reserved = PROTECTED_BYTES - ALIGNMENT;
    expectTable("top-carveout-reserved-not-exact", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.fbRegion[2].regionTag = NV2080_FB_REGION_TAG_NONE;
    expectTable("top-carveout-tag-not-exact", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.fbRegion[2].bProtected = NV_TRUE;
    expectTable("top-carveout-must-not-be-PMA-protected", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.fbRegion[0].reserved = LOW_RESERVED_END + 1;
    expectTable("reserved-size-exceeds-region", &params,
                FB_64G, FB_64G, RSVD_64G, MIN_PUBLIC_64G,
                NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.numFBRegions = 0;
    expectTable("zero-regions", &params, FB_64G, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    params.numFBRegions = NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MAX_ENTRIES + 1;
    expectTable("too-many-regions", &params, FB_64G, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    expectTable("fbLength-metaFbSize-mismatch", &params,
                FB_64G - ALIGNMENT, FB_64G, RSVD_64G,
                MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    params = nativeTable(FB_64G, RSVD_64G);
    expectTable("unaligned-protectedStart", &params, FB_64G, FB_64G,
                RSVD_64G + 1, MIN_PUBLIC_64G, NV_FALSE, 0, 0);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    expectLayout("20c2-wrapper-native", &context, NV_TRUE);

    context = validContext(0x2082U, TARGET_10G_FB, TARGET_10G_RSVD);
    expectLayout("2082-wrapper-configured-target", &context, NV_TRUE);

    context = validContext(0x2082U, TARGET_10G_FB, TARGET_10G_RSVD);
    context.gpu.idInfo.PCISubDeviceID = 0x155810DEU;
    expectLayout("2082-wrapper-wrong-subdevice", &context, NV_FALSE);

    context = validContext(
        0x2082U,
        TARGET_10G_FB == FB_40G ? FB_80G : FB_40G,
        TARGET_10G_FB == FB_40G ? RSVD_80G : RSVD_40G);
    expectLayout("2082-wrapper-rejects-other-target", &context, NV_FALSE);

    context = validContext(0x20C3U, FB_64G, RSVD_64G);
    expectLayout("unsupported-device", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.gpu.bVirtual = NV_TRUE;
    expectLayout("virtual-target-device", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.magic ^= 1ULL;
    expectLayout("metadata-magic-mismatch", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.revision++;
    expectLayout("metadata-revision-mismatch", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.descriptor.size = sizeof(context.meta) - 1;
    expectLayout("metadata-descriptor-truncated", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    expectLayoutWithMetadata(
        "missing-WPR-metadata", &context, NV_FALSE, NV_FALSE, NV_TRUE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    expectLayoutWithMetadata(
        "missing-WPR-metadata-descriptor", &context, NV_FALSE, NV_TRUE, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.fbSize = FB_64G - ALIGNMENT;
    expectLayout("metadata-fb-size-mismatch", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwRsvdStart = STOCK_8G;
    expectLayout("protected-boundary-at-stock-capacity", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwRsvdStart++;
    expectLayout("protected-boundary-unaligned", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.nonWprHeapOffset -= ALIGNMENT;
    expectLayout("rsvdStart-nonWprHeapOffset-mismatch", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.nonWprHeapSize -= ALIGNMENT;
    expectLayout("nonWpr-heap-does-not-fill-to-WPR", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.nonWprHeapSize = 0;
    expectLayout("nonWpr-heap-empty", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwWprStart++;
    expectLayout("WPR-start-unaligned", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwWprEnd = context.meta.gspFwWprStart;
    expectLayout("WPR-range-empty", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwWprEnd = FB_64G + ALIGNMENT;
    expectLayout("WPR-end-exceeds-FB", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwHeapSize = 0;
    expectLayout("WPR-heap-empty", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwHeapOffset = context.meta.gspFwWprStart - ALIGNMENT;
    expectLayout("WPR-heap-starts-before-WPR", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.meta.gspFwHeapSize = context.meta.gspFwWprEnd -
                                 context.meta.gspFwHeapOffset + ALIGNMENT;
    expectLayout("WPR-heap-exceeds-WPR", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.kgsp.gspStaticInfo.fb_length = STOCK_8G;
    expectLayout("fake-fbLength", &context, NV_FALSE);

    context = validContext(0x20C2U, FB_64G, RSVD_64G);
    context.kgsp.gspStaticInfo.fbRegionInfoParams.fbRegion[1].reserved =
        RSVD_64G - LOW_RESERVED_END;
    expectLayout("wrapper-insufficient-publicBytes", &context, NV_FALSE);

    if (failures != 0)
    {
        fprintf(stderr, "%u FB-region validator self-test(s) failed\n", failures);
        return 1;
    }

    puts("FB-region validator self-test: PASS");
    return 0;
}
'''


def compiler_command() -> list[str]:
    configured = os.environ.get("HOSTCC") or os.environ.get("CC") or "cc"
    command = shlex.split(configured)
    if not command:
        die("empty HOSTCC/CC command")
    if shutil.which(command[0]) is None:
        die(f"host C compiler not found: {command[0]}")
    return command


def run_tests(source: Path) -> None:
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        die(f"cannot read {source}: {error}")

    gate = extract_function(text, ENABLE_GATE, "NvBool")
    pure = extract_function(text, PURE_VALIDATOR)
    wrapper = extract_function(text, LAYOUT_VALIDATOR)
    ten_gb_target = detect_ten_gb_target(wrapper, text)
    fingerprint = fingerprint_for_target(ten_gb_target)
    validate_source_shape(text, gate, pure, wrapper, fingerprint)

    harness = (
        HARNESS_PREFIX
        + f"\n#define TEST_10GB_TARGET_FB {ten_gb_target}\n"
        + f'#define TEST_BUILD_FINGERPRINT "{fingerprint}"\n'
        + "\n"
        + gate
        + "\n\n"
        + pure
        + "\n\n"
        + wrapper
        + "\n"
        + HARNESS_SUFFIX
    )
    with tempfile.TemporaryDirectory(prefix="cmpunlocker-fb-layout-test.") as temp:
        temp_dir = Path(temp)
        harness_path = temp_dir / "fb-region-validator-test.c"
        executable = temp_dir / "fb-region-validator-test"
        harness_path.write_text(harness, encoding="utf-8")

        compile_result = subprocess.run(
            compiler_command()
            + [
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-O2",
                str(harness_path),
                "-o",
                str(executable),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if compile_result.returncode != 0:
            details = (compile_result.stdout + compile_result.stderr).strip()
            die(f"host compilation failed:\n{details}")

        test_result = subprocess.run(
            [str(executable)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        output = (test_result.stdout + test_result.stderr).strip()
        if test_result.returncode != 0:
            die(f"compiled C vectors failed:\n{output}")
        print(output)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compile and test FB-region validators from patched kernel_gsp.c"
    )
    parser.add_argument("source", type=Path, help="final patched kernel_gsp.c")
    args = parser.parse_args()
    run_tests(args.source.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
