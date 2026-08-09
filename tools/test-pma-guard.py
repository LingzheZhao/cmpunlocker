#!/usr/bin/env python3
"""Compile and exercise cmpunlocker's final materialized FB/PMA guard.

The target guard is brace-aware extracted from the final patched mem_mgr.c,
including the standard PMA registration and its post-registration accounting
check.  A userspace C harness supplies only the NVIDIA types and calls used by
that exact source segment.  This provides executable fail-closed regression
coverage without modifying the driver source tree.
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
from typing import NoReturn


FUNCTION_NAME = "memmgrCreateHeap_IMPL"
PRE_GUARD_ANCHOR = "NvU32 devId = pGpu->idInfo.PCIDeviceID >> 16;"
REGISTRATION_ANCHOR = "status = memmgrPmaRegisterRegions("
POST_GUARD_ANCHOR = "if (devId == 0x20C2 || devId == 0x2082)"
ENCLOSING_GUARD_ANCHOR = (
    "if ((memmgrIsPmaInitialized(pMemoryManager)) && "
    "(pMemoryManager->pHeap->bHasFbRegions))"
)


def die(message: str) -> NoReturn:
    raise SystemExit(f"PMA-guard self-test: {message}")


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

    die("unterminated brace-delimited source block")


def extract_function(text: str, name: str) -> str:
    """Brace-aware extraction of a named C function definition."""

    name_match = re.search(rf"(?m)^\s*{re.escape(name)}\s*$", text)
    if name_match is None:
        die(f"missing {name} definition")

    return_types = list(re.finditer(r"(?m)^NV_STATUS\s*$", text[: name_match.start()]))
    if not return_types:
        die(f"cannot locate return type for {name}")
    start = return_types[-1].start()
    opening = text.find("{", name_match.end())
    if opening < 0:
        die(f"cannot locate opening brace for {name}")
    closing = find_matching_brace(text, opening)
    return text[start : closing + 1]


def extract_guard_segment(function: str) -> str:
    """Extract pre-guard, standard registration, and post-accounting guard."""

    start = function.find(PRE_GUARD_ANCHOR)
    registration = function.find(REGISTRATION_ANCHOR, start)
    registration_assert = function.find(
        "NV_ASSERT_OR_RETURN(status == NV_OK, status);", registration
    )
    post_if = function.find(POST_GUARD_ANCHOR, registration_assert)
    if min(start, registration, registration_assert, post_if) < 0:
        die("cannot locate the complete materialized FB/PMA guard sequence")

    opening = function.find("{", post_if + len(POST_GUARD_ANCHOR))
    if opening < 0:
        die("cannot locate post-registration PMA guard body")
    closing = find_matching_brace(function, opening)
    segment = function[start : closing + 1]
    if segment.count(REGISTRATION_ANCHOR) != 1:
        die("guard segment must contain exactly one standard PMA registration")
    return segment


def validate_source_shape(function: str, segment: str) -> None:
    """Require the invariants and their ordering before compiling the segment."""

    required_pre_markers = (
        "GSP_FW_WPR_META_MAGIC",
        "GSP_FW_WPR_META_REVISION",
        "pWprMeta->fbSize != targetFbBytes",
        "fbAddrSpaceBytes != targetFbBytes",
        "pWprMeta->gspFwRsvdStart != pWprMeta->nonWprHeapOffset",
        "pWprMeta->nonWprHeapSize !=",
        "pWprMeta->gspFwWprStart - pWprMeta->nonWprHeapOffset",
        "pMemoryManager->pHeap->base >= pWprMeta->fbSize",
        "PMA_QUERY_NUMA_ONLINED",
        "pmaQueryConfigs(",
        "pMemoryManager->Ram.numFBRegions > MAX_FB_REGIONS",
        "pRegion->base != expectedBase",
        "(pRegion->base & 0xffffULL) != 0",
        "((pRegion->limit + 1) & 0xffffULL) != 0",
        "pRegion->rsvdSize > currentRegionBytes",
        "pRegion->rsvdSize != currentRegionBytes",
        "pRegion->rsvdSize != 0 || pRegion->bProtected",
        "pRegion->limit >= pWprMeta->gspFwRsvdStart",
        "nativePublicBytes < pWprMeta->fbSize - 0x80000000ULL",
        "clippedBase = NV_MAX(",
        "clippedEndExclusive = NV_MIN(",
        "pTopRegion->base != pWprMeta->gspFwRsvdStart",
        "pTopRegion->limit + 1 != pWprMeta->fbSize",
        "!pTopRegion->bRsvdRegion",
        "pTopRegion->rsvdSize != protectedBytes",
        "validatedPublicBytes = pmaPublicBytes",
    )
    missing = [marker for marker in required_pre_markers if marker not in segment]
    if missing:
        die(f"materialized pre-registration guard is missing invariant: {missing[0]}")

    pre = segment.find(PRE_GUARD_ANCHOR)
    registration = segment.find(REGISTRATION_ANCHOR)
    registration_assert = segment.find(
        "NV_ASSERT_OR_RETURN(status == NV_OK, status);", registration
    )
    total_query = segment.find("pmaGetTotalMemory(", registration_assert)
    equality = segment.find("if (pmaBytes != validatedPublicBytes)", total_query)
    refusal = segment.find("return NV_ERR_INVALID_STATE;", equality)
    safe_log = segment.find(
        '"status=safe build=cmpunlocker-safety-v3\\n"', equality
    )
    if not (
        0
        <= pre
        < registration
        < registration_assert
        < total_query
        < equality
        < refusal
        < safe_log
    ):
        die(
            "PMA registration, total query, equality refusal, and v3 safe log "
            "are not ordered fail-closed"
        )

    outer_registration = function.find(REGISTRATION_ANCHOR)
    if outer_registration < 0 or function.find(PRE_GUARD_ANCHOR) >= outer_registration:
        die("materialized FB guard does not precede standard PMA registration")
    if function.count(REGISTRATION_ANCHOR) != 1:
        die("memmgrCreateHeap_IMPL must contain exactly one PMA registration")

    enclosing_if = function.find(ENCLOSING_GUARD_ANCHOR)
    if enclosing_if < 0:
        die("PMA registration is missing its initialized/FB-regions enclosure")
    enclosing_open = function.find(
        "{", enclosing_if + len(ENCLOSING_GUARD_ANCHOR)
    )
    if enclosing_open < 0:
        die("cannot locate initialized/FB-regions enclosure body")
    enclosing_close = find_matching_brace(function, enclosing_open)
    pre_in_function = function.find(PRE_GUARD_ANCHOR)
    post_total_in_function = function.find("pmaGetTotalMemory(", outer_registration)
    segment_end_in_function = pre_in_function + len(segment)
    if not (
        enclosing_open
        < pre_in_function
        < outer_registration
        < post_total_in_function
        < segment_end_in_function
        < enclosing_close
    ):
        die(
            "pre-guard, standard registration, and post-check must share the "
            "initialized/FB-regions enclosure"
        )


HARNESS_PREFIX = r'''
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef unsigned char NvBool;
typedef unsigned int NvU32;
typedef unsigned long long NvU64;
typedef int NV_STATUS;

#define NV_FALSE 0U
#define NV_TRUE 1U
#define NV_OK 0
#define NV_ERR_INVALID_STATE 0x56
#define NV_ERR_GENERIC 0x01
#define LEVEL_ERROR 0
#define MAX_FB_REGIONS 16U
#define PMA_QUERY_NUMA_ONLINED 0x8U
#define GSP_FW_WPR_META_MAGIC 0xdc3aae21371a60b3ULL
#define GSP_FW_WPR_META_REVISION 1ULL
#define NV_MAX(a, b) ((a) > (b) ? (a) : (b))
#define NV_MIN(a, b) ((a) < (b) ? (a) : (b))
#define NV_ASSERT_OR_RETURN(condition, value) \
    do { if (!(condition)) return (value); } while (0)

typedef struct FB_REGION_DESCRIPTOR
{
    NvU64 base;
    NvU64 limit;
    NvU64 rsvdSize;
    NvBool bRsvdRegion;
    NvU32 performance;
    NvBool bSupportCompressed;
    NvBool bSupportISO;
    NvBool bProtected;
    NvBool bInternalHeap;
    NvBool bLostOnSuspend;
    NvBool bPreserveOnSuspend;
    NvU32 regionTag;
} FB_REGION_DESCRIPTOR;

typedef struct GspFwWprMeta
{
    NvU64 magic;
    NvU64 revision;
    NvU64 gspFwRsvdStart;
    NvU64 nonWprHeapOffset;
    NvU64 nonWprHeapSize;
    NvU64 gspFwWprStart;
    NvU64 gspFwHeapOffset;
    NvU64 gspFwHeapSize;
    NvU64 gspFwWprEnd;
    NvU64 fbSize;
} GspFwWprMeta;

typedef struct MEMORY_DESCRIPTOR
{
    NvU64 size;
} MEMORY_DESCRIPTOR;

typedef struct PMA_OBJECT
{
    NvU32 unused;
} PMA_OBJECT;

typedef struct Heap
{
    NvU64 base;
    NvU64 total;
    PMA_OBJECT *pPmaObject;
} Heap;

typedef struct MemoryManager MemoryManager;

typedef struct KernelGsp
{
    GspFwWprMeta *pWprMeta;
    MEMORY_DESCRIPTOR *pWprMetaDescriptor;
} KernelGsp;

typedef struct OBJGPU
{
    struct
    {
        NvU32 PCIDeviceID;
    } idInfo;
    KernelGsp *pKernelGsp;
    MemoryManager *pMemoryManager;
} OBJGPU;

struct MemoryManager
{
    struct
    {
        NvU64 fbAddrSpaceSizeMb;
        NvU32 numFBRegions;
        FB_REGION_DESCRIPTOR fbRegion[MAX_FB_REGIONS];
    } Ram;
    Heap *pHeap;
    OBJGPU *pGpu;
};

#define GPU_GET_KERNEL_GSP(pGpu) ((pGpu)->pKernelGsp)

static NvU32 g_query_config;
static NV_STATUS g_query_status;
static NV_STATUS g_registration_status;
static NvU64 g_pma_total;
static NvU32 g_query_calls;
static NvU32 g_registration_calls;
static NvU32 g_total_calls;
static NvU32 g_bad_pointer_calls;
static OBJGPU *g_expected_gpu;
static MemoryManager *g_expected_memory_manager;
static Heap *g_expected_heap;
static PMA_OBJECT *g_expected_pma;

static void nv_printf(NvU32 level, const char *format, ...)
{
    va_list arguments;
    (void)level;
    va_start(arguments, format);
    va_end(arguments);
}

#define NV_PRINTF nv_printf

static NvU64 memdescGetSize(const MEMORY_DESCRIPTOR *pDescriptor)
{
    return pDescriptor->size;
}

static NV_STATUS pmaQueryConfigs(PMA_OBJECT *pPmaObject, NvU32 *pConfig)
{
    g_query_calls++;
    if (pPmaObject != g_expected_pma || pConfig == NULL)
    {
        g_bad_pointer_calls++;
        return NV_ERR_GENERIC;
    }
    if (g_query_status != NV_OK)
        return g_query_status;
    *pConfig &= g_query_config;
    return NV_OK;
}

static NV_STATUS memmgrPmaRegisterRegions(
    OBJGPU *pGpu,
    MemoryManager *pMemoryManager,
    Heap *pHeap,
    PMA_OBJECT *pPmaObject)
{
    g_registration_calls++;
    if (pGpu != g_expected_gpu ||
        pMemoryManager != g_expected_memory_manager ||
        pHeap != g_expected_heap ||
        pPmaObject != g_expected_pma)
    {
        g_bad_pointer_calls++;
        return NV_ERR_GENERIC;
    }
    return g_registration_status;
}

static void pmaGetTotalMemory(PMA_OBJECT *pPmaObject, NvU64 *pTotal)
{
    g_total_calls++;
    if (pPmaObject != g_expected_pma || pTotal == NULL)
    {
        g_bad_pointer_calls++;
        return;
    }
    *pTotal = g_pma_total;
}

static NV_STATUS runExtractedGuard(MemoryManager *pMemoryManager)
{
    OBJGPU *pGpu = pMemoryManager->pGpu;
    NV_STATUS status = NV_OK;
'''


HARNESS_SUFFIX = r'''
    return status;
}

#define FB64 0x0000001000000000ULL
#define FB40 0x0000000a00000000ULL
#define LIVE_PROTECTED 0x0000000ff7200000ULL
#define LIVE_PUBLIC 0x0000000fd8e50000ULL

typedef struct TestContext
{
    OBJGPU gpu;
    KernelGsp kernelGsp;
    GspFwWprMeta meta;
    MEMORY_DESCRIPTOR descriptor;
    PMA_OBJECT pma;
    Heap heap;
    MemoryManager memoryManager;
} TestContext;

static NvU32 failures;

static NvU64 regionSize(const FB_REGION_DESCRIPTOR *pRegion)
{
    return pRegion->limit - pRegion->base + 1ULL;
}

static void addRegion(
    TestContext *pContext,
    NvU64 base,
    NvU64 limit,
    NvBool reserved,
    NvBool internal,
    NvBool protectedRegion,
    NvU64 reservedSize)
{
    NvU32 index = pContext->memoryManager.Ram.numFBRegions++;
    FB_REGION_DESCRIPTOR *pRegion = &pContext->memoryManager.Ram.fbRegion[index];
    pRegion->base = base;
    pRegion->limit = limit;
    pRegion->bRsvdRegion = reserved;
    pRegion->bInternalHeap = internal;
    pRegion->bProtected = protectedRegion;
    pRegion->rsvdSize = reservedSize;
}

static void resetStubs(NvU64 pmaTotal)
{
    g_query_config = 0;
    g_query_status = NV_OK;
    g_registration_status = NV_OK;
    g_pma_total = pmaTotal;
    g_query_calls = 0;
    g_registration_calls = 0;
    g_total_calls = 0;
    g_bad_pointer_calls = 0;
}

static void initCommon(
    TestContext *pContext,
    NvU32 deviceId,
    NvU64 fbSize,
    NvU64 protectedStart)
{
    memset(pContext, 0, sizeof(*pContext));
    pContext->gpu.idInfo.PCIDeviceID = deviceId << 16;
    pContext->gpu.pKernelGsp = &pContext->kernelGsp;
    pContext->gpu.pMemoryManager = &pContext->memoryManager;
    pContext->kernelGsp.pWprMeta = &pContext->meta;
    pContext->kernelGsp.pWprMetaDescriptor = &pContext->descriptor;
    pContext->descriptor.size = sizeof(pContext->meta);
    pContext->heap.pPmaObject = &pContext->pma;
    pContext->heap.total = fbSize;
    pContext->memoryManager.pHeap = &pContext->heap;
    pContext->memoryManager.pGpu = &pContext->gpu;
    pContext->memoryManager.Ram.fbAddrSpaceSizeMb = fbSize >> 20;
    g_expected_gpu = &pContext->gpu;
    g_expected_memory_manager = &pContext->memoryManager;
    g_expected_heap = &pContext->heap;
    g_expected_pma = &pContext->pma;

    pContext->meta.magic = GSP_FW_WPR_META_MAGIC;
    pContext->meta.revision = GSP_FW_WPR_META_REVISION;
    pContext->meta.fbSize = fbSize;
    pContext->meta.gspFwRsvdStart = protectedStart;
    pContext->meta.nonWprHeapOffset = protectedStart;
    pContext->meta.gspFwWprStart = protectedStart + 0x100000ULL;
    pContext->meta.nonWprHeapSize = 0x100000ULL;
    pContext->meta.gspFwHeapOffset = protectedStart + 0x200000ULL;
    pContext->meta.gspFwHeapSize = 0x6e00000ULL;
    pContext->meta.gspFwWprEnd = fbSize - 0x100000ULL;
}

static void initLive20c2(TestContext *pContext)
{
    initCommon(pContext, 0x20c2U, FB64, LIVE_PROTECTED);
    addRegion(pContext, 0x0000000000000000ULL, 0x000000001007ffffULL,
              NV_TRUE, NV_FALSE, NV_FALSE, 0x10080000ULL);
    addRegion(pContext, 0x0000000010080000ULL, 0x0000000fe8ecffffULL,
              NV_FALSE, NV_FALSE, NV_FALSE, 0);
    addRegion(pContext, 0x0000000fe8ed0000ULL, 0x0000000ff41dffffULL,
              NV_FALSE, NV_TRUE, NV_FALSE, 0x0b310000ULL);
    addRegion(pContext, 0x0000000ff41e0000ULL, 0x0000000ff420ffffULL,
              NV_TRUE, NV_TRUE, NV_FALSE, 0x00030000ULL);
    addRegion(pContext, 0x0000000ff4210000ULL, 0x0000000ff710ffffULL,
              NV_TRUE, NV_FALSE, NV_FALSE, 0x02f00000ULL);
    addRegion(pContext, 0x0000000ff7110000ULL, 0x0000000ff71fffffULL,
              NV_TRUE, NV_FALSE, NV_FALSE, 0x000f0000ULL);
    addRegion(pContext, LIVE_PROTECTED, FB64 - 1ULL,
              NV_TRUE, NV_FALSE, NV_FALSE, FB64 - LIVE_PROTECTED);
    resetStubs(LIVE_PUBLIC);
}

static void initSynthetic2082(TestContext *pContext)
{
    const NvU64 protectedStart = FB40 - 0x08e00000ULL;
    const NvU64 publicBase = 0x10080000ULL;
    initCommon(pContext, 0x2082U, FB40, protectedStart);
    addRegion(pContext, 0, publicBase - 1ULL,
              NV_TRUE, NV_FALSE, NV_FALSE, publicBase);
    addRegion(pContext, publicBase, protectedStart - 1ULL,
              NV_FALSE, NV_FALSE, NV_FALSE, 0);
    addRegion(pContext, protectedStart, FB40 - 1ULL,
              NV_TRUE, NV_FALSE, NV_FALSE, FB40 - protectedStart);
    resetStubs(protectedStart - publicBase);
}

static void expectResult(
    const char *name,
    TestContext *pContext,
    NV_STATUS expected,
    NvU32 expectedQueries,
    NvU32 expectedRegistrations,
    NvU32 expectedTotalQueries)
{
    TestContext before = *pContext;
    NV_STATUS actual = runExtractedGuard(&pContext->memoryManager);
    if (actual != expected)
    {
        fprintf(stderr, "%s: status 0x%x, expected 0x%x\n", name, actual, expected);
        failures++;
    }
    if (g_query_calls != expectedQueries ||
        g_registration_calls != expectedRegistrations ||
        g_total_calls != expectedTotalQueries ||
        g_bad_pointer_calls != 0)
    {
        fprintf(stderr,
                "%s: query/registration/total/bad-pointer calls "
                "%u/%u/%u/%u, expected %u/%u/%u/0\n",
                name, g_query_calls, g_registration_calls, g_total_calls,
                g_bad_pointer_calls, expectedQueries, expectedRegistrations,
                expectedTotalQueries);
        failures++;
    }
    if (memcmp(&before, pContext, sizeof(before)) != 0)
    {
        fprintf(stderr, "%s: extracted guard mutated its input layout\n", name);
        failures++;
    }
}

static void expectPass(const char *name, TestContext *pContext)
{
    expectResult(name, pContext, NV_OK, 1, 1, 1);
}

static void expectGuardRefusal(const char *name, TestContext *pContext)
{
    expectResult(name, pContext, NV_ERR_INVALID_STATE, 1, 0, 0);
}

static void expectEarlyRefusal(const char *name, TestContext *pContext)
{
    expectResult(name, pContext, NV_ERR_INVALID_STATE, 0, 0, 0);
}

int main(void)
{
    TestContext context;
    FB_REGION_DESCRIPTOR *pRegion;
    NvU64 clippedPublic;

    initLive20c2(&context);
    expectPass("live-20c2-seven-region-map", &context);

    initSynthetic2082(&context);
    expectPass("synthetic-2082-map", &context);

    initLive20c2(&context);
    context.heap.base = 0x20000000ULL;
    context.heap.total = FB64 - context.heap.base;
    clippedPublic = 0x0000000fe8ed0000ULL - context.heap.base;
    resetStubs(clippedPublic);
    expectPass("heap-clipping-exact-PMA-total", &context);

    initLive20c2(&context);
    context.heap.base = 0x20000000ULL;
    context.heap.total = FB64 - context.heap.base;
    resetStubs(LIVE_PUBLIC);
    expectResult("heap-clipping-PMA-mismatch", &context,
                 NV_ERR_INVALID_STATE, 1, 1, 1);

    initLive20c2(&context);
    pRegion = &context.memoryManager.Ram.fbRegion[6];
    pRegion->limit = LIVE_PROTECTED + 0xffffULL;
    pRegion->rsvdSize = regionSize(pRegion);
    addRegion(&context, pRegion->limit + 1ULL, FB64 - 1ULL,
              NV_TRUE, NV_FALSE, NV_FALSE, FB64 - pRegion->limit - 1ULL);
    expectGuardRefusal("top-carveout-must-be-one-exact-region", &context);

    initLive20c2(&context);
    context.memoryManager.Ram.fbRegion[1].base += 0x10000ULL;
    expectGuardRefusal("region-gap", &context);

    initLive20c2(&context);
    context.memoryManager.Ram.fbRegion[1].base -= 0x10000ULL;
    expectGuardRefusal("region-overlap", &context);

    initLive20c2(&context);
    context.memoryManager.Ram.fbRegion[1].base += 1ULL;
    expectGuardRefusal("region-misalignment", &context);

    initLive20c2(&context);
    pRegion = &context.memoryManager.Ram.fbRegion[2];
    pRegion->rsvdSize = regionSize(pRegion) + 1ULL;
    expectGuardRefusal("reserved-size-overflow", &context);

    initLive20c2(&context);
    pRegion = &context.memoryManager.Ram.fbRegion[0];
    pRegion->rsvdSize = regionSize(pRegion) - 0x10000ULL;
    expectGuardRefusal("reserved-region-must-be-full", &context);

    initLive20c2(&context);
    context.memoryManager.Ram.fbRegion[1].rsvdSize = 0x10000ULL;
    expectGuardRefusal("public-region-reserved-bytes", &context);

    initLive20c2(&context);
    context.memoryManager.Ram.fbRegion[1].bProtected = NV_TRUE;
    expectGuardRefusal("public-region-protected", &context);

    initLive20c2(&context);
    pRegion = &context.memoryManager.Ram.fbRegion[6];
    pRegion->bRsvdRegion = NV_FALSE;
    pRegion->bInternalHeap = NV_TRUE;
    pRegion->rsvdSize = 0;
    expectGuardRefusal("internal-region-crosses-protected-start", &context);

    initLive20c2(&context);
    g_query_config = PMA_QUERY_NUMA_ONLINED;
    expectGuardRefusal("NUMA-onlined-refusal", &context);

    initLive20c2(&context);
    pRegion = &context.memoryManager.Ram.fbRegion[0];
    pRegion->limit = 0xbfffffffULL;
    pRegion->rsvdSize = regionSize(pRegion);
    context.memoryManager.Ram.fbRegion[1].base = 0xc0000000ULL;
    expectGuardRefusal("native-public-capacity-floor", &context);

    initLive20c2(&context);
    g_pma_total = LIVE_PUBLIC - 0x10000ULL;
    expectResult("post-registration-PMA-total-mismatch", &context,
                 NV_ERR_INVALID_STATE, 1, 1, 1);

    initLive20c2(&context);
    context.gpu.pKernelGsp = NULL;
    expectEarlyRefusal("missing-KernelGsp", &context);

    initLive20c2(&context);
    context.kernelGsp.pWprMeta = NULL;
    expectEarlyRefusal("missing-WPR-metadata", &context);

    initLive20c2(&context);
    context.kernelGsp.pWprMetaDescriptor = NULL;
    expectEarlyRefusal("missing-WPR-metadata-descriptor", &context);

    initLive20c2(&context);
    context.descriptor.size = sizeof(context.meta) - 1ULL;
    expectEarlyRefusal("truncated-WPR-metadata-descriptor", &context);

    initLive20c2(&context);
    context.meta.gspFwRsvdStart += 0x10000ULL;
    expectEarlyRefusal("reserved-start-must-equal-non-WPR-offset", &context);

    initLive20c2(&context);
    context.meta.nonWprHeapSize += 0x10000ULL;
    expectEarlyRefusal("non-WPR-span-must-end-at-WPR-start", &context);

    initLive20c2(&context);
    context.meta.gspFwHeapOffset = context.meta.gspFwWprEnd;
    expectEarlyRefusal("GSP-heap-must-stay-inside-WPR", &context);

    initLive20c2(&context);
    g_query_status = NV_ERR_GENERIC;
    expectGuardRefusal("PMA-config-query-failure", &context);

    initLive20c2(&context);
    g_registration_status = NV_ERR_GENERIC;
    expectResult("standard-PMA-registration-failure", &context,
                 NV_ERR_GENERIC, 1, 1, 0);

    initLive20c2(&context);
    context.gpu.idInfo.PCIDeviceID = 0x1234U << 16;
    context.gpu.pKernelGsp = NULL;
    expectResult("non-target-device-bypasses-target-guard", &context,
                 NV_OK, 0, 1, 0);

    if (failures != 0)
    {
        fprintf(stderr, "%u PMA-guard self-test(s) failed\n", failures);
        return 1;
    }

    puts("PMA-guard self-test: PASS (26 compiled vectors)");
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
        source_before = source.read_bytes()
        text = source_before.decode("utf-8")
    except (OSError, UnicodeError) as error:
        die(f"cannot read {source}: {error}")

    try:
        function = extract_function(text, FUNCTION_NAME)
        segment = extract_guard_segment(function)
        validate_source_shape(function, segment)

        harness = HARNESS_PREFIX + "\n" + segment + "\n" + HARNESS_SUFFIX
        with tempfile.TemporaryDirectory(prefix="cmpunlocker-pma-guard-test.") as temp:
            temp_dir = Path(temp)
            harness_path = temp_dir / "pma-guard-test.c"
            executable = temp_dir / "pma-guard-test"
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
                cwd=temp_dir,
            )
            if compile_result.returncode != 0:
                details = (compile_result.stdout + compile_result.stderr).strip()
                die(f"host compilation failed for {source}:\n{details}")

            test_result = subprocess.run(
                [str(executable)],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=temp_dir,
            )
            output = (test_result.stdout + test_result.stderr).strip()
            if test_result.returncode != 0:
                die(f"compiled C vectors failed for {source}:\n{output}")
            print(f"{source}: {output}")
    finally:
        try:
            source_after = source.read_bytes()
        except OSError as error:
            die(f"cannot re-read {source} after testing: {error}")
        if source_after != source_before:
            die(f"source changed while running self-test: {source}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Compile and test the extracted final materialized FB/PMA guard "
            "from patched mem_mgr.c"
        )
    )
    parser.add_argument(
        "source",
        type=Path,
        nargs="+",
        help="one or more final patched mem_mgr.c sources",
    )
    args = parser.parse_args()
    for source in args.source:
        run_tests(source.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
