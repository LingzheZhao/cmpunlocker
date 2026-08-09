#!/usr/bin/env python3
"""Summarize cmpunlocker WPR/PMA evidence from a kernel log.

Input must be one chronologically ordered kernel-log source from one current
boot.  Do not concatenate journal, dmesg, or records from different boots;
``verify.sh`` analyzes each readable current-boot source independently.

Exit status 0 means that relevant records were parsed and none of the hazards
checked here were present. In strict mode, fixed-driver anchors were also
coherent; ``--best-effort`` intentionally does not require those anchors.
Status 1 means that overlap or runtime-fault evidence was found. Status 2
means that the input or safety proof was incomplete.
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import sys
from bisect import bisect_right
from collections import defaultdict
from pathlib import Path
from typing import Iterable, Optional


EXIT_OK = 0
EXIT_HAZARD = 1
EXIT_NO_DATA = 2
MAX_U64 = (1 << 64) - 1
MAX_GPU_INDEX_DIGITS = 10
MAX_FB_REGIONS = 16
MAX_RESERVED_BYTES = 0x80000000
MAX_INPUT_CHARS = 32 * 1024 * 1024
MAX_LOG_LINE_CHARS = 64 * 1024
MAX_RELEVANT_RECORDS = 8192
EXPECTED_SAFETY_BUILD = "cmpunlocker-safety-v3"

UNKNOWN_GPU = "unattributed"

GPU_RE = re.compile(r"\bGPU(?P<index>\d+)\b", re.IGNORECASE)
PCI_RE = re.compile(
    r"\bPCI:(?P<bdf>(?:[0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}(?:\.[0-7])?)",
    re.IGNORECASE,
)
HEX_U64_TOKEN_RE = r"0x[0-9a-fA-F](?:_?[0-9a-fA-F]){0,15}"
DEC_U64_TOKEN_RE = r"[0-9](?:_?[0-9]){0,19}"
HEX_OR_DEC_RE = (
    rf"(?:(?:{HEX_U64_TOKEN_RE})|(?:{DEC_U64_TOKEN_RE}))"
    r"(?![0-9A-Za-z_])"
)
KEY_VALUE_RE = re.compile(
    rf"\b(?P<key>fbSize|rsvdStart|wprStart|wprEnd|heapOffset|heapSize)"
    rf"\s*=\s*(?P<value>{HEX_OR_DEC_RE})",
    re.IGNORECASE,
)
KEY_ASSIGNMENT_RE = re.compile(
    r"\b(?P<key>fbSize|rsvdStart|wprStart|wprEnd|heapOffset|heapSize)\s*=",
    re.IGNORECASE,
)
PMA_VALUE_RE = re.compile(
    rf"\b(?P<key>candidate|base|limit)\s*=\s*(?P<value>{HEX_OR_DEC_RE})",
    re.IGNORECASE,
)
PMA_ASSIGNMENT_RE = re.compile(
    r"\b(?P<key>candidate|base|limit)\s*=", re.IGNORECASE
)
GUARD_VALUE_RE = re.compile(
    rf"\b(?P<key>protectedStart|fbSize|metaFbSize|publicBytes|pmaBytes)"
    rf"\s*=\s*(?P<value>{HEX_OR_DEC_RE})",
    re.IGNORECASE,
)
GUARD_ASSIGNMENT_RE = re.compile(
    r"\b(?P<key>protectedStart|fbSize|metaFbSize|publicBytes|pmaBytes)\s*=",
    re.IGNORECASE,
)
FB_LAYOUT_VALUE_RE = re.compile(
    rf"\b(?P<key>fbSize|protectedStart|publicBytes|capacityFloor|"
    rf"reservedRegionBytes|regions)\s*=\s*(?P<value>{HEX_OR_DEC_RE})",
    re.IGNORECASE,
)
FB_LAYOUT_ASSIGNMENT_RE = re.compile(
    r"\b(?P<key>fbSize|protectedStart|publicBytes|capacityFloor|"
    r"reservedRegionBytes|regions)\s*=",
    re.IGNORECASE,
)
BUILD_VALUE_RE = re.compile(
    r"\bbuild\s*=\s*(?P<value>[A-Za-z0-9._-]+)(?![A-Za-z0-9._-])",
    re.IGNORECASE,
)
BUILD_ASSIGNMENT_RE = re.compile(r"\bbuild\s*=", re.IGNORECASE)
STATUS_VALUE_RE = re.compile(
    r"\bstatus\s*=\s*(?P<value>[A-Za-z0-9._-]+)(?![A-Za-z0-9._-])",
    re.IGNORECASE,
)
STATUS_ASSIGNMENT_RE = re.compile(r"\bstatus\s*=", re.IGNORECASE)
XID_31_RE = re.compile(
    r"\bXid(?:\s*\([^)]*\))?\s*(?::\s*|\s+)31\b", re.IGNORECASE
)
ANY_XID_RE = re.compile(r"\bXid(?:\s*\([^)]*\))?\s*(?::\s*|\s+)\d+\b", re.IGNORECASE)
FAULT_ADDRESS_RE = re.compile(
    rf"\bfaulted\s*@\s*({HEX_U64_TOKEN_RE})(?![0-9A-Za-z_])",
    re.IGNORECASE,
)
CE_ENGINE_RE = re.compile(r"\b(?:ENGINE\s+)?(CE\d+)\b", re.IGNORECASE)
CE_CONTEXT_RE = re.compile(
    r"\b(?:CE\d+|HUBCLIENT_[A-Z0-9_]*CE\d+)\b", re.IGNORECASE
)
PHYS_WRITE_RE = re.compile(r"\b(?:ACCESS_TYPE_)?PHYS(?:ICAL)?_?WRITE\b", re.IGNORECASE)
REGION_VIOLATION_RE = re.compile(
    r"(?:\bREGION_VIOLATION\b|"
    r"\b(?:FAULT_INFO_TYPE|MMU_FAULT_TYPE)_REGION_VIOLATION\b)",
    re.IGNORECASE,
)
REGION_VIOLATION_NEGATION_RE = re.compile(
    r"\b(?:did|does)\s+not\s+report\s+REGION_VIOLATION\b|"
    r"\bno\s+REGION_VIOLATION\b",
    re.IGNORECASE,
)
SCRUB_TIMED_OUT_RE = re.compile(r"\btimed\s+out\b", re.IGNORECASE)
SCRUB_TIMEOUT_NEGATION_RE = re.compile(
    r"\b(?:not|never)\s+timed\s+out\b|\bdid\s+not\s+time\s+out\b|"
    r"\bwithout\s+timing\s+out\b",
    re.IGNORECASE,
)
PMA_NO_MEMORY_CODE_RE = re.compile(r"\b0x0*51\b", re.IGNORECASE)
PMA_SUCCESS_RE = re.compile(
    r"\b(?:succeeded|successful|success|returned\s+NV_OK)\b", re.IGNORECASE
)
PMA_SUCCESS_NEGATION_RE = re.compile(
    r"\b(?:not|never)\s+(?:succeeded|successful|a\s+success)\b|"
    r"\b(?:was|is)\s+not\s+successful\b",
    re.IGNORECASE,
)
NVRM_RECORD_RE = re.compile(r"\bNVRM\s*:", re.IGNORECASE)
STALE_WPR_STATE_RE = re.compile(
    r"(?:\bunexpected\s+WPR2\s+already\s+up\b|"
    r"\bWPR2\s+already\s+up\s+before\s+GSP\s+boot\b)",
    re.IGNORECASE,
)


@dataclasses.dataclass(frozen=True)
class WprMeta:
    gpu: str
    line: int
    fb_size: int
    wpr_start: int
    wpr_end: int
    heap_offset: int
    heap_size: int
    rsvd_start: Optional[int] = None


@dataclasses.dataclass(frozen=True)
class PmaRange:
    gpu: str
    line: int
    base: int
    limit: int
    candidate: Optional[int] = None


@dataclasses.dataclass(frozen=True)
class Fault:
    gpu: str
    line: int
    address: int
    engine: str


@dataclasses.dataclass(frozen=True)
class Event:
    gpu: str
    line: int


@dataclasses.dataclass(frozen=True)
class FbLayout:
    gpu: str
    line: int
    fb_size: Optional[int]
    protected_start: Optional[int]
    public_bytes: Optional[int]
    capacity_floor: Optional[int]
    reserved_region_bytes: Optional[int]
    regions: Optional[int]
    build: Optional[str]
    safe: bool
    rejected: bool


@dataclasses.dataclass(frozen=True)
class Guard:
    gpu: str
    line: int
    protected_start: Optional[int]
    fb_size: Optional[int]
    public_bytes: Optional[int]
    pma_bytes: Optional[int]
    build: Optional[str]
    safe: bool
    refusing: bool


@dataclasses.dataclass(frozen=True)
class Finding:
    gpu: str
    kind: str
    overlap_start: int
    overlap_end: int


@dataclasses.dataclass
class Analysis:
    wpr: list[WprMeta] = dataclasses.field(default_factory=list)
    pma: list[PmaRange] = dataclasses.field(default_factory=list)
    fb_layouts: list[FbLayout] = dataclasses.field(default_factory=list)
    guards: list[Guard] = dataclasses.field(default_factory=list)
    xid31: list[Event] = dataclasses.field(default_factory=list)
    ce_region_violations: list[Event] = dataclasses.field(default_factory=list)
    faults: list[Fault] = dataclasses.field(default_factory=list)
    scrub_timeouts: list[Event] = dataclasses.field(default_factory=list)
    pma_oom: list[Event] = dataclasses.field(default_factory=list)
    context_oom: list[Event] = dataclasses.field(default_factory=list)
    stale_wpr_state: list[Event] = dataclasses.field(default_factory=list)
    warnings: list[str] = dataclasses.field(default_factory=list)
    layout_errors: list[str] = dataclasses.field(default_factory=list)

    def has_records(self) -> bool:
        return any(
            (
                self.wpr,
                self.pma,
                self.fb_layouts,
                self.guards,
                self.xid31,
                self.ce_region_violations,
                self.faults,
                self.scrub_timeouts,
                self.pma_oom,
                self.context_oom,
                self.stale_wpr_state,
            )
        )

    def record_count(self) -> int:
        return sum(
            len(records)
            for records in (
                self.wpr,
                self.pma,
                self.fb_layouts,
                self.guards,
                self.xid31,
                self.ce_region_violations,
                self.faults,
                self.scrub_timeouts,
                self.pma_oom,
                self.context_oom,
                self.stale_wpr_state,
            )
        )


def parse_number(value: str) -> int:
    cleaned = value.replace("_", "")
    hexadecimal = cleaned.lower().startswith("0x")
    digits = cleaned[2:] if hexadecimal else cleaned
    # Every parsed field is an RM address, size, status value, or small index.
    # Reject non-U64-width tokens before int() so Python's decimal digit limit
    # can never raise an uncaught exception on an adversarial/garbled log line.
    if len(digits) > (16 if hexadecimal else 20):
        raise ValueError("numeric field exceeds unsigned 64-bit width")
    parsed = int(cleaned, 16 if hexadecimal else 10)
    if parsed > MAX_U64:
        raise ValueError("numeric field exceeds unsigned 64-bit range")
    return parsed


def parse_key_values(
    pattern: re.Pattern[str],
    assignment_pattern: re.Pattern[str],
    line: str,
    line_no: int,
    record_name: str,
    analysis: Analysis,
) -> Optional[dict[str, int]]:
    try:
        values: dict[str, int] = {}
        value_matches = list(pattern.finditer(line))
        assignment_matches = list(assignment_pattern.finditer(line))
        if len(value_matches) != len(assignment_matches):
            raise ValueError("unparseable or empty field assignment")
        for match in value_matches:
            key = match.group("key").lower()
            if key in values:
                raise ValueError(f"duplicate {key} field")
            values[key] = parse_number(match.group("value"))
        return values
    except ValueError as error:
        analysis.warnings.append(
            f"line {line_no}: malformed {record_name} numeric field ({error})"
        )
        return None


def single_token_value(
    pattern: re.Pattern[str],
    assignment_pattern: re.Pattern[str],
    line: str,
) -> Optional[str]:
    matches = list(pattern.finditer(line))
    assignments = list(assignment_pattern.finditer(line))
    return (
        matches[0].group("value")
        if len(matches) == 1 and len(assignments) == 1
        else None
    )


def gpu_from_text(text: str) -> str:
    match = GPU_RE.search(text)
    if match:
        digits = match.group("index").lstrip("0") or "0"
        if len(digits) > MAX_GPU_INDEX_DIGITS:
            return UNKNOWN_GPU
        return f"GPU{digits}"
    match = PCI_RE.search(text)
    if match:
        return f"PCI:{match.group('bdf').lower()}"
    return UNKNOWN_GPU


def gpu_from_xid_text(text: str) -> str:
    """Prefer the explicit PCI identity carried by Xid records."""
    match = PCI_RE.search(text)
    if match:
        return f"PCI:{match.group('bdf').lower()}"
    return gpu_from_text(text)


def parse_log(text: str) -> Analysis:
    analysis = Analysis()
    if len(text) > MAX_INPUT_CHARS:
        analysis.warnings.append(
            f"input exceeds the {MAX_INPUT_CHARS}-character analysis limit"
        )
        return analysis
    lines = text.splitlines()
    oversized_lines = {
        offset + 1
        for offset, line in enumerate(lines)
        if len(line) > MAX_LOG_LINE_CHARS
    }
    for line_no in sorted(oversized_lines):
        analysis.warnings.append(
            f"line {line_no}: record exceeds the {MAX_LOG_LINE_CHARS}-character limit"
        )

    primary_context_oom: list[Event] = []
    fallback_context_oom: list[Event] = []
    primary_scrub_timeout: list[Event] = []
    fallback_scrub_timeout: list[Event] = []
    record_limit_hit = False

    for offset, line in enumerate(lines):
        line_no = offset + 1
        provisional_count = (
            analysis.record_count()
            + len(analysis.warnings)
            + len(primary_context_oom)
            + len(fallback_context_oom)
            + len(primary_scrub_timeout)
            + len(fallback_scrub_timeout)
        )
        if provisional_count >= MAX_RELEVANT_RECORDS:
            analysis.warnings.append(
                f"relevant record count exceeds the {MAX_RELEVANT_RECORDS}-record limit"
            )
            record_limit_hit = True
            break
        if line_no in oversized_lines:
            continue
        gpu = gpu_from_text(line)
        lowered = line.lower()
        gpu_match = GPU_RE.search(line)
        if gpu_match:
            gpu_digits = gpu_match.group("index").lstrip("0") or "0"
            if len(gpu_digits) > MAX_GPU_INDEX_DIGITS:
                analysis.warnings.append(
                    f"line {line_no}: GPU index exceeds supported numeric width"
                )

        if "wpr meta updated" in lowered:
            raw_values = parse_key_values(
                KEY_VALUE_RE,
                KEY_ASSIGNMENT_RE,
                line,
                line_no,
                "WPR metadata",
                analysis,
            )
            if raw_values is not None:
                required = (
                    "fbsize",
                    "wprstart",
                    "wprend",
                    "heapoffset",
                    "heapsize",
                )
                missing = [name for name in required if name not in raw_values]
                if missing:
                    analysis.warnings.append(
                        f"line {line_no}: incomplete WPR metadata "
                        f"(missing {', '.join(missing)})"
                    )
                else:
                    analysis.wpr.append(
                        WprMeta(
                            gpu=gpu,
                            line=line_no,
                            fb_size=raw_values["fbsize"],
                            wpr_start=raw_values["wprstart"],
                            wpr_end=raw_values["wprend"],
                            heap_offset=raw_values["heapoffset"],
                            heap_size=raw_values["heapsize"],
                            rsvd_start=raw_values.get("rsvdstart"),
                        )
                    )

        if "sec2_debug_fb_layout:" in lowered:
            raw_values = parse_key_values(
                FB_LAYOUT_VALUE_RE,
                FB_LAYOUT_ASSIGNMENT_RE,
                line,
                line_no,
                "FB layout",
                analysis,
            )
            if raw_values is None:
                raw_values = {}
            build = single_token_value(
                BUILD_VALUE_RE, BUILD_ASSIGNMENT_RE, line
            )
            status_value = single_token_value(
                STATUS_VALUE_RE, STATUS_ASSIGNMENT_RE, line
            )
            layout_rejected = bool(
                re.search(
                    r"\b(?:rejected|failed|refusing)\b", line, re.IGNORECASE
                )
                or (
                    status_value is not None
                    and status_value.lower()
                    in ("rejected", "failed", "unsafe", "error")
                )
            )
            layout_safe = bool(
                re.search(
                    r"SEC2_DEBUG_FB_LAYOUT:\s*validated\b",
                    line,
                    re.IGNORECASE,
                )
                and status_value is not None
                and status_value.lower() == "safe"
                and not layout_rejected
            )
            layout_required = (
                "fbsize",
                "protectedstart",
                "publicbytes",
                "capacityfloor",
                "reservedregionbytes",
                "regions",
            )
            missing_layout = [
                name for name in layout_required if name not in raw_values
            ]
            analysis.fb_layouts.append(
                FbLayout(
                    gpu=gpu,
                    line=line_no,
                    fb_size=raw_values.get("fbsize"),
                    protected_start=raw_values.get("protectedstart"),
                    public_bytes=raw_values.get("publicbytes"),
                    capacity_floor=raw_values.get("capacityfloor"),
                    reserved_region_bytes=raw_values.get("reservedregionbytes"),
                    regions=raw_values.get("regions"),
                    build=build,
                    safe=layout_safe,
                    rejected=layout_rejected,
                )
            )
            if not layout_rejected:
                if not layout_safe:
                    analysis.warnings.append(
                        f"line {line_no}: incomplete or unknown FB layout record"
                    )
                if missing_layout:
                    analysis.warnings.append(
                        f"line {line_no}: incomplete FB layout "
                        f"(missing {', '.join(missing_layout)})"
                    )
                if build != EXPECTED_SAFETY_BUILD:
                    analysis.warnings.append(
                        f"line {line_no}: FB layout build fingerprint is not "
                        f"{EXPECTED_SAFETY_BUILD}"
                    )

        if "sec2_debug_pma_guard:" in lowered:
            raw_values = parse_key_values(
                GUARD_VALUE_RE,
                GUARD_ASSIGNMENT_RE,
                line,
                line_no,
                "PMA guard",
                analysis,
            )
            if raw_values is None:
                raw_values = {}
            build = single_token_value(
                BUILD_VALUE_RE, BUILD_ASSIGNMENT_RE, line
            )
            status_value = single_token_value(
                STATUS_VALUE_RE, STATUS_ASSIGNMENT_RE, line
            )
            guard_refusing = bool(
                re.search(
                    r"\b(?:refusing|rejected|failed)\b", line, re.IGNORECASE
                )
                or (
                    status_value is not None
                    and status_value.lower()
                    in ("rejected", "failed", "unsafe", "error")
                )
            )
            guard_safe = bool(
                status_value is not None
                and status_value.lower() == "safe"
                and not guard_refusing
            )
            ambiguous_guard_fb_size = bool(
                "fbsize" in raw_values and "metafbsize" in raw_values
            )
            guard_fb_size = (
                None
                if ambiguous_guard_fb_size
                else raw_values.get("fbsize", raw_values.get("metafbsize"))
            )
            analysis.guards.append(
                Guard(
                    gpu=gpu,
                    line=line_no,
                    protected_start=raw_values.get("protectedstart"),
                    fb_size=guard_fb_size,
                    public_bytes=raw_values.get("publicbytes"),
                    pma_bytes=raw_values.get("pmabytes"),
                    build=build,
                    safe=guard_safe,
                    refusing=guard_refusing,
                )
            )
            if not guard_safe and not guard_refusing:
                analysis.warnings.append(
                    f"line {line_no}: incomplete or unknown PMA guard record"
                )
            if ambiguous_guard_fb_size:
                analysis.warnings.append(
                    f"line {line_no}: PMA guard contains both fbSize and "
                    f"metaFbSize"
                )
            if guard_safe:
                missing_guard = [
                    name
                    for name in (
                        "protectedstart",
                        "fbsize",
                        "publicbytes",
                        "pmabytes",
                    )
                    if name not in raw_values
                ]
                if missing_guard:
                    analysis.warnings.append(
                        f"line {line_no}: incomplete safe PMA guard "
                        f"(missing {', '.join(missing_guard)})"
                    )
                if build != EXPECTED_SAFETY_BUILD:
                    analysis.warnings.append(
                        f"line {line_no}: PMA guard build fingerprint is not "
                        f"{EXPECTED_SAFETY_BUILD}"
                    )

        if XID_31_RE.search(line):
            analysis.xid31.append(Event(gpu_from_xid_text(line), line_no))

        if (
            REGION_VIOLATION_RE.search(line)
            and not REGION_VIOLATION_NEGATION_RE.search(line)
            and CE_CONTEXT_RE.search(line)
        ):
            analysis.ce_region_violations.append(Event(gpu, line_no))

        if STALE_WPR_STATE_RE.search(line):
            analysis.stale_wpr_state.append(Event(gpu, line_no))

        if "registering" in lowered and any(
            marker in lowered for marker in ("late_pma", "late pma", "late-pma")
        ):
            raw_values = parse_key_values(
                PMA_VALUE_RE,
                PMA_ASSIGNMENT_RE,
                line,
                line_no,
                "late-PMA",
                analysis,
            )
            if raw_values is not None:
                missing = [
                    name for name in ("base", "limit") if name not in raw_values
                ]
                if missing:
                    analysis.warnings.append(
                        f"line {line_no}: incomplete late-PMA range "
                        f"(missing {', '.join(missing)})"
                    )
                else:
                    analysis.pma.append(
                        PmaRange(
                            gpu=gpu,
                            line=line_no,
                            base=raw_values["base"],
                            limit=raw_values["limit"],
                            candidate=raw_values.get("candidate"),
                        )
                    )

        if "_scrubwaitandsave" in lowered:
            if (
                SCRUB_TIMED_OUT_RE.search(line)
                and not SCRUB_TIMEOUT_NEGATION_RE.search(line)
            ):
                primary_scrub_timeout.append(Event(gpu, line_no))
            elif "nv_err_timeout" in lowered or "call timed out" in lowered:
                fallback_scrub_timeout.append(Event(gpu, line_no))

        affirmative_pma_success = bool(
            PMA_SUCCESS_RE.search(line) and not PMA_SUCCESS_NEGATION_RE.search(line)
        )
        if "pmaallocatepages" in lowered and not affirmative_pma_success and (
            "nv_err_no_memory" in lowered
            or "out of memory" in lowered
            or PMA_NO_MEMORY_CODE_RE.search(line)
        ):
            analysis.pma_oom.append(Event(gpu, line_no))

        if "ctxbufpoolreserve" in lowered:
            if "failed to reserve memory" in lowered:
                primary_context_oom.append(Event(gpu, line_no))
            elif "nv_err_no_memory" in lowered or "out of memory" in lowered:
                fallback_context_oom.append(Event(gpu, line_no))
        elif "rmmempoolreserve" in lowered and (
            "nv_err_no_memory" in lowered or "out of memory" in lowered
        ):
            fallback_context_oom.append(Event(gpu, line_no))

    # NVIDIA emits a human-readable line followed by an NV_ERR_* call trace for
    # the same timeout/OOM.  Prefer the former so the summary does not double
    # count one event, while still accepting logs that contain only call traces.
    analysis.scrub_timeouts = prefer_primary_events(
        primary_scrub_timeout, fallback_scrub_timeout
    )
    analysis.context_oom = prefer_primary_events(
        primary_context_oom, fallback_context_oom
    )

    # An Xid MMU fault is normally one printk line, but filtered/pasted logs may
    # split its details over subsequent lines.  Inspect a short bounded window.
    for offset, line in enumerate(lines):
        if record_limit_hit or analysis.record_count() >= MAX_RELEVANT_RECORDS:
            if not record_limit_hit:
                analysis.warnings.append(
                    f"relevant record count exceeds the {MAX_RELEVANT_RECORDS}-record limit"
                )
                record_limit_hit = True
            break
        if offset + 1 in oversized_lines:
            continue
        if not XID_31_RE.search(line):
            continue
        window = [line]
        joined = line
        xid_gpu = gpu_from_xid_text(line)
        if not complete_ce_fault(joined):
            for following in lines[offset + 1 : offset + 7]:
                if ANY_XID_RE.search(following):
                    break
                # Only join visibly wrapped continuation text.  A fresh NVRM
                # record or a different explicit GPU/PCI identity is not
                # evidence belonging to this Xid.
                following_gpu = gpu_from_text(following)
                if NVRM_RECORD_RE.search(following) or (
                    following_gpu != UNKNOWN_GPU and following_gpu != xid_gpu
                ):
                    break
                window.append(following)
                joined = " ".join(window)
                if complete_ce_fault(joined):
                    break
        joined = " ".join(window)
        address_match = FAULT_ADDRESS_RE.search(joined)
        engine_match = CE_ENGINE_RE.search(joined)
        if not (address_match and engine_match and PHYS_WRITE_RE.search(joined)):
            continue
        try:
            fault_address = parse_number(address_match.group(1))
        except ValueError as error:
            analysis.warnings.append(
                f"line {offset + 1}: malformed fault address ({error})"
            )
            continue
        analysis.faults.append(
            Fault(
                gpu=gpu_from_xid_text(joined),
                line=offset + 1,
                address=fault_address,
                engine=engine_match.group(1).upper(),
            )
        )

    if record_limit_hit:
        # Preserve bounded definite runtime/refusal evidence, but do not emit
        # thousands of untrusted records after the parser has declared the
        # source incomplete.
        analysis.wpr = []
        analysis.pma = []
        analysis.fb_layouts = [item for item in analysis.fb_layouts if item.rejected][:16]
        analysis.guards = [item for item in analysis.guards if item.refusing][:16]
        analysis.xid31 = analysis.xid31[:16]
        analysis.ce_region_violations = analysis.ce_region_violations[:16]
        analysis.faults = analysis.faults[:16]
        analysis.scrub_timeouts = analysis.scrub_timeouts[:16]
        analysis.pma_oom = analysis.pma_oom[:16]
        analysis.context_oom = analysis.context_oom[:16]
        analysis.stale_wpr_state = analysis.stale_wpr_state[:16]
        limit_warning = (
            f"relevant record count exceeds the {MAX_RELEVANT_RECORDS}-record limit"
        )
        analysis.warnings = analysis.warnings[:64]
        if limit_warning not in analysis.warnings:
            analysis.warnings.append(limit_warning)
    else:
        validate_ranges(analysis)
    return analysis


def complete_ce_fault(text: str) -> bool:
    return bool(
        FAULT_ADDRESS_RE.search(text)
        and CE_ENGINE_RE.search(text)
        and PHYS_WRITE_RE.search(text)
    )


def prefer_primary_events(primary: list[Event], fallback: list[Event]) -> list[Event]:
    """Keep fallback call traces only when no nearby primary message exists."""
    selected: list[Event] = []
    for event in sorted(primary, key=lambda item: item.line):
        duplicate = any(
            item.gpu == event.gpu and abs(item.line - event.line) <= 2
            for item in selected[-2:]
        )
        if not duplicate:
            selected.append(event)
    for event in fallback:
        duplicate = any(
            item.gpu == event.gpu and abs(item.line - event.line) <= 2
            for item in selected
        )
        if not duplicate:
            selected.append(event)
    return sorted(selected, key=lambda item: item.line)


def validate_ranges(analysis: Analysis) -> None:
    numbered_gpus = {
        record.gpu
        for records in (analysis.wpr, analysis.fb_layouts, analysis.guards)
        for record in records
        if record.gpu.startswith("GPU")
    }
    if len(numbered_gpus) > 1:
        for record_name, records in (
            ("WPR metadata", analysis.wpr),
            ("FB layout", analysis.fb_layouts),
            ("PMA guard", analysis.guards),
        ):
            for record in records:
                if record.gpu == UNKNOWN_GPU:
                    analysis.warnings.append(
                        f"line {record.line}: unattributed {record_name} in a "
                        f"multi-GPU log"
                    )
    for meta in analysis.wpr:
        if meta.fb_size == 0:
            analysis.layout_errors.append(f"line {meta.line}: fbSize is zero")
        if meta.wpr_start == 0:
            analysis.layout_errors.append(f"line {meta.line}: WPR start is zero")
        if meta.wpr_end <= meta.wpr_start:
            analysis.layout_errors.append(
                f"line {meta.line}: WPR end is not above WPR start"
            )
        if meta.heap_size == 0:
            analysis.layout_errors.append(f"line {meta.line}: heap size is zero")
        if meta.wpr_end > meta.fb_size:
            analysis.layout_errors.append(f"line {meta.line}: WPR end exceeds fbSize")
        if meta.heap_offset + meta.heap_size > meta.fb_size:
            analysis.layout_errors.append(f"line {meta.line}: heap end exceeds fbSize")
        if meta.heap_offset < meta.wpr_start or meta.heap_offset + meta.heap_size > meta.wpr_end:
            analysis.layout_errors.append(
                f"line {meta.line}: heap is not fully contained in WPR"
            )
        if meta.rsvd_start is not None and not (0 < meta.rsvd_start < meta.fb_size):
            analysis.layout_errors.append(
                f"line {meta.line}: rsvdStart is outside (0, fbSize)"
            )
        if meta.rsvd_start is not None and meta.rsvd_start > meta.wpr_start:
            analysis.layout_errors.append(
                f"line {meta.line}: rsvdStart is above WPR start"
            )
    for layout in analysis.fb_layouts:
        values = (
            layout.fb_size,
            layout.protected_start,
            layout.public_bytes,
            layout.capacity_floor,
            layout.reserved_region_bytes,
            layout.regions,
        )
        if not layout.safe or any(value is None for value in values):
            continue
        assert layout.fb_size is not None
        assert layout.protected_start is not None
        assert layout.public_bytes is not None
        assert layout.capacity_floor is not None
        assert layout.reserved_region_bytes is not None
        assert layout.regions is not None
        if layout.fb_size <= MAX_RESERVED_BYTES:
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout fbSize is too small"
            )
        if not (0 < layout.protected_start < layout.fb_size):
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout protectedStart is outside "
                f"(0, fbSize)"
            )
        if not (1 <= layout.regions <= MAX_FB_REGIONS):
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout region count is outside "
                f"[1, {MAX_FB_REGIONS}]"
            )
        if layout.public_bytes + layout.reserved_region_bytes != layout.fb_size:
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout public + reserved bytes "
                f"does not equal fbSize"
            )
        if layout.capacity_floor != layout.fb_size - MAX_RESERVED_BYTES:
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout capacityFloor is not "
                f"fbSize - {fmt_addr(MAX_RESERVED_BYTES)}"
            )
        if layout.public_bytes < layout.capacity_floor:
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout publicBytes is below capacityFloor"
            )
        if layout.public_bytes > layout.protected_start:
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout publicBytes exceeds protectedStart"
            )
        if (
            layout.reserved_region_bytes
            < layout.fb_size - layout.protected_start
        ):
            analysis.layout_errors.append(
                f"line {layout.line}: FB layout reserved bytes do not cover "
                f"the protected top range"
            )
    for guard in analysis.guards:
        values = (
            guard.fb_size,
            guard.protected_start,
            guard.public_bytes,
            guard.pma_bytes,
        )
        if not guard.safe or any(value is None for value in values):
            continue
        assert guard.fb_size is not None
        assert guard.protected_start is not None
        assert guard.public_bytes is not None
        assert guard.pma_bytes is not None
        if guard.fb_size <= MAX_RESERVED_BYTES:
            analysis.layout_errors.append(
                f"line {guard.line}: PMA guard fbSize is too small"
            )
        if not (0 < guard.protected_start < guard.fb_size):
            analysis.layout_errors.append(
                f"line {guard.line}: PMA guard protectedStart is outside "
                f"(0, fbSize)"
            )
        if guard.public_bytes == 0 or guard.public_bytes > guard.protected_start:
            analysis.layout_errors.append(
                f"line {guard.line}: PMA guard publicBytes is outside "
                f"(0, protectedStart]"
            )
        if guard.public_bytes < guard.fb_size - MAX_RESERVED_BYTES:
            analysis.layout_errors.append(
                f"line {guard.line}: PMA guard publicBytes is below capacity floor"
            )
        if guard.pma_bytes != guard.public_bytes:
            analysis.layout_errors.append(
                f"line {guard.line}: PMA bytes do not equal guard public bytes"
            )
    wpr_by_gpu: dict[str, list[WprMeta]] = defaultdict(list)
    for meta in analysis.wpr:
        wpr_by_gpu[meta.gpu].append(meta)
    for metas in wpr_by_gpu.values():
        metas.sort(key=lambda item: item.line)
    wpr_lines_by_gpu = {
        gpu: [meta.line for meta in metas]
        for gpu, metas in wpr_by_gpu.items()
    }
    for pma in analysis.pma:
        if pma.limit < pma.base:
            analysis.layout_errors.append(f"line {pma.line}: PMA limit is below its base")
            continue
        metas = wpr_by_gpu.get(pma.gpu, [])
        if (
            not metas
            and pma.gpu == UNKNOWN_GPU
            and len(analysis.wpr) == 1
            and len(numbered_gpus) == 1
        ):
            metas = analysis.wpr
            meta_lines = [analysis.wpr[0].line]
        else:
            meta_lines = wpr_lines_by_gpu.get(pma.gpu, [])
        preceding_index = bisect_right(meta_lines, pma.line) - 1
        if preceding_index < 0:
            reason = "has no preceding WPR metadata" if metas else "cannot be attributed to WPR metadata"
            analysis.warnings.append(f"line {pma.line}: PMA range {reason}")
            continue
        meta = metas[preceding_index]
        if meta is not None and (pma.base >= meta.fb_size or pma.limit >= meta.fb_size):
            analysis.layout_errors.append(
                f"line {pma.line}: PMA range exceeds fbSize from line {meta.line}"
            )


def alias_map(analysis: Analysis) -> tuple[dict[str, str], dict[str, list[str]]]:
    identities = {
        record.gpu
        for records in (
            analysis.wpr,
            analysis.pma,
            analysis.fb_layouts,
            analysis.guards,
            analysis.xid31,
            analysis.ce_region_violations,
            analysis.faults,
            analysis.scrub_timeouts,
            analysis.pma_oom,
            analysis.context_oom,
            analysis.stale_wpr_state,
        )
        for record in records
    }
    numbered = sorted(identity for identity in identities if identity.startswith("GPU"))
    pci = sorted(identity for identity in identities if identity.startswith("PCI:"))
    aliases = {identity: identity for identity in identities}
    labels: dict[str, list[str]] = defaultdict(list)

    # Current NVIDIA logs identify normal RM messages as GPU<n>, while Xid lines
    # carry only the PCI BDF.  With exactly one identity of each kind in the
    # supplied excerpt, joining them is deterministic within that excerpt.
    if len(numbered) == 1 and len(pci) == 1:
        aliases[pci[0]] = numbered[0]
        labels[numbered[0]].append(pci[0])
    if UNKNOWN_GPU in identities:
        if len(numbered) == 1:
            aliases[UNKNOWN_GPU] = numbered[0]
        elif not numbered and len(pci) == 1:
            aliases[UNKNOWN_GPU] = pci[0]
    return aliases, labels


def group_records(analysis: Analysis) -> tuple[dict[str, dict[str, list]], dict[str, list[str]]]:
    aliases, labels = alias_map(analysis)
    grouped: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    for name in (
        "wpr",
        "pma",
        "fb_layouts",
        "guards",
        "xid31",
        "ce_region_violations",
        "faults",
        "scrub_timeouts",
        "pma_oom",
        "context_oom",
        "stale_wpr_state",
    ):
        for record in getattr(analysis, name):
            grouped[aliases.get(record.gpu, record.gpu)][name].append(record)
    return grouped, labels


def inferred_required_gpus(analysis: Analysis) -> list[str]:
    grouped, _ = group_records(analysis)
    return sorted(
        gpu
        for gpu, records in grouped.items()
        if (
            records.get("wpr")
            or records.get("pma")
            or records.get("fb_layouts")
            or records.get("guards")
        )
    )


def required_anchor_issues(
    analysis: Analysis,
    required_gpus: Iterable[str],
    expected_fb_sizes: Optional[dict[str, int]] = None,
) -> list[str]:
    grouped, _ = group_records(analysis)
    expected_fb_sizes = expected_fb_sizes or {}
    issues: list[str] = []
    for gpu in dict.fromkeys(required_gpus):
        records = grouped.get(gpu, {})
        metas = records.get("wpr", [])
        latest_meta = max(metas, key=lambda item: item.line) if metas else None
        layouts = [
            layout for layout in records.get("fb_layouts", []) if layout.safe
        ]
        later_layouts = (
            [layout for layout in layouts if layout.line > latest_meta.line]
            if latest_meta
            else []
        )
        latest_layout = (
            max(later_layouts, key=lambda item: item.line)
            if later_layouts
            else None
        )
        guards = [guard for guard in records.get("guards", []) if guard.safe]
        later_guards = (
            [guard for guard in guards if guard.line > latest_layout.line]
            if latest_layout
            else []
        )
        latest_guard = (
            max(later_guards, key=lambda item: item.line)
            if later_guards
            else None
        )
        expected_fb_size = expected_fb_sizes.get(gpu)
        if (
            latest_meta is not None
            and expected_fb_size is not None
            and latest_meta.fb_size != expected_fb_size
        ):
            issues.append(
                f"{gpu}: latest WPR fbSize {fmt_addr(latest_meta.fb_size)} "
                f"does not match expected {fmt_addr(expected_fb_size)}"
            )
            continue
        coherent = bool(
            latest_meta
            and latest_meta.rsvd_start is not None
            and latest_layout
            and latest_layout.fb_size == latest_meta.fb_size
            and latest_layout.protected_start == latest_meta.rsvd_start
            and latest_layout.public_bytes is not None
            and latest_layout.capacity_floor is not None
            and latest_layout.reserved_region_bytes is not None
            and latest_layout.regions is not None
            and latest_layout.build == EXPECTED_SAFETY_BUILD
            and latest_guard
            and latest_guard.protected_start == latest_meta.rsvd_start
            and latest_guard.fb_size == latest_meta.fb_size
            and latest_guard.public_bytes is not None
            and latest_guard.pma_bytes == latest_guard.public_bytes
            and 0 < latest_guard.public_bytes <= latest_layout.public_bytes
            and latest_guard.public_bytes >= latest_layout.capacity_floor
            and latest_guard.build == EXPECTED_SAFETY_BUILD
            and (
                expected_fb_size is None
                or (
                    latest_layout.fb_size == expected_fb_size
                    and latest_guard.fb_size == expected_fb_size
                )
            )
        )
        if not coherent:
            expected_suffix = (
                ""
                if expected_fb_size is None
                else f", fbSize={fmt_addr(expected_fb_size)}"
            )
            issues.append(
                f"{gpu}: missing coherent WPR + native FB layout + PMA guard chain "
                f"(required build={EXPECTED_SAFETY_BUILD}{expected_suffix})"
            )
    return issues


def half_open_overlap(
    first_start: int, first_end: int, second_start: int, second_end: int
) -> Optional[tuple[int, int]]:
    start = max(first_start, second_start)
    end = min(first_end, second_end)
    return (start, end) if start < end else None


def find_overlaps(analysis: Analysis) -> list[Finding]:
    grouped, _ = group_records(analysis)
    findings: list[Finding] = []
    for gpu, records in grouped.items():
        metas: list[WprMeta] = sorted(records["wpr"], key=lambda item: item.line)
        meta_lines = [meta.line for meta in metas]
        for pma in records["pma"]:
            if pma.limit < pma.base or not metas:
                continue
            # If a file spans multiple initializations, use the metadata closest
            # to this registration instead of comparing unrelated boots.
            preceding_index = bisect_right(meta_lines, pma.line) - 1
            if preceding_index < 0:
                continue
            meta = metas[preceding_index]
            pma_end = pma.limit + 1
            if meta.rsvd_start is not None and meta.fb_size > meta.rsvd_start:
                overlap = half_open_overlap(
                    pma.base, pma_end, meta.rsvd_start, meta.fb_size
                )
                if overlap:
                    findings.append(
                        Finding(gpu, "PMA/protected", overlap[0], overlap[1])
                    )
            if meta.wpr_end > meta.wpr_start:
                overlap = half_open_overlap(
                    pma.base, pma_end, meta.wpr_start, meta.wpr_end
                )
                if overlap:
                    findings.append(
                        Finding(gpu, "PMA/WPR", overlap[0], overlap[1])
                    )
            if meta.heap_size > 0:
                overlap = half_open_overlap(
                    pma.base,
                    pma_end,
                    meta.heap_offset,
                    meta.heap_offset + meta.heap_size,
                )
                if overlap:
                    findings.append(
                        Finding(gpu, "PMA/heap", overlap[0], overlap[1])
                    )
    return findings


def fmt_addr(value: int) -> str:
    return f"0x{value:016x}"


def fmt_size(value: int) -> str:
    units = ((1 << 30, "GiB"), (1 << 20, "MiB"), (1 << 10, "KiB"))
    for divisor, suffix in units:
        if value >= divisor:
            scaled_hundredths = (value * 100 + divisor // 2) // divisor
            return (
                f"{scaled_hundredths // 100}."
                f"{scaled_hundredths % 100:02d} {suffix}"
            )
    return f"{value} B"


def fmt_lines(events: Iterable[Event]) -> str:
    line_numbers = [str(event.line) for event in events]
    preview = ", ".join(line_numbers[:5])
    if len(line_numbers) > 5:
        preview += ", ..."
    return preview


def address_membership(
    address: int, fault_line: int, records: dict[str, list]
) -> list[str]:
    memberships: list[str] = []
    preceding_metas = [meta for meta in records["wpr"] if meta.line <= fault_line]
    latest_meta = (
        max(preceding_metas, key=lambda item: item.line)
        if preceding_metas
        else None
    )
    relevant_pma = [
        pma
        for pma in records["pma"]
        if pma.line <= fault_line
        and (latest_meta is None or pma.line >= latest_meta.line)
    ]
    if any(pma.base <= address <= pma.limit for pma in relevant_pma):
        memberships.append("late-PMA")
    if (
        latest_meta is not None
        and latest_meta.rsvd_start is not None
        and latest_meta.rsvd_start <= address < latest_meta.fb_size
    ):
        memberships.append("protected")
    if (
        latest_meta is not None
        and latest_meta.wpr_start <= address < latest_meta.wpr_end
    ):
        memberships.append("WPR")
    if (
        latest_meta is not None
        and latest_meta.heap_size > 0
        and latest_meta.heap_offset
        <= address
        < latest_meta.heap_offset + latest_meta.heap_size
    ):
        memberships.append("heap")
    return memberships


def render_report(
    analysis: Analysis,
    source: str,
    required_gpus: Optional[Iterable[str]] = None,
    expected_fb_sizes: Optional[dict[str, int]] = None,
) -> tuple[str, int]:
    if required_gpus is None:
        required_gpus = inferred_required_gpus(analysis)
    anchor_issues = required_anchor_issues(
        analysis, required_gpus, expected_fb_sizes
    )
    if not analysis.has_records():
        details = [
            f"Kernel log analysis: {source}",
            "Result: NO ANALYZABLE RECORDS",
            "No WPR metadata, PMA guard, late-PMA registration, Xid 31, "
            "native FB layout, CE region violation, scrub timeout, PMA/context "
            "OOM, or stale WPR2 state record was parsed.",
        ]
        if anchor_issues:
            details.append("Required fixed-driver anchors:")
            details.extend(f"  - {issue}" for issue in anchor_issues)
        if analysis.warnings:
            details.append("Warnings:")
            details.extend(f"  - {warning}" for warning in analysis.warnings)
        evidence_class = "INCOMPLETE" if anchor_issues or analysis.warnings else "EMPTY"
        details.append(f"Evidence class: {evidence_class}")
        details.append(f"Exit status: {EXIT_NO_DATA}")
        return "\n".join(details), EXIT_NO_DATA

    findings = find_overlaps(analysis)
    grouped, labels = group_records(analysis)
    runtime_hazard = any(
        (
            analysis.xid31,
            analysis.ce_region_violations,
            analysis.faults,
            analysis.scrub_timeouts,
            analysis.pma_oom,
            analysis.context_oom,
            analysis.stale_wpr_state,
        )
    )
    guard_refusal = any(guard.refusing for guard in analysis.guards)
    layout_rejection = any(layout.rejected for layout in analysis.fb_layouts)
    if (
        findings
        or runtime_hazard
        or guard_refusal
        or layout_rejection
        or analysis.layout_errors
    ):
        status = EXIT_HAZARD
        result = "HAZARD EVIDENCE FOUND"
    elif anchor_issues or analysis.warnings:
        status = EXIT_NO_DATA
        result = "INDETERMINATE: INCOMPLETE OR MISSING SAFETY DATA"
    else:
        status = EXIT_OK
        result = "no checked hazard found"
    output = [f"Kernel log analysis: {source}", f"Result: {result}"]

    for gpu in sorted(grouped, key=lambda item: (item == UNKNOWN_GPU, item)):
        records = grouped[gpu]
        alias_suffix = ""
        if labels.get(gpu):
            alias_suffix = f" (also {', '.join(labels[gpu])}; inferred from single-GPU excerpt)"
        output.extend(("", f"{gpu}{alias_suffix}"))

        for meta in records["wpr"]:
            output.append(
                f"  WPR meta (line {meta.line}): fbSize={fmt_addr(meta.fb_size)} "
                f"({fmt_size(meta.fb_size)})"
            )
            if meta.rsvd_start is not None:
                output.append(
                    f"    rsvdStart={fmt_addr(meta.rsvd_start)} "
                    f"=> protected=[{fmt_addr(meta.rsvd_start)}, "
                    f"{fmt_addr(meta.fb_size)})"
                )
            else:
                output.append("    rsvdStart=not logged")
            output.append(
                f"    wprStart={fmt_addr(meta.wpr_start)} "
                f"wprEnd={fmt_addr(meta.wpr_end)} "
                f"=> [{fmt_addr(meta.wpr_start)}, {fmt_addr(meta.wpr_end)})"
            )
            output.append(
                f"    heapOffset={fmt_addr(meta.heap_offset)} "
                f"heapSize={fmt_addr(meta.heap_size)} ({fmt_size(meta.heap_size)}) "
                f"=> [{fmt_addr(meta.heap_offset)}, "
                f"{fmt_addr(meta.heap_offset + meta.heap_size)})"
            )

        for pma in records["pma"]:
            candidate = "?" if pma.candidate is None else str(pma.candidate)
            size = pma.limit - pma.base + 1 if pma.limit >= pma.base else 0
            output.append(
                f"  late-PMA candidate {candidate} (line {pma.line}): "
                f"base={fmt_addr(pma.base)} limit={fmt_addr(pma.limit)} "
                f"=> [{fmt_addr(pma.base)}, {fmt_addr(pma.limit)}] "
                f"({fmt_size(size)})"
            )

        for layout in records["fb_layouts"]:
            state = "safe" if layout.safe else "REJECTED" if layout.rejected else "unknown"
            fb_size = "?" if layout.fb_size is None else fmt_addr(layout.fb_size)
            protected = (
                "?"
                if layout.protected_start is None
                else fmt_addr(layout.protected_start)
            )
            public = (
                "?" if layout.public_bytes is None else fmt_addr(layout.public_bytes)
            )
            floor = (
                "?" if layout.capacity_floor is None else fmt_addr(layout.capacity_floor)
            )
            reserved = (
                "?"
                if layout.reserved_region_bytes is None
                else fmt_addr(layout.reserved_region_bytes)
            )
            regions = "?" if layout.regions is None else str(layout.regions)
            build = "?" if layout.build is None else layout.build
            output.append(
                f"  native FB layout (line {layout.line}): state={state} "
                f"fbSize={fb_size} protectedStart={protected} "
                f"publicBytes={public} capacityFloor={floor} "
                f"reservedRegionBytes={reserved} regions={regions} build={build}"
            )

        for guard in records["guards"]:
            state = "safe" if guard.safe else "REFUSED" if guard.refusing else "unknown"
            protected = (
                "?" if guard.protected_start is None else fmt_addr(guard.protected_start)
            )
            fb_size = "?" if guard.fb_size is None else fmt_addr(guard.fb_size)
            public = (
                "?" if guard.public_bytes is None else fmt_addr(guard.public_bytes)
            )
            pma = "?" if guard.pma_bytes is None else fmt_addr(guard.pma_bytes)
            build = "?" if guard.build is None else guard.build
            output.append(
                f"  PMA guard (line {guard.line}): state={state} "
                f"fbSize={fb_size} protectedStart={protected} "
                f"publicBytes={public} pmaBytes={pma} build={build}"
            )

        for fault in records["faults"]:
            membership = address_membership(fault.address, fault.line, records)
            location = f"; inside {', '.join(membership)}" if membership else ""
            output.append(
                f"  Xid 31 {fault.engine} PHYS_WRITE (line {fault.line}): "
                f"{fmt_addr(fault.address)}{location}"
            )

        event_labels = (
            ("Xid 31", records["xid31"]),
            ("CE REGION_VIOLATION", records["ce_region_violations"]),
            ("scrub timeout", records["scrub_timeouts"]),
            ("PMA OOM", records["pma_oom"]),
            ("context OOM", records["context_oom"]),
            ("stale WPR2 state", records["stale_wpr_state"]),
        )
        for label, events in event_labels:
            if events:
                output.append(
                    f"  {label}: {len(events)} occurrence(s) (line(s) {fmt_lines(events)})"
                )

        gpu_findings = [finding for finding in findings if finding.gpu == gpu]
        for finding in gpu_findings:
            output.append(
                f"  ERROR {finding.kind} overlap: "
                f"[{fmt_addr(finding.overlap_start)}, {fmt_addr(finding.overlap_end)}) "
                f"({fmt_size(finding.overlap_end - finding.overlap_start)})"
            )

    if anchor_issues:
        output.extend(("", "Required fixed-driver anchors:"))
        output.extend(f"  - {issue}" for issue in anchor_issues)

    if analysis.layout_errors:
        output.extend(("", "Invalid safety-critical layout data:"))
        output.extend(f"  - {error}" for error in analysis.layout_errors)

    if analysis.warnings:
        output.extend(("", "Warnings:"))
        output.extend(f"  - {warning}" for warning in analysis.warnings)

    output.extend(
        (
            "",
            "Range convention: late-PMA limit is inclusive; "
            "protected/WPR/heap end is exclusive.",
            "Evidence class: "
            + (
                "HAZARD"
                if status == EXIT_HAZARD
                else "INCOMPLETE"
                if status == EXIT_NO_DATA
                else "CLEAN"
            ),
            f"Exit status: {status}",
        )
    )
    return "\n".join(output), status


SELF_TEST_CURRENT_64_GIB = """\
[    9.320134] host kernel: NVRM: GPU1 _kgspBootGspRm: SEC2_DEBUG: WPR meta updated fbSize=0x0000001000000000 wprStart=0x0000000ff7300000 wprEnd=0x0000000ffff00000 heapOffset=0x0000000ff7400000 heapSize=0x0000000006e00000
[   10.140139] host kernel: NVRM: GPU1 memmgrSec2DebugLateExtendHighPmaRegion: SEC2_DEBUG_LATE_PMA: registering candidate=6 base=0xff7200000 limit=0xfffffffff cand_base=0xff7200000 cand_limit=0xfffffffff pma_region_id=1
[94408.055174] host kernel: NVRM: Xid (PCI:0000:03:00): 31, pid=658, name=(udev-worker), channel 0x01000001, intr 00000000. MMU Fault: ENGINE CE2 HUBCLIENT_HSCE2 faulted @ 0xf_f9200000. Fault is of type FAULT_INFO_TYPE_REGION_VIOLATION ACCESS_TYPE_PHYS_WRITE
[94437.859199] host kernel: NVRM: GPU1 _scrubWaitAndSave: Timed out when waiting for scrub jobs to finish.
[94496.117337] host kernel: NVRM: GPU1 nvAssertOkFailedNoLog: Assertion failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from pmaAllocatePages(...) @ pool_alloc.c:270
[94496.117410] host kernel: NVRM: GPU1 ctxBufPoolReserve: Failed to reserve memory. trimming all pools
"""


def run_self_test() -> int:
    failures: list[str] = []

    current = parse_log(SELF_TEST_CURRENT_64_GIB)
    current_findings = find_overlaps(current)
    report, status = render_report(current, "self-test/current-64GiB")
    checks = {
        "current log status": status == EXIT_HAZARD,
        "64 GiB fbSize": len(current.wpr) == 1 and current.wpr[0].fb_size == 0x1000000000,
        "late-PMA range": len(current.pma) == 1
        and current.pma[0].base == 0xFF7200000
        and current.pma[0].limit == 0xFFFFFFFFF,
        "physical-write address": len(current.faults) == 1
        and current.faults[0].address == 0xFF9200000,
        "PMA/WPR overlap": any(item.kind == "PMA/WPR" for item in current_findings),
        "PMA/heap overlap": any(item.kind == "PMA/heap" for item in current_findings),
        "fault membership": "inside late-PMA, WPR, heap" in report,
        "generic Xid 31": len(current.xid31) == 1,
        "CE region violation": len(current.ce_region_violations) == 1,
        "scrub/PMA/context chain": len(current.scrub_timeouts) == 1
        and len(current.pma_oom) == 1
        and len(current.context_oom) == 1,
    }
    failures.extend(name for name, passed in checks.items() if not passed)

    broad_runtime_faults = parse_log(
        "NVRM: GPU7 _scrubWaitAndSave: Timed\t out after 30 seconds\n"
        "NVRM: GPU7 pmaAllocatePages(request) returned status 0x00000051\n"
    )
    _, broad_runtime_status = render_report(
        broad_runtime_faults, "self-test/broad-runtime-faults", []
    )
    if (
        broad_runtime_status != EXIT_HAZARD
        or len(broad_runtime_faults.scrub_timeouts) != 1
        or len(broad_runtime_faults.pma_oom) != 1
    ):
        failures.append("wide scrub timeout and PMA 0x51 matching")

    negated_runtime = parse_log(
        "NVRM: GPU7 _scrubWaitAndSave: not timed out\n"
        "NVRM: GPU7 pmaAllocatePages succeeded; diagnostic-mask=0x51\n"
        "NVRM: GPU7 CE2 NO_REGION_VIOLATION ACCESS_TYPE_PHYS_WRITE\n"
        "NVRM: GPU7 CE2 REGION_VIOLATION_CLEARED ACCESS_TYPE_PHYS_WRITE\n"
        "NVRM: GPU7 CE2 did not report REGION_VIOLATION ACCESS_TYPE_PHYS_WRITE\n"
    )
    _, negated_runtime_status = render_report(
        negated_runtime, "self-test/negated-runtime", []
    )
    if (
        negated_runtime_status != EXIT_NO_DATA
        or negated_runtime.scrub_timeouts
        or negated_runtime.pma_oom
        or negated_runtime.ce_region_violations
    ):
        failures.append("negated or cleared runtime text is not fault evidence")

    negated_success_oom = parse_log(
        "NVRM: GPU7 pmaAllocatePages was not successful, returned status 0x51\n"
    )
    _, negated_success_oom_status = render_report(
        negated_success_oom, "self-test/negated-success-PMA-OOM", []
    )
    if negated_success_oom_status != EXIT_HAZARD or len(negated_success_oom.pma_oom) != 1:
        failures.append("negated PMA success does not suppress no-memory evidence")

    old_wpr_zero = parse_log(
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        "fbSize=0x1000000000 wprStart=0 wprEnd=0xffff00000 "
        "heapOffset=0xff7400000 heapSize=0x6e00000\n"
    )
    _, old_wpr_zero_status = render_report(
        old_wpr_zero, "self-test/old-WPR-zero-start", []
    )
    if (
        old_wpr_zero_status != EXIT_HAZARD
        or not any("WPR start is zero" in item for item in old_wpr_zero.layout_errors)
    ):
        failures.append("old-format WPR start zero is a layout hazard")

    huge_decimal = "9" * 5000
    huge_numeric_text = (
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        f"fbSize={huge_decimal} wprStart=1 wprEnd=2 "
        "heapOffset=1 heapSize=1\n"
    )
    huge_numeric = parse_log(huge_numeric_text)
    huge_report, huge_numeric_status = render_report(
        huge_numeric, "self-test/overlong-numeric", []
    )
    if (
        huge_numeric_status != EXIT_NO_DATA
        or "malformed WPR metadata numeric field" not in huge_report
    ):
        failures.append("overlong numeric field is controlled indeterminate data")

    _, huge_plus_xid_status = render_report(
        parse_log(
            huge_numeric_text
            + "NVRM: Xid (PCI:0000:03:00): 31, generic MMU fault\n"
        ),
        "self-test/overlong-numeric-plus-Xid31",
        [],
    )
    if huge_plus_xid_status != EXIT_HAZARD:
        failures.append("Xid 31 takes priority over an overlong numeric field")

    huge_gpu_index_text = f"NVRM: GPU{huge_decimal} ordinary message\n"
    _, huge_gpu_index_status = render_report(
        parse_log(huge_gpu_index_text),
        "self-test/overlong-GPU-index",
        [],
    )
    _, huge_gpu_plus_ce_status = render_report(
        parse_log(
            huge_gpu_index_text
            + "NVRM: HUBCLIENT_HSCE2 REGION_VIOLATION ACCESS_TYPE_VIRT_READ\n"
        ),
        "self-test/overlong-GPU-index-plus-CE",
        [],
    )
    if (
        huge_gpu_index_status != EXIT_NO_DATA
        or huge_gpu_plus_ce_status != EXIT_HAZARD
    ):
        failures.append("overlong GPU index cannot crash or mask a CE hazard")

    oversized_line = parse_log("X" * (MAX_LOG_LINE_CHARS + 1) + "\n")
    _, oversized_line_status = render_report(
        oversized_line, "self-test/oversized-line", []
    )
    if (
        oversized_line_status != EXIT_NO_DATA
        or not any("record exceeds" in warning for warning in oversized_line.warnings)
    ):
        failures.append("oversized line is controlled indeterminate data")

    wpr_with_rsvd = (
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        "fbSize=0x1000000000 rsvdStart=0xff7000000 "
        "wprStart=0xff7300000 wprEnd=0xffff00000 "
        "heapOffset=0xff7400000 heapSize=0x6e00000\n"
    )
    clean_with_rsvd = parse_log(
        wpr_with_rsvd
        + "NVRM: GPU0 SEC2_DEBUG_LATE_PMA: registering candidate=4 "
        "base=0x200000000 limit=0xff6ffffff\n"
    )
    _, clean_status = render_report(clean_with_rsvd, "self-test/rsvdStart")
    if clean_status != EXIT_NO_DATA or clean_with_rsvd.wpr[0].rsvd_start != 0xFF7000000:
        failures.append("rsvdStart parsed but fixed-driver anchors required")

    _, best_effort_status = render_report(
        clean_with_rsvd, "self-test/best-effort", []
    )
    if best_effort_status != EXIT_OK:
        failures.append("explicit best-effort status")

    _, wpr_only_status = render_report(parse_log(wpr_with_rsvd), "self-test/WPR-only")
    if wpr_only_status != EXIT_NO_DATA:
        failures.append("WPR-only is not a safety proof")

    protected_only = parse_log(
        wpr_with_rsvd
        + "NVRM: GPU0 SEC2_DEBUG_LATE_PMA: registering candidate=4 "
        "base=0xff7100000 limit=0xff72fffff\n"
    )
    protected_findings = find_overlaps(protected_only)
    _, protected_status = render_report(protected_only, "self-test/protected-only")
    protected_kinds = {item.kind for item in protected_findings}
    if protected_status != EXIT_HAZARD or protected_kinds != {"PMA/protected"}:
        failures.append("non-WPR protected overlap")

    safe_layout = (
        "NVRM: GPU0 SEC2_DEBUG_FB_LAYOUT: validated "
        "fbSize=0x1000000000 protectedStart=0xff7000000 "
        "publicBytes=0xff0000000 capacityFloor=0xf80000000 "
        "reservedRegionBytes=0x10000000 regions=3 status=safe "
        f"build={EXPECTED_SAFETY_BUILD}\n"
    )
    safe_guard = (
        "NVRM: GPU0 SEC2_DEBUG_PMA_GUARD: fbSize=0x1000000000 "
        "protectedStart=0xff7000000 publicBytes=0xff0000000 "
        "pmaBytes=0xff0000000 status=safe "
        f"build={EXPECTED_SAFETY_BUILD}\n"
    )
    _, required_ok = render_report(
        parse_log(wpr_with_rsvd + safe_layout + safe_guard),
        "self-test/required-anchor",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if required_ok != EXIT_OK:
        failures.append("coherent required anchor with exact expected fbSize")

    heap_clipped_guard = safe_guard.replace("0xff0000000", "0xfe0000000")
    _, heap_clipped_guard_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + heap_clipped_guard),
        "self-test/heap-clipped-final-public",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if heap_clipped_guard_status != EXIT_OK:
        failures.append("heap-clipped PMA public may be below native public")

    chain_cases_expected_indeterminate = {
        "missing native FB layout": wpr_with_rsvd + safe_guard,
        "guard before native FB layout": wpr_with_rsvd + safe_guard + safe_layout,
        "new layout after completed chain": (
            wpr_with_rsvd + safe_layout + safe_guard + safe_layout
        ),
        "layout/WPR protectedStart mismatch": (
            wpr_with_rsvd
            + safe_layout.replace("protectedStart=0xff7000000", "protectedStart=0xff6000000")
            + safe_guard
        ),
        "guard public exceeds native public": (
            wpr_with_rsvd
            + safe_layout
            + safe_guard.replace("0xff0000000", "0xff1000000")
        ),
        "safe guard missing pmaBytes": (
            wpr_with_rsvd
            + safe_layout
            + safe_guard.replace("pmaBytes=0xff0000000 ", "")
        ),
    }
    for case_name, case_text in chain_cases_expected_indeterminate.items():
        _, case_status = render_report(
            parse_log(case_text),
            f"self-test/{case_name}",
            ["GPU0"],
            {"GPU0": 0x1000000000},
        )
        if case_status != EXIT_NO_DATA:
            failures.append(f"{case_name} is indeterminate")

    malformed_assignment_cases = {
        "malformed duplicate WPR field": (
            wpr_with_rsvd.rstrip("\n")
            + " fbSize=bogus\n"
            + safe_layout
            + safe_guard
        ),
        "malformed duplicate layout field": (
            wpr_with_rsvd
            + safe_layout.rstrip("\n")
            + " publicBytes=bogus\n"
            + safe_guard
        ),
        "malformed duplicate guard field": (
            wpr_with_rsvd
            + safe_layout
            + safe_guard.rstrip("\n")
            + " pmaBytes=bogus\n"
        ),
        "empty duplicate layout status": (
            wpr_with_rsvd
            + safe_layout.rstrip("\n")
            + " status=\n"
            + safe_guard
        ),
        "empty duplicate guard build": (
            wpr_with_rsvd
            + safe_layout
            + safe_guard.rstrip("\n")
            + " build=\n"
        ),
    }
    for case_name, case_text in malformed_assignment_cases.items():
        _, case_status = render_report(
            parse_log(case_text),
            f"self-test/{case_name}",
            ["GPU0"],
            {"GPU0": 0x1000000000},
        )
        if case_status != EXIT_NO_DATA:
            failures.append(f"{case_name} is indeterminate")

    rejected_layout = (
        "NVRM: GPU0 SEC2_DEBUG_FB_LAYOUT: rejected "
        "reason=native FB region table failed validation "
        f"build={EXPECTED_SAFETY_BUILD}\n"
    )
    _, rejected_layout_status = render_report(
        parse_log(wpr_with_rsvd + rejected_layout),
        "self-test/rejected-FB-layout",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if rejected_layout_status != EXIT_HAZARD:
        failures.append("explicitly rejected native FB layout is a hazard")

    refused_final_guard = (
        "NVRM: GPU0 SEC2_DEBUG_PMA_GUARD: PMA total does not match "
        "validated public bytes; refusing init\n"
    )
    _, refused_final_guard_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + refused_final_guard),
        "self-test/refused-final-PMA-guard",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if refused_final_guard_status != EXIT_HAZARD:
        failures.append("explicitly refused final PMA guard is a hazard")

    bad_native_accounting = safe_layout.replace(
        "reservedRegionBytes=0x10000000",
        "reservedRegionBytes=0x20000000",
    )
    bad_capacity_floor = safe_layout.replace(
        "capacityFloor=0xf80000000",
        "capacityFloor=0xf90000000",
    )
    bad_region_count = safe_layout.replace("regions=3", "regions=0")
    bad_pma_accounting = safe_guard.replace(
        "pmaBytes=0xff0000000",
        "pmaBytes=0xfe0000000",
    )
    for case_name, bad_record in (
        ("native public/reserved accounting", bad_native_accounting),
        ("native capacity floor", bad_capacity_floor),
        ("native region count", bad_region_count),
    ):
        _, case_status = render_report(
            parse_log(wpr_with_rsvd + bad_record + safe_guard),
            f"self-test/{case_name}",
            ["GPU0"],
            {"GPU0": 0x1000000000},
        )
        if case_status != EXIT_HAZARD:
            failures.append(f"bad {case_name} is a layout hazard")
    _, bad_pma_accounting_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + bad_pma_accounting),
        "self-test/bad-PMA-accounting",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if bad_pma_accounting_status != EXIT_HAZARD:
        failures.append("bad PMA accounting is a layout hazard")

    legacy_guard = safe_guard.replace(
        f" build={EXPECTED_SAFETY_BUILD}", ""
    )
    legacy_report, legacy_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + legacy_guard),
        "self-test/legacy-guard-without-build",
    )
    if (
        legacy_status != EXIT_NO_DATA
        or f"build={EXPECTED_SAFETY_BUILD}" not in legacy_report
        or "build=?" not in legacy_report
    ):
        failures.append("legacy guard without safety build is indeterminate by default")

    wrong_build_guard = safe_guard.replace(
        EXPECTED_SAFETY_BUILD, "cmpunlocker-safety-v1"
    )
    wrong_build_report, wrong_build_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + wrong_build_guard),
        "self-test/wrong-guard-build",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if (
        wrong_build_status != EXIT_NO_DATA
        or "build=cmpunlocker-safety-v1" not in wrong_build_report
    ):
        failures.append("wrong guard safety build is indeterminate in strict mode")

    old_v2_layout = safe_layout.replace(
        EXPECTED_SAFETY_BUILD, "cmpunlocker-safety-v2"
    )
    old_v2_guard = safe_guard.replace(
        EXPECTED_SAFETY_BUILD, "cmpunlocker-safety-v2"
    )
    _, old_v2_chain_status = render_report(
        parse_log(wpr_with_rsvd + old_v2_layout + old_v2_guard),
        "self-test/old-v2-chain",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if old_v2_chain_status != EXIT_NO_DATA:
        failures.append("old v2 safety chain is indeterminate")

    duplicate_layout_build = safe_layout.replace(
        f"build={EXPECTED_SAFETY_BUILD}",
        f"build={EXPECTED_SAFETY_BUILD} build=cmpunlocker-safety-v2",
    )
    _, duplicate_layout_build_status = render_report(
        parse_log(wpr_with_rsvd + duplicate_layout_build + safe_guard),
        "self-test/ambiguous-layout-build",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if duplicate_layout_build_status != EXIT_NO_DATA:
        failures.append("ambiguous layout safety build is indeterminate")

    duplicate_build_guard = safe_guard.replace(
        f"build={EXPECTED_SAFETY_BUILD}",
        f"build={EXPECTED_SAFETY_BUILD} build=cmpunlocker-safety-v1",
    )
    _, duplicate_build_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + duplicate_build_guard),
        "self-test/ambiguous-guard-build",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if duplicate_build_status != EXIT_NO_DATA:
        failures.append("ambiguous guard safety build is indeterminate")

    conflicting_fb_alias_guard = safe_guard.replace(
        "fbSize=0x1000000000",
        "fbSize=0x1000000000 metaFbSize=0xc00000000",
    )
    _, conflicting_fb_alias_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + conflicting_fb_alias_guard),
        "self-test/conflicting-guard-fbSize-alias",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if conflicting_fb_alias_status != EXIT_NO_DATA:
        failures.append("conflicting guard fbSize aliases are indeterminate")

    _, wrong_build_with_xid_status = render_report(
        parse_log(
            wpr_with_rsvd
            + safe_layout
            + wrong_build_guard
            + "NVRM: Xid (PCI:0000:03:00): 31, generic MMU fault\n"
        ),
        "self-test/wrong-build-plus-Xid31",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if wrong_build_with_xid_status != EXIT_HAZARD:
        failures.append("Xid 31 takes priority over wrong guard build")

    coherent_48g_text = (
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        "fbSize=0xc00000000 rsvdStart=0xbf7000000 "
        "wprStart=0xbf7300000 wprEnd=0xbfff00000 "
        "heapOffset=0xbf7400000 heapSize=0x6e00000\n"
        "NVRM: GPU0 SEC2_DEBUG_FB_LAYOUT: validated "
        "fbSize=0xc00000000 protectedStart=0xbf7000000 "
        "publicBytes=0xbf0000000 capacityFloor=0xb80000000 "
        "reservedRegionBytes=0x10000000 regions=3 status=safe "
        f"build={EXPECTED_SAFETY_BUILD}\n"
        "NVRM: GPU0 SEC2_DEBUG_PMA_GUARD: fbSize=0xc00000000 "
        "protectedStart=0xbf7000000 publicBytes=0xbf0000000 "
        "pmaBytes=0xbf0000000 status=safe "
        f"build={EXPECTED_SAFETY_BUILD}\n"
    )
    coherent_48g = parse_log(coherent_48g_text)
    mismatch_report, mismatch_status = render_report(
        coherent_48g,
        "self-test/coherent-48GiB-but-expect-64GiB",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if (
        mismatch_status != EXIT_NO_DATA
        or "does not match expected" not in mismatch_report
    ):
        failures.append("coherent 48 GiB anchors cannot satisfy 64 GiB expectation")

    _, latest_size_mismatch = render_report(
        parse_log(wpr_with_rsvd + safe_guard + coherent_48g_text),
        "self-test/latest-fbSize-wins",
        ["GPU0"],
        {"GPU0": 0x1000000000},
    )
    if latest_size_mismatch != EXIT_NO_DATA:
        failures.append("latest WPR/guard pair must match expected fbSize")

    coherent_40g = parse_log(
        "NVRM: GPU2 SEC2_DEBUG: WPR meta updated "
        "fbSize=0xa00000000 rsvdStart=0x9f7000000 "
        "wprStart=0x9f7300000 wprEnd=0x9fff00000 "
        "heapOffset=0x9f7400000 heapSize=0x6e00000\n"
        "NVRM: GPU2 SEC2_DEBUG_FB_LAYOUT: validated "
        "fbSize=0xa00000000 protectedStart=0x9f7000000 "
        "publicBytes=0x9f0000000 capacityFloor=0x980000000 "
        "reservedRegionBytes=0x10000000 regions=3 status=safe "
        f"build={EXPECTED_SAFETY_BUILD}\n"
        "NVRM: GPU2 SEC2_DEBUG_PMA_GUARD: fbSize=0xa00000000 "
        "protectedStart=0x9f7000000 publicBytes=0x9f0000000 "
        "pmaBytes=0x9f0000000 status=safe "
        f"build={EXPECTED_SAFETY_BUILD}\n"
    )
    _, exact_40g_status = render_report(
        coherent_40g,
        "self-test/coherent-40GiB",
        ["GPU2"],
        {"GPU2": 0xA00000000},
    )
    if exact_40g_status != EXIT_OK:
        failures.append("coherent 40 GiB anchors satisfy exact expected fbSize")

    multi_gpu_unattributed_pma = parse_log(
        wpr_with_rsvd
        + safe_layout
        + safe_guard
        + wpr_with_rsvd.replace("GPU0", "GPU1")
        + safe_layout.replace("GPU0", "GPU1")
        + safe_guard.replace("GPU0", "GPU1")
        + "NVRM: SEC2_DEBUG_LATE_PMA: registering candidate=4 "
        "base=0x200000000 limit=0x2ffffffff\n"
    )
    _, multi_gpu_unattributed_strict = render_report(
        multi_gpu_unattributed_pma,
        "self-test/multi-GPU-unattributed-PMA-strict",
        ["GPU0", "GPU1"],
        {"GPU0": 0x1000000000, "GPU1": 0x1000000000},
    )
    _, multi_gpu_unattributed_best_effort = render_report(
        multi_gpu_unattributed_pma,
        "self-test/multi-GPU-unattributed-PMA-best-effort",
        [],
    )
    if (
        multi_gpu_unattributed_strict != EXIT_NO_DATA
        or multi_gpu_unattributed_best_effort != EXIT_NO_DATA
        or not any(
            "cannot be attributed" in warning
            for warning in multi_gpu_unattributed_pma.warnings
        )
    ):
        failures.append("multi-GPU unattributed late-PMA cannot return healthy")

    explicit_mismatched_pma = parse_log(
        wpr_with_rsvd
        + "NVRM: GPU1 SEC2_DEBUG_LATE_PMA: registering candidate=4 "
        "base=0x200000000 limit=0x2ffffffff\n"
    )
    _, explicit_mismatched_status = render_report(
        explicit_mismatched_pma,
        "self-test/explicit-mismatched-PMA",
        [],
    )
    if (
        explicit_mismatched_status != EXIT_NO_DATA
        or not any(
            "cannot be attributed" in warning
            for warning in explicit_mismatched_pma.warnings
        )
    ):
        failures.append("explicit cross-GPU PMA is never rebound to singleton WPR")

    second_identity_guard = safe_guard.replace("GPU0", "GPU1")
    unknown_with_second_identity = parse_log(
        wpr_with_rsvd
        + second_identity_guard
        + "NVRM: SEC2_DEBUG_LATE_PMA: registering candidate=4 "
        "base=0x200000000 limit=0x2ffffffff\n"
    )
    _, unknown_with_second_status = render_report(
        unknown_with_second_identity,
        "self-test/unattributed-PMA-with-second-identity",
        [],
    )
    if (
        unknown_with_second_status != EXIT_NO_DATA
        or not any(
            "cannot be attributed" in warning
            for warning in unknown_with_second_identity.warnings
        )
    ):
        failures.append("unattributed PMA fallback requires one concrete GPU")

    _, missing_gpu = render_report(
        parse_log((wpr_with_rsvd + safe_layout + safe_guard) * 2),
        "self-test/missing-second-GPU",
        ["GPU0", "GPU1"],
    )
    if missing_gpu != EXIT_NO_DATA:
        failures.append("per-GPU anchor uniqueness")

    _, stale_anchor = render_report(
        parse_log(wpr_with_rsvd + safe_layout + safe_guard + wpr_with_rsvd),
        "self-test/stale-anchor",
        ["GPU0"],
    )
    if stale_anchor != EXIT_NO_DATA:
        failures.append("latest initialization requires a later guard")

    wpr_without_rsvd = wpr_with_rsvd.replace("rsvdStart=0xff7000000 ", "")
    _, latest_old_format = render_report(
        parse_log(
            wpr_with_rsvd + safe_layout + safe_guard + wpr_without_rsvd
        ),
        "self-test/latest-old-format",
        ["GPU0"],
    )
    if latest_old_format != EXIT_NO_DATA:
        failures.append("latest WPR must carry rsvdStart")

    _, incomplete_latest = render_report(
        parse_log(
            wpr_with_rsvd
            + safe_layout
            + safe_guard
            + "NVRM: GPU0 WPR meta updated fbSize=0x1000000000 "
            + "wprStart=0xff7300000 wprEnd=0xffff00000\n"
        ),
        "self-test/incomplete-latest-WPR",
        ["GPU0"],
    )
    if incomplete_latest != EXIT_NO_DATA:
        failures.append("incomplete safety marker prevents clean status")

    conflicting_guard = (
        "NVRM: GPU0 SEC2_DEBUG_PMA_GUARD: fbSize=0x1000000000 "
        "protectedStart=0xff7100000 publicBytes=0xff0000000 "
        "pmaBytes=0xff0000000 status=safe "
        f"build={EXPECTED_SAFETY_BUILD}\n"
    )
    _, conflicting_status = render_report(
        parse_log(wpr_with_rsvd + safe_layout + safe_guard + conflicting_guard),
        "self-test/conflicting-latest-guard",
        ["GPU0"],
    )
    if conflicting_status != EXIT_NO_DATA:
        failures.append("latest guard must match latest WPR")

    generic_xid = parse_log("NVRM: Xid (PCI:0000:04:00): 31, generic MMU fault\n")
    _, generic_xid_status = render_report(generic_xid, "self-test/generic-Xid31")
    if generic_xid_status != EXIT_HAZARD:
        failures.append("generic Xid 31")

    malformed_fault = parse_log(
        "NVRM: Xid (PCI:0000:04:00): 31, ENGINE CE2 faulted @ 0x____ "
        "FAULT_INFO_TYPE_REGION_VIOLATION ACCESS_TYPE_PHYS_WRITE\n"
    )
    _, malformed_fault_status = render_report(
        malformed_fault, "self-test/malformed-fault-address"
    )
    if malformed_fault_status != EXIT_HAZARD:
        failures.append("generic Xid survives malformed detailed address")

    cross_gpu_split = parse_log(
        "NVRM: Xid (PCI:0000:03:00): 31, generic MMU fault\n"
        "NVRM: GPU7 ENGINE CE9 faulted @ 0xff9200000 "
        "FAULT_INFO_TYPE_REGION_VIOLATION ACCESS_TYPE_PHYS_WRITE\n"
    )
    _, cross_gpu_split_status = render_report(
        cross_gpu_split, "self-test/cross-GPU-split-Xid", []
    )
    if cross_gpu_split_status != EXIT_HAZARD or cross_gpu_split.faults:
        failures.append("split Xid details never cross an explicit GPU identity")

    future_layout_for_fault = parse_log(
        "NVRM: GPU0 Xid: 31, ENGINE CE2 faulted @ 0xff9200000 "
        "FAULT_INFO_TYPE_REGION_VIOLATION ACCESS_TYPE_PHYS_WRITE\n"
        + wpr_with_rsvd
        + "NVRM: GPU0 SEC2_DEBUG_LATE_PMA: registering candidate=4 "
        "base=0xff7100000 limit=0xfffffffff\n"
    )
    future_layout_report, future_layout_status = render_report(
        future_layout_for_fault, "self-test/future-layout-for-fault", []
    )
    if future_layout_status != EXIT_HAZARD or "; inside " in future_layout_report:
        failures.append("future WPR/PMA records cannot annotate an earlier Xid")

    ce_virt_read = parse_log(
        "NVRM: HUBCLIENT_HSCE2 MMU_FAULT_TYPE_REGION_VIOLATION "
        "ACCESS_TYPE_VIRT_READ\n"
    )
    _, ce_virt_status = render_report(ce_virt_read, "self-test/CE-region")
    if ce_virt_status != EXIT_HAZARD:
        failures.append("CE region violation without physical write")

    stale_wpr = parse_log(
        "NVRM: GPU0 SEC2_DEBUG: unexpected WPR2 already up\n"
        "NVRM: GPU1 WPR2 already up before GSP boot\n"
    )
    stale_wpr_report, stale_wpr_status = render_report(
        stale_wpr, "self-test/stale-WPR2-state", []
    )
    if (
        stale_wpr_status != EXIT_HAZARD
        or len(stale_wpr.stale_wpr_state) != 2
        or "stale WPR2 state" not in stale_wpr_report
    ):
        failures.append("stale WPR2 state is a definite hazard")

    refused = parse_log(
        "NVRM: GPU0 SEC2_DEBUG_PMA_GUARD: WPR metadata unavailable; "
        "refusing PMA registration\n"
    )
    _, refused_status = render_report(refused, "self-test/guard-refusal")
    if refused_status != EXIT_HAZARD:
        failures.append("guard refusal")

    malformed_layout = parse_log(
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        "fbSize=0x1000000000 rsvdStart=0xff7000000 "
        "wprStart=0xffff00000 wprEnd=0xff7300000 "
        "heapOffset=0xff7400000 heapSize=0x6e00000\n"
        + safe_guard
    )
    _, malformed_status = render_report(
        malformed_layout, "self-test/malformed-layout", ["GPU0"]
    )
    if malformed_status != EXIT_HAZARD:
        failures.append("invalid safety-critical layout")

    malformed_number = parse_log(
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        "fbSize=0x1000000000NOT_HEX rsvdStart=0xff7000000 "
        "wprStart=0xff7300000 wprEnd=0xffff00000 "
        "heapOffset=0xff7400000 heapSize=0x6e00000\n"
        + safe_guard
    )
    _, malformed_number_status = render_report(
        malformed_number, "self-test/malformed-number", ["GPU0"]
    )
    if malformed_number_status != EXIT_NO_DATA:
        failures.append("malformed numeric token is indeterminate")

    bad_protection = parse_log(
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        "fbSize=0x1000000000 rsvdStart=0xff7400000 "
        "wprStart=0xff7300000 wprEnd=0xffff00000 "
        "heapOffset=0xff7400000 heapSize=0x6e00000\n"
        + safe_guard.replace("0xff7000000", "0xff7400000")
    )
    _, bad_protection_status = render_report(
        bad_protection, "self-test/rsvd-above-WPR", ["GPU0"]
    )
    if bad_protection_status != EXIT_HAZARD:
        failures.append("protected range must cover WPR")

    heap_outside_wpr = parse_log(
        "NVRM: GPU0 SEC2_DEBUG: WPR meta updated "
        "fbSize=0x1000000000 rsvdStart=0xff7000000 "
        "wprStart=0xff7300000 wprEnd=0xff8000000 "
        "heapOffset=0xff9000000 heapSize=0x100000\n"
        + safe_guard
    )
    _, heap_outside_status = render_report(
        heap_outside_wpr, "self-test/heap-outside-WPR", ["GPU0"]
    )
    if heap_outside_status != EXIT_HAZARD:
        failures.append("heap must be contained in WPR")

    pma_outside_fb = parse_log(
        wpr_with_rsvd
        + safe_guard
        + "NVRM: GPU0 SEC2_DEBUG_LATE_PMA: registering candidate=7 "
        + "base=0x1000000000 limit=0x10000fffff\n"
    )
    _, pma_outside_status = render_report(
        pma_outside_fb, "self-test/PMA-outside-FB", ["GPU0"]
    )
    if pma_outside_status != EXIT_HAZARD:
        failures.append("PMA range must stay inside fbSize")

    empty_report, empty_status = render_report(
        parse_log("ordinary kernel message\n"), "self-test/empty"
    )
    if empty_status != EXIT_NO_DATA or "Evidence class: EMPTY" not in empty_report:
        failures.append("no-data status")

    if failures:
        print("self-test: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return EXIT_HAZARD
    print(
        "self-test: PASS (ordered WPR/layout/PMA chain, exact geometry/build, "
        "overlap, Xid/CE, unattributed PMA, broad timeout/OOM, stale WPR2, "
        "malformed/overlong input, and no-data cases)"
    )
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Analyze cmpunlocker protected/WPR/PMA, CE fault, scrub, and OOM "
            "kernel records."
        ),
        epilog=(
            "Exit status: 0 no checked hazard (with coherent required anchors "
            "unless --best-effort is used), 1 hazard evidence, 2 incomplete/"
            "unreadable evidence. Input must be one ordered "
            "current-boot source; never concatenate journal, dmesg, or boots. "
            "Use verify.sh to check multiple sources independently."
        ),
    )
    parser.add_argument(
        "logfile",
        nargs="?",
        metavar="LOGFILE",
        help=(
            "one chronologically ordered kernel log from one current boot; "
            "omit or use '-' for stdin"
        ),
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run built-in parser tests using the current 64 GiB failure signature",
    )
    safety_mode = parser.add_mutually_exclusive_group()
    safety_mode.add_argument(
        "--require-gpu",
        action="append",
        default=[],
        metavar="GPU<N>",
        help=(
            "require a coherent ordered WPR, native FB-layout, and final "
            "PMA-guard chain for this GPU; may be repeated"
        ),
    )
    safety_mode.add_argument(
        "--require-gpu-fb-size",
        action="append",
        default=[],
        metavar="GPU<N>=BYTES",
        help=(
            "require a coherent fingerprinted safety chain whose latest WPR, "
            "native layout, and PMA guard fbSize exactly equal BYTES; BYTES "
            "may be decimal or hexadecimal; may be repeated"
        ),
    )
    safety_mode.add_argument(
        "--best-effort",
        action="store_true",
        help=(
            "summarize one ordered current-boot source without requiring "
            "fixed-driver safety anchors; this is not a healthy verdict"
        ),
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        if (
            args.logfile is not None
            or args.require_gpu
            or args.require_gpu_fb_size
            or args.best_effort
        ):
            parser.error("LOGFILE/safety-mode options cannot be used with --self-test")
        return run_self_test()

    if args.logfile in (None, "-"):
        source = "stdin"
        if sys.stdin is None:
            print("analyze-kernel-log.py: stdin is unavailable", file=sys.stderr)
            return EXIT_NO_DATA
        try:
            text = sys.stdin.read(MAX_INPUT_CHARS + 1)
        except (AttributeError, MemoryError, OSError) as error:
            print(f"analyze-kernel-log.py: cannot safely read stdin: {error}", file=sys.stderr)
            return EXIT_NO_DATA
    else:
        source = args.logfile
        try:
            with Path(args.logfile).open("r", encoding="utf-8", errors="replace") as stream:
                text = stream.read(MAX_INPUT_CHARS + 1)
        except (MemoryError, OSError) as error:
            print(f"analyze-kernel-log.py: cannot read {args.logfile}: {error}", file=sys.stderr)
            return EXIT_NO_DATA

    if len(text) > MAX_INPUT_CHARS:
        print(
            f"analyze-kernel-log.py: input exceeds the "
            f"{MAX_INPUT_CHARS}-character analysis limit",
            file=sys.stderr,
        )
        return EXIT_NO_DATA

    invalid_required = [
        gpu for gpu in args.require_gpu if not re.fullmatch(r"GPU[0-9]+", gpu)
    ]
    if invalid_required:
        parser.error(f"invalid --require-gpu value: {invalid_required[0]}")

    expected_fb_sizes: dict[str, int] = {}
    for requirement in args.require_gpu_fb_size:
        try:
            gpu, raw_size = requirement.split("=", 1)
        except ValueError:
            parser.error(
                f"invalid --require-gpu-fb-size value: {requirement}"
            )
        if not re.fullmatch(r"GPU[0-9]+", gpu) or not re.fullmatch(
            HEX_OR_DEC_RE, raw_size
        ):
            parser.error(
                f"invalid --require-gpu-fb-size value: {requirement}"
            )
        if gpu in expected_fb_sizes:
            parser.error(f"duplicate --require-gpu-fb-size GPU: {gpu}")
        try:
            expected_fb_sizes[gpu] = parse_number(raw_size)
        except ValueError as error:
            parser.error(f"invalid expected fbSize for {gpu}: {error}")
        if expected_fb_sizes[gpu] <= 0:
            parser.error(f"expected fbSize must be positive for {gpu}")

    try:
        analysis = parse_log(text)
    except (MemoryError, ValueError) as error:
        print(f"analyze-kernel-log.py: input cannot be analyzed safely: {error}", file=sys.stderr)
        return EXIT_NO_DATA

    required_gpus = (
        []
        if args.best_effort
        else (list(expected_fb_sizes) or args.require_gpu or None)
    )
    report, status = render_report(
        analysis, source, required_gpus, expected_fb_sizes
    )
    print(report)
    return status


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MemoryError:
        print("analyze-kernel-log.py: memory exhausted while analyzing input", file=sys.stderr)
        raise SystemExit(EXIT_NO_DATA)
    except Exception as error:
        # Exit 1 is reserved for a report that positively identified hazard
        # evidence.  Parser/runtime failures must never collide with it.
        print(
            "analyze-kernel-log.py: unexpected analysis failure "
            f"({type(error).__name__})",
            file=sys.stderr,
        )
        raise SystemExit(EXIT_NO_DATA)
