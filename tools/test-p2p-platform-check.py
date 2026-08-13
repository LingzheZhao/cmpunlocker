#!/usr/bin/env python3
"""Unit tests for the read-only BAR1 platform preflight."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("check-p2p-platform.py")
SPEC = importlib.util.spec_from_file_location("check_p2p_platform", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write_device(
    root: Path, bdf: str, device_id: str, bar1_start: int, bar1_bytes: int
) -> None:
    path = root / bdf
    path.mkdir(parents=True)
    (path / "vendor").write_text("0x10de\n", encoding="utf-8")
    (path / "device").write_text(f"0x{device_id}\n", encoding="utf-8")
    (path / "numa_node").write_text("0\n", encoding="utf-8")
    resources = [(0, 0, 0)] * 6
    resources[1] = (
        bar1_start,
        bar1_start + bar1_bytes - 1 if bar1_bytes else 0,
        0,
    )
    resources[3] = (0x10000000, 0x11FFFFFF, 0)
    (path / "resource").write_text(
        "".join(f"{start:016x} {end:016x} {flags:016x}\n" for start, end, flags in resources),
        encoding="utf-8",
    )


class PlatformCheckTests(unittest.TestCase):
    def test_two_distinct_64_gib_bars_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_device(root, "0000:01:00.0", "20c2", 0x10000000000, 64 * MODULE.GIB)
            write_device(root, "0000:02:00.0", "2082", 0x12000000000, 64 * MODULE.GIB)
            devices = MODULE.discover(root)
            failures, _ = MODULE.audit(devices)
            self.assertEqual(failures, [])

    def test_missing_bar_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_device(root, "0000:01:00.0", "20c2", 0, 0)
            write_device(root, "0000:02:00.0", "2082", 0x12000000000, 64 * MODULE.GIB)
            failures, _ = MODULE.audit(MODULE.discover(root))
            self.assertTrue(any("unassigned" in failure for failure in failures))

    def test_small_bar_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_device(root, "0000:01:00.0", "20c2", 0x10000000000, 32 * MODULE.GIB)
            write_device(root, "0000:02:00.0", "2082", 0x12000000000, 64 * MODULE.GIB)
            failures, _ = MODULE.audit(MODULE.discover(root))
            self.assertTrue(any("expected 64 GiB" in failure for failure in failures))

    def test_overlap_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_device(root, "0000:01:00.0", "20c2", 0x10000000000, 64 * MODULE.GIB)
            write_device(root, "0000:02:00.0", "2082", 0x10800000000, 64 * MODULE.GIB)
            failures, _ = MODULE.audit(MODULE.discover(root))
            self.assertTrue(any("overlap" in failure for failure in failures))

    def test_non_target_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_device(root, "0000:01:00.0", "1234", 0x10000000000, 64 * MODULE.GIB)
            self.assertEqual(MODULE.discover(root), [])


if __name__ == "__main__":
    unittest.main()
