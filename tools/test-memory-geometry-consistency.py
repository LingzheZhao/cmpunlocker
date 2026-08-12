#!/usr/bin/env python3
"""Fail if the documented profiles drift from build/runtime consumers."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
CONSTANTS = ROOT / "common/constants.yaml"
CONFIGURATOR = ROOT / "tools/configure-memory-geometry.py"


def die(message: str) -> None:
    raise SystemExit(f"memory geometry consistency test: {message}")


def load_profile(text: str, name: str) -> dict[str, str]:
    match = re.search(
        rf'^  "{re.escape(name)}":\n(?P<body>(?:    [^\n]+\n?)*)',
        text,
        re.MULTILINE,
    )
    if match is None:
        die(f"missing constants profile {name}")
    values: dict[str, str] = {}
    for line in match.group("body").splitlines():
        key, separator, value = line.strip().partition(":")
        if not separator:
            continue
        values[key] = value.strip().strip('"')
    return values


def load_top_level_mapping(text: str, name: str) -> dict[str, str]:
    match = re.search(
        rf"^{re.escape(name)}:\n(?P<body>(?:  [^\n]+\n?)*)",
        text,
        re.MULTILINE,
    )
    if match is None:
        die(f"missing constants mapping {name}")
    values: dict[str, str] = {}
    for line in match.group("body").splitlines():
        key, separator, value = line.strip().partition(":")
        if separator:
            values[key] = value.strip().strip('"')
    return values


def main() -> int:
    constants_text = CONSTANTS.read_text(encoding="utf-8")
    spec = importlib.util.spec_from_file_location("cmp_geometry", CONFIGURATOR)
    if spec is None or spec.loader is None:
        die("cannot load geometry configurator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    profiles = {
        "40gb": load_profile(constants_text, "10gb"),
        "80gb": load_profile(constants_text, "10gb_80_experimental"),
    }
    release_gate = load_top_level_mapping(constants_text, "experimental_80g_gate")
    for target, profile in profiles.items():
        geometry = module.GEOMETRIES[target]
        expected = {
            "cfg1": geometry.cfg1,
            "lmr": geometry.lmr,
            "fb_bytes": geometry.fb_bytes,
            "build_fingerprint": geometry.fingerprint,
        }
        for key, value in expected.items():
            if profile.get(key) != value:
                die(
                    f"{target} {key} drift: constants={profile.get(key)!r}, "
                    f"configurator={value!r}"
                )

    shell = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; '
            'printf "%s %s" "$(expected_mib_for_profile 10gb 40gb)" '
            '"$(expected_mib_for_profile 10gb 80gb)"',
            "bash",
            str(ROOT / "common/lib.sh"),
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    expected_mib = f"{profiles['40gb']['unlocked_mib']} {profiles['80gb']['unlocked_mib']}"
    if shell.stdout != expected_mib:
        die(f"common/lib.sh memory values drift: got {shell.stdout!r}")

    consumer_text = "\n".join(
        (ROOT / path).read_text(encoding="utf-8")
        for path in ("driver/build.sh", "install.sh", "verify.sh")
    )
    for target in ("40gb", "80gb"):
        fingerprint = module.GEOMETRIES[target].fingerprint
        if fingerprint not in consumer_text:
            die(f"userspace consumers are missing fingerprint {fingerprint}")

    for gate_name in ("driver_version", "revision", "vbios", "firmware_sha256"):
        gate_value = release_gate.get(gate_name, "")
        if not gate_value:
            die(f"experimental 80G release gate is missing {gate_name}")
        for consumer in ("install.sh", "verify.sh"):
            if gate_value not in (ROOT / consumer).read_text(encoding="utf-8"):
                die(f"{consumer} is missing experimental 80G {gate_name}={gate_value}")

    version_file = [
        line.strip()
        for line in (ROOT / "driver/VERSION").read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    yaml_versions = re.findall(r'^  - "([0-9]+\.[0-9]+\.[0-9]+)"$', constants_text, re.MULTILINE)
    if version_file != yaml_versions:
        die(f"driver/VERSION drift: file={version_file!r}, constants={yaml_versions!r}")

    print("memory geometry consistency: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
