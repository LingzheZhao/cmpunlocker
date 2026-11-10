import re
import shutil
import subprocess

import pytest
import repo


SCRIPT = repo.ROOT / "tools/install-cmp-booter-experiment.sh"


def helper(name):
    match = re.search(rf"(?m)^{name}\(\) \(\n.*?^\)", SCRIPT.read_text(), re.S)
    assert match, name
    return match.group()


def test_depmod_indices_readable_under_private_backup_umask(tmp_path):
    assert shutil.which("depmod"), "depmod is required"
    kernel = "6.8.12-test"
    modules = tmp_path / "lib/modules" / kernel
    modules.mkdir(parents=True)
    for name in ("modules.order", "modules.builtin", "modules.builtin.modinfo"):
        (modules / name).touch()
    config = tmp_path / "empty.conf"
    config.touch()
    script = helper("rebuild_module_index") + '''
KVER="$2"
fixture_root="$1"
fixture_config="$3"
depmod() { command depmod -b "$fixture_root" -C "$fixture_config" "$@"; }
umask 077
rebuild_module_index
[[ "$(umask)" == 0077 ]]
'''
    for _ in range(2):
        subprocess.run(["bash", "-euc", script, "bash", str(tmp_path), kernel, str(config)], check=True)
        for name in ("modules.dep", "modules.dep.bin", "modules.alias", "modules.alias.bin"):
            assert (modules / name).stat().st_mode & 0o777 == 0o644, name
            (modules / name).chmod(0o600)


def test_initramfs_does_not_inherit_backup_umask(tmp_path):
    script = helper("rebuild_initramfs") + '''
fixture_output="$1"
mkinitcpio() { umask > "$fixture_output"; }
umask 077
rebuild_initramfs
[[ "$(umask)" == 0077 ]]
'''
    output = tmp_path / "initramfs-umask"
    subprocess.run(["bash", "-euc", script, "bash", str(output)], check=True)
    assert output.read_text().strip() == "0022"


@pytest.mark.parametrize("name,command", [
    ("rebuild_module_index", "depmod"),
    ("rebuild_initramfs", "mkinitcpio"),
])
def test_rebuild_errors_propagate(name, command):
    script = helper(name) + f'\nKVER=test\n{command}() {{ return 17; }}\n{name}\n'
    result = subprocess.run(["bash", "-uc", script])
    assert result.returncode == 17
