import hashlib
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

import pytest
import repo
from test_patches import tarball


spec = importlib.util.spec_from_file_location("cmp_booter", repo.ROOT / "tools/prepare-cmp-booter.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


@pytest.fixture(scope="module")
def inputs(tmp_path_factory):
    root = tmp_path_factory.mktemp("cmp-booter-input")
    with tarfile.open(tarball("615.78.08")) as archive:
        archive.extractall(root, filter="data")
    source = root / "open-gpu-kernel-modules-615.78.08"
    for patch in repo.patch_order():
        result = subprocess.run(["patch", "--batch", "--forward", "-p1", "-i",
                                 str(repo.ROOT / "driver/patches" / patch)],
                                cwd=source, text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
    old = root / "legacy.c"
    with tarfile.open(tarball("610.57.04")) as archive:
        member = "open-gpu-kernel-modules-610.57.04/src/nvidia/generated/" + prepare.OLD_ARCHIVE
        old.write_bytes(archive.extractfile(member).read())
    return source, old


def source_copy(source, target):
    files = [Path("version.mk"), prepare.GENERATED / "g_bindata.c",
             prepare.GENERATED / prepare.OLD_ARCHIVE,
             prepare.GSP / "kernel_gsp.c", prepare.GSP / "kernel_gsp_booter.c"]
    for relative in files:
        dest = target / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, dest)
    return target


def digest_tree(root):
    return {p.relative_to(root): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


def test_source_integration_and_rejection(inputs, tmp_path):
    source, old = inputs
    target = source_copy(source, tmp_path / "source")
    before = digest_tree(target)
    changes = prepare.prepare(target, old)
    assert len(changes) == 4
    assert hashlib.sha256((target / prepare.GENERATED / prepare.OLD_ARCHIVE).read_bytes()).hexdigest() == before[prepare.GENERATED / prepare.OLD_ARCHIVE]
    generated = (target / prepare.GENERATED / "g_bindata.c").read_text()
    assert generated.count('#include "' + prepare.NEW_ARCHIVE + '"') == 4
    assert len(re.findall(r"__idx_kgspBinArchiveCmpBooterLoadUcode_GA100_\w+\s*=", generated)) == 10
    prior_indices = re.findall(r"^    (__idx_\w+)\s*=\s*(\d+),", (source / prepare.GENERATED / "g_bindata.c").read_text(), re.M)
    after_indices = dict(re.findall(r"^    (__idx_\w+)\s*=\s*(\d+),", generated, re.M))
    assert all(after_indices[name] == value for name, value in prior_indices)
    kernel = (target / prepare.GSP / "kernel_gsp.c").read_text()
    start = kernel.index("kgspCmpSelectBooter(pGpu, pKernelGsp, NV_TRUE)")
    restored = kernel.index("kgspCmpSelectBooter(pGpu, pKernelGsp, NV_FALSE)", start)
    primary_failure = kernel.index("if (plmIdx < 4)", start)
    assert primary_failure < restored < kernel.index("return NV_ERR_INVALID_STATE;", primary_failure)
    normal_restore = kernel.index("kgspCmpSelectBooter(pGpu, pKernelGsp, NV_FALSE)", restored + 1)
    assert normal_restore < kernel.index("plmStatus = kgspSec2PostblTimingRebuildStockSignature", start)
    after = digest_tree(target)
    with pytest.raises(ValueError, match="already present"):
        prepare.prepare(target, old)
    assert digest_tree(target) == after

    bad = tmp_path / "bad.c"
    bad.write_bytes(old.read_bytes() + b" ")
    clean = source_copy(source, tmp_path / "clean")
    clean_before = digest_tree(clean)
    with pytest.raises(ValueError, match="pinned official"):
        prepare.prepare(clean, bad)
    assert digest_tree(clean) == clean_before
    (clean / "version.mk").write_text("NVIDIA_VERSION = 615.71.10\n")
    wrong_version = digest_tree(clean)
    with pytest.raises(ValueError, match="615.78.08"):
        prepare.prepare(clean, old)
    assert digest_tree(clean) == wrong_version


def test_switch_gates_and_lifetime(tmp_path):
    code = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
typedef uint32_t NvU32;
typedef int NvBool;
typedef int NV_STATUS;
typedef struct { struct { NvU32 PCIDeviceID; } idInfo; } OBJGPU;
typedef struct { int id; } KernelGspFlcnUcode;
typedef struct KernelGsp { KernelGspFlcnUcode *pBooterLoadUcode; } KernelGsp;
typedef struct { int id; } BINDATA_ARCHIVE;
#define NV_OK 0
#define NV_ERR_INVALID_ARGUMENT 1
#define NV_ERR_NOT_SUPPORTED 2
#define NV_ERR_INVALID_STATE 3
#define NV_ASSERT_OR_RETURN(c, e) do { if (!(c)) return (e); } while (0)
#define NV_PRINTF(...) do {} while (0)
static const BINDATA_ARCHIVE current_archive = {1}, legacy_archive = {2};
static KernelGspFlcnUcode initial = {1}, replacement = {2}, partial = {3}, restored = {4};
static int allocations, releases, fail_alloc, null_archive, empty_success;
static const BINDATA_ARCHIVE *selected;
static KernelGspFlcnUcode *old_during_allocate, *freed;
const BINDATA_ARCHIVE *kgspGetBinArchiveCmpBooterLoadUcode_GA100(struct KernelGsp *g)
{ (void)g; return null_archive ? NULL : &legacy_archive; }
static const BINDATA_ARCHIVE *kgspGetBinArchiveBooterLoadUcode_HAL(KernelGsp *g)
{ (void)g; return null_archive ? NULL : &current_archive; }
static NV_STATUS s_allocateUcodeFromBinArchive(OBJGPU *g, KernelGsp *k,
    const BINDATA_ARCHIVE *a, KernelGspFlcnUcode **out)
{
    (void)g; allocations++; selected=a; old_during_allocate=k->pBooterLoadUcode;
    *out=empty_success ? NULL : (fail_alloc ? &partial :
         (a == &legacy_archive ? &replacement : &restored));
    return fail_alloc ? 9 : NV_OK;
}
static void kgspFreeFlcnUcode(KernelGspFlcnUcode *u)
{ if (u) { releases++; freed=u; } }
'''
    main = r'''
int main(void)
{
    OBJGPU gpu = {{0x20c210deU}};
    KernelGsp gsp = {&initial};
    assert(kgspCmpSelectBooter(NULL, &gsp, 1) == NV_ERR_INVALID_ARGUMENT);
    assert(kgspCmpSelectBooter(&gpu, NULL, 1) == NV_ERR_INVALID_ARGUMENT);
    const NvU32 ignored[] = {0x2b8510deU, 0x208210deU, 0x20c21002U};
    for (unsigned i=0; i<sizeof(ignored)/sizeof(ignored[0]); i++)
    {
        gpu.idInfo.PCIDeviceID=ignored[i];
        assert(kgspCmpSelectBooter(&gpu,&gsp,1)==NV_OK);
        assert(kgspCmpSelectBooter(&gpu,&gsp,0)==NV_OK);
        assert(gsp.pBooterLoadUcode==&initial && allocations==0 && releases==0);
    }
    gpu.idInfo.PCIDeviceID=0x20c210deU;
    null_archive=1;
    assert(kgspCmpSelectBooter(&gpu,&gsp,1)==NV_ERR_NOT_SUPPORTED);
    assert(gsp.pBooterLoadUcode==&initial && allocations==0 && releases==0);
    null_archive=0; fail_alloc=1;
    assert(kgspCmpSelectBooter(&gpu,&gsp,1)==9);
    assert(gsp.pBooterLoadUcode==&initial && old_during_allocate==&initial);
    assert(allocations==1 && releases==1 && freed==&partial);
    fail_alloc=0; releases=0; empty_success=1;
    assert(kgspCmpSelectBooter(&gpu,&gsp,1)==NV_ERR_INVALID_STATE);
    assert(gsp.pBooterLoadUcode==&initial && releases==0);
    empty_success=0;
    assert(kgspCmpSelectBooter(&gpu,&gsp,1)==NV_OK);
    assert(selected==&legacy_archive && old_during_allocate==&initial);
    assert(gsp.pBooterLoadUcode==&replacement && freed==&initial);
    replacement.id=2;
    assert(kgspCmpSelectBooter(&gpu,&gsp,0)==NV_OK);
    assert(selected==&current_archive && old_during_allocate==&replacement);
    assert(gsp.pBooterLoadUcode==&restored && freed==&replacement);
    return 0;
}
'''
    file = tmp_path / "switch.c"
    file.write_text(code + prepare.HELPER + main)
    binary = tmp_path / "switch"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(file), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
