#!/usr/bin/env python3
"""Read-only BAR1 enumeration and PCI-topology preflight for CMP P2P research.

This tool does not enable Resizable BAR, change PCI configuration, load a
module, or advertise peer capability. A successful result means only that all
detected target GPUs own distinct 64 GiB BAR1 resources. Real peer transfers
must still pass the alias-resistant directed-pair test described in
docs/BAR1-P2P.md.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
import sys


GIB = 1 << 30
EXPECTED_BAR1_BYTES = 64 * GIB
TARGET_DEVICE_IDS = {"20c2", "2082"}
BDF_RE = re.compile(r"^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$")


@dataclass(frozen=True)
class GpuResource:
    bdf: str
    device_id: str
    numa_node: int | None
    iommu_group: str | None
    driver: str | None
    topology_path: tuple[str, ...]
    bar1_start: int
    bar1_end: int
    bar1_bytes: int
    bar3_bytes: int


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def read_hex_id(path: Path) -> str:
    value = read_text(path).lower()
    return value.removeprefix("0x").zfill(4)


def resource_size(start: int, end: int) -> int:
    if start == 0 and end == 0:
        return 0
    if end < start:
        raise ValueError(f"invalid PCI resource interval 0x{start:x}-0x{end:x}")
    return end - start + 1


def parse_resources(path: Path) -> list[tuple[int, int, int]]:
    rows: list[tuple[int, int, int]] = []
    for line_number, line in enumerate(read_text(path).splitlines(), 1):
        fields = line.split()
        if len(fields) != 3:
            raise ValueError(f"{path}:{line_number}: expected three fields")
        rows.append(tuple(int(field, 16) for field in fields))
    return rows


def optional_link_name(path: Path) -> str | None:
    try:
        return path.resolve(strict=True).name
    except (FileNotFoundError, OSError):
        return None


def optional_int(path: Path) -> int | None:
    try:
        value = int(read_text(path), 10)
        return None if value < 0 else value
    except (FileNotFoundError, OSError, ValueError):
        return None


def topology_components(device_path: Path) -> tuple[str, ...]:
    try:
        resolved = device_path.resolve(strict=True)
    except (FileNotFoundError, OSError):
        resolved = device_path
    return tuple(part.lower() for part in resolved.parts if BDF_RE.match(part))


def load_gpu(device_path: Path) -> GpuResource:
    resources = parse_resources(device_path / "resource")
    if len(resources) < 4:
        raise ValueError(f"{device_path}: fewer than four PCI resources")
    bar1_start, bar1_end, _ = resources[1]
    bar3_start, bar3_end, _ = resources[3]
    return GpuResource(
        bdf=device_path.name.lower(),
        device_id=read_hex_id(device_path / "device"),
        numa_node=optional_int(device_path / "numa_node"),
        iommu_group=optional_link_name(device_path / "iommu_group"),
        driver=optional_link_name(device_path / "driver"),
        topology_path=topology_components(device_path),
        bar1_start=bar1_start,
        bar1_end=bar1_end,
        bar1_bytes=resource_size(bar1_start, bar1_end),
        bar3_bytes=resource_size(bar3_start, bar3_end),
    )


def discover(sysfs_root: Path) -> list[GpuResource]:
    devices: list[GpuResource] = []
    if not sysfs_root.is_dir():
        raise ValueError(f"PCI sysfs root does not exist: {sysfs_root}")
    for path in sorted(sysfs_root.iterdir(), key=lambda item: item.name):
        try:
            vendor = read_hex_id(path / "vendor")
            device = read_hex_id(path / "device")
        except (FileNotFoundError, OSError, ValueError):
            continue
        if vendor == "10de" and device in TARGET_DEVICE_IDS:
            devices.append(load_gpu(path))
    return devices


def overlaps(left: GpuResource, right: GpuResource) -> bool:
    if left.bar1_bytes == 0 or right.bar1_bytes == 0:
        return False
    return max(left.bar1_start, right.bar1_start) <= min(
        left.bar1_end, right.bar1_end
    )


def common_topology_prefix(left: GpuResource, right: GpuResource) -> tuple[str, ...]:
    common: list[str] = []
    for left_part, right_part in zip(left.topology_path, right.topology_path):
        if left_part != right_part:
            break
        common.append(left_part)
    return tuple(common)


def pair_class(left: GpuResource, right: GpuResource) -> str:
    if left.bdf.split(":", 1)[0] != right.bdf.split(":", 1)[0]:
        return "different-pci-domain"
    if left.topology_path[:-1] == right.topology_path[:-1]:
        return "same-immediate-parent"
    if common_topology_prefix(left, right):
        return "shared-pci-ancestry"
    if left.numa_node is not None and left.numa_node == right.numa_node:
        return "same-numa-node-different-root-path"
    return "different-root-path-or-socket"


def audit(devices: list[GpuResource]) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []
    if len(devices) < 2:
        failures.append("at least two target GPUs are required for P2P")
    for gpu in devices:
        if gpu.bar1_start == 0 or gpu.bar1_bytes == 0:
            failures.append(f"{gpu.bdf}: BAR1 is unassigned")
        elif gpu.bar1_bytes != EXPECTED_BAR1_BYTES:
            failures.append(
                f"{gpu.bdf}: BAR1 is {gpu.bar1_bytes / GIB:.3f} GiB, expected 64 GiB"
            )
        if gpu.driver is None:
            warnings.append(f"{gpu.bdf}: no bound kernel driver was observed")
        if gpu.iommu_group is None:
            warnings.append(f"{gpu.bdf}: no IOMMU group was observed")
    for index, left in enumerate(devices):
        for right in devices[index + 1 :]:
            if overlaps(left, right):
                failures.append(f"{left.bdf} and {right.bdf}: BAR1 resources overlap")
    return failures, warnings


def hex_resource(value: int) -> str:
    return f"0x{value:016x}"


def human_report(
    devices: list[GpuResource], failures: list[str], warnings: list[str]
) -> None:
    print(f"Detected target GPUs: {len(devices)}")
    print(f"Conservative parent-window planning estimate: {len(devices) * 128} GiB")
    for gpu in devices:
        print(
            f"- {gpu.bdf} device=10de:{gpu.device_id} numa={gpu.numa_node} "
            f"iommu_group={gpu.iommu_group or '-'} driver={gpu.driver or '-'}"
        )
        print(
            f"  BAR1={hex_resource(gpu.bar1_start)}-{hex_resource(gpu.bar1_end)} "
            f"size={gpu.bar1_bytes / GIB:.3f} GiB BAR3={gpu.bar3_bytes / (1 << 20):.3f} MiB"
        )
        print(f"  topology={' -> '.join(gpu.topology_path) or 'unavailable'}")
    if len(devices) >= 2:
        print("Directed-pair topology classes:")
        for left in devices:
            for right in devices:
                if left is right:
                    continue
                print(f"  {left.bdf} -> {right.bdf}: {pair_class(left, right)}")
    for warning in warnings:
        print(f"WARNING: {warning}")
    for failure in failures:
        print(f"FAIL: {failure}")
    print(f"BAR1_ENUMERATION_READY={'no' if failures else 'yes'}")
    print("REAL_P2P_TRANSFER_VALIDATED=no")


def json_report(
    devices: list[GpuResource], failures: list[str], warnings: list[str]
) -> None:
    print(
        json.dumps(
            {
                "devices": [asdict(device) for device in devices],
                "conservative_parent_window_gib": len(devices) * 128,
                "failures": failures,
                "warnings": warnings,
                "bar1_enumeration_ready": not failures,
                "real_p2p_transfer_validated": False,
            },
            indent=2,
            sort_keys=True,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sysfs-root",
        type=Path,
        default=Path("/sys/bus/pci/devices"),
        help="PCI devices directory; override only for an offline fixture",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()
    try:
        devices = discover(args.sysfs_root)
        failures, warnings = audit(devices)
    except (OSError, ValueError) as error:
        print(f"P2P platform preflight failed: {error}", file=sys.stderr)
        return 2
    if args.json:
        json_report(devices, failures, warnings)
    else:
        human_report(devices, failures, warnings)
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
