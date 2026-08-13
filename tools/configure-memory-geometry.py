#!/usr/bin/env python3
"""Configure the 10 GB CMP 170HX geometry in a patched driver tree.

The unlock touches the same geometry in three independent boot/allocator paths.
This helper updates all of them as one fail-closed transaction and refuses a
source tree whose expected anchors have drifted.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys
from typing import NoReturn


@dataclass(frozen=True)
class Geometry:
    cfg1: str
    lmr: str
    fb_bytes: str
    label: str
    fingerprint: str


GEOMETRIES = {
    "40gb": Geometry(
        cfg1="0x02669000",
        lmr="0x0000028A",
        fb_bytes="0x0000000A00000000",
        label="40GB",
        fingerprint="cmpunlocker-safety-v5-2082-40g",
    ),
    "80gb": Geometry(
        cfg1="0x02779000",
        lmr="0x0000028B",
        fb_bytes="0x0000001400000000",
        label="80GB-experimental",
        fingerprint="cmpunlocker-layout-v5-2082-80g-unverified",
    ),
}


def die(message: str) -> NoReturn:
    raise SystemExit(f"memory geometry configuration failed: {message}")


def replace_one(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if count != 1:
        die(f"expected exactly one {label} anchor, found {count}")
    return updated


def configure_gsp(text: str, geometry: Geometry) -> str:
    text = replace_one(
        text,
        r'(#define\s+SEC2_POSTBL_TIMING_BUILD_FINGERPRINT\s+)'
        r'"(?:cmpunlocker-safety-v(?:4|5-2082-(?:40g|80g-experimental))|'
        r'cmpunlocker-layout-v5-2082-80g-unverified)"',
        rf'\g<1>"{geometry.fingerprint}"',
        "kernel_gsp build fingerprint",
    )
    text = replace_one(
        text,
        r"(NvU64 expectedFbSize\s*=\s*\n"
        r"\s*\(devId == SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID\)\s*\n"
        r"\s*\? 0x0000001000000000ULL\s*\n"
        r"\s*:\s*)0x(?:0000000A00000000|0000001400000000)ULL;",
        rf"\g<1>{geometry.fb_bytes}ULL;",
        "kernel_gsp expected 10 GB framebuffer size",
    )
    text = replace_one(
        text,
        r"(else\s*\n\s*\{\s*\n\s*cfg1Value\s*=\s*)"
        r"0x(?:02669000|02779000)U;\s*\n"
        r"(\s*lmrValue\s*=\s*)0x(?:0000028A|0000028B)U;",
        rf"\g<1>{geometry.cfg1}U;\n\g<2>{geometry.lmr}U;",
        "kernel_gsp 10 GB CFG1/LMR pair",
    )
    return text


def configure_booter_verify(text: str, geometry: Geometry) -> str:
    text = replace_one(
        text,
        r"(NvU32 cfg1Expected\s*=\s*\(devId == 0x20C2\)\s*\?\s*"
        r"0x02779000U\s*:\s*)0x(?:02669000|02779000)U;",
        rf"\g<1>{geometry.cfg1}U;",
        "post-Booter CFG1 expectation",
    )
    text = replace_one(
        text,
        r"(NvU32 lmrExpected\s*=\s*\(devId == 0x20C2\)\s*\?\s*"
        r"0x0000020BU\s*:\s*)0x(?:0000028A|0000028B)U;",
        rf"\g<1>{geometry.lmr}U;",
        "post-Booter LMR expectation",
    )
    return text


def configure_pma_guard(text: str, geometry: Geometry) -> str:
    text = replace_one(
        text,
        r"(NvU64 targetFbBytes\s*=\s*\(devId == 0x20C2\)\s*\?\s*\n"
        r"\s*0x0000001000000000ULL\s*:\s*)"
        r"0x(?:0000000A00000000|0000001400000000)ULL;",
        rf"\g<1>{geometry.fb_bytes}ULL;",
        "PMA guard 10 GB framebuffer size",
    )
    return replace_one(
        text,
        r"status=safe build=(?:cmpunlocker-safety-v"
        r"(?:4|5-2082-(?:40g|80g-experimental))|"
        r"cmpunlocker-layout-v5-2082-80g-unverified)\\n",
        f"status=safe build={geometry.fingerprint}\\\\n",
        "PMA guard build fingerprint",
    )


def read_source(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        die(f"cannot read {path}: {error}")


def write_source(path: Path, text: str) -> None:
    try:
        path.write_text(text, encoding="utf-8")
    except OSError as error:
        die(f"cannot write {path}: {error}")


def configure(source_root: Path, target: str) -> Geometry:
    geometry = GEOMETRIES[target]
    paths = {
        "gsp": source_root / "src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c",
        "booter": source_root
        / "src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c",
        "pma": source_root / "src/nvidia/src/kernel/gpu/mem_mgr/mem_mgr.c",
    }

    originals = {name: read_source(path) for name, path in paths.items()}
    updated = {
        "gsp": configure_gsp(originals["gsp"], geometry),
        "booter": configure_booter_verify(originals["booter"], geometry),
        "pma": configure_pma_guard(originals["pma"], geometry),
    }

    required = {
        "gsp": (
            f"cfg1Value = {geometry.cfg1}U;",
            f"lmrValue  = {geometry.lmr}U;",
            f'"{geometry.fingerprint}"',
        ),
        "booter": (
            f"? 0x02779000U : {geometry.cfg1}U;",
            f"? 0x0000020BU : {geometry.lmr}U;",
        ),
        "pma": (
            f": {geometry.fb_bytes}ULL;",
            f"status=safe build={geometry.fingerprint}",
        ),
    }
    for name, markers in required.items():
        missing = [marker for marker in markers if marker not in updated[name]]
        if missing:
            die(f"{name} output is missing configured marker: {missing[0]}")

    # Do not partially update a tree: every source is parsed and validated
    # before the first write occurs.
    for name, path in paths.items():
        write_source(path, updated[name])

    return geometry


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument(
        "--ten-gb-target", choices=tuple(GEOMETRIES), default="40gb"
    )
    args = parser.parse_args()

    geometry = configure(args.source_root.resolve(), args.ten_gb_target)
    print(
        "configured 10 GB target: "
        f"{geometry.label} cfg1={geometry.cfg1} lmr={geometry.lmr} "
        f"fb_bytes={geometry.fb_bytes} fingerprint={geometry.fingerprint}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
