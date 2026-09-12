#!/usr/bin/env python3
"""Check upgrade version selection and depmod precedence without touching drivers."""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run_bash(script, *args):
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script, "bash", *map(str, args)],
        text=True, capture_output=True,
    )


def main():
    with tempfile.TemporaryDirectory(prefix="cmp-driver-upgrade-") as tmp:
        work = Path(tmp)
        cache = work / "ldconfig.cache"
        libraries = []
        for version in ("610.57.04", "610.43.02"):
            library = work / f"libnvidia-ml.so.{version}"
            library.touch()
            link = work / version / "libnvidia-ml.so.1"
            link.parent.mkdir()
            link.symlink_to(library)
            libraries.append(link)

        setup = '''source "$1/common/lib.sh"
fixture_cache="$2"
ldconfig() { cat "${fixture_cache}"; }
nvidia-smi() { echo "must not query the running driver" >&2; return 99; }
modinfo() { echo "must not use the old module as the target" >&2; return 99; }
'''

        def write_cache(paths):
            cache.write_text("".join(
                f"libnvidia-ml.so.1 (libc6,x86-64) => {path}\n" for path in paths
            ))

        write_cache([libraries[0]])
        result = run_bash(setup + "installed_nvidia_userspace_version", ROOT, cache)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "610.57.04", result.stdout

        for paths, expected_error in (
            ([], "No installed libnvidia-ml.so.1"),
            (libraries, "Conflicting installed NVML versions"),
            ([work / "missing.so"], "Installed NVML library is missing"),
        ):
            write_cache(paths)
            result = run_bash(setup + "installed_nvidia_userspace_version", ROOT, cache)
            assert result.returncode != 0 and expected_error in result.stderr, result

        write_cache([libraries[0], libraries[0]])
        result = run_bash(setup + "installed_nvidia_userspace_version", ROOT, cache)
        assert result.returncode == 0 and result.stdout.strip() == "610.57.04", result

        running = work / "running-version"
        running.write_text("NVRM version: NVIDIA UNIX Open Kernel Module 610.43.02\n")
        installer = (ROOT / "install.sh").read_text()
        selection = installer[installer.index('running_version=""'):
                              installer.index("STOCK_MODULE_FILES=(")]
        selection = selection.replace("/proc/driver/nvidia/version", str(running))
        fixture = setup + '''
SUPPORTED_VERSIONS_CSV="610.57.04,610.43.03,610.43.02"
version_supported() { [[ "$1" == "610.57.04" ]]; }
TEN_GB_TARGET="$3"
''' + selection + '\nprintf "selected=%s running=%s\\n" "$detected" "$running_version"\n'
        result = run_bash(fixture, ROOT, cache, "40gb")
        assert result.returncode == 0, result.stderr
        assert "selected=610.57.04 running=610.43.02" in result.stdout, result.stdout
        result = run_bash(fixture, ROOT, cache, "80gb")
        assert result.returncode != 0 and "release-gated" in result.stderr, result
        print("Installed userspace selection, invalid/ambiguous libraries, and 80GB gate: PASS")

        kernel = "6.8.12-cmp-test"
        module_root = work / "lib/modules" / kernel
        names = ("nvidia", "nvidia-modeset", "nvidia-uvm", "nvidia-drm", "nvidia-peermem")
        for directory in ("updates/cmpunlocker", "updates/dkms"):
            (module_root / directory).mkdir(parents=True)
        for name in names:
            source = work / f"{name}.c"
            source.write_text(
                'const char module_license[] __attribute__((section(".modinfo"))) = "license=GPL";\n'
                f'const char module_name[] __attribute__((section(".modinfo"))) = "name={name.replace("-", "_")}";\n'
                "int init_module(void) { return 0; }\nvoid cleanup_module(void) {}\n"
            )
            output = module_root / "updates/cmpunlocker" / f"{name}.ko"
            subprocess.run(["gcc", "-c", "-o", str(output), str(source)], check=True)
            (module_root / "updates/dkms" / output.name).write_bytes(output.read_bytes())
        for name in ("modules.order", "modules.builtin", "modules.builtin.modinfo"):
            (module_root / name).touch()

        build = (ROOT / "driver/build.sh").read_text()
        end = build.index('> "${TRANSACTION_STATE}/depmod.conf.new"')
        start = build.rfind("printf '%s\\n'", 0, end)
        assert start >= 0
        writer = build[start:end + len('> "${TRANSACTION_STATE}/depmod.conf.new"')]
        result = run_bash('TRANSACTION_STATE="$1"\n' + writer, work)
        assert result.returncode == 0, result.stderr
        config = work / "depmod.conf.new"
        config.write_text("search updates/dkms updates/cmpunlocker built-in\n" + config.read_text())
        result = subprocess.run(
            ["depmod", "-n", "-b", str(work), "-C", str(config), kernel],
            text=True, capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        chosen = set(re.findall(r"^(updates/[^:]+\.ko):", result.stdout, re.MULTILINE))
        expected = {f"updates/cmpunlocker/{name}.ko" for name in names}
        assert chosen == expected, f"depmod selected {chosen}, expected {expected}"
        print("Real depmod selects all five patched modules over DKMS: PASS")


if __name__ == "__main__":
    main()
