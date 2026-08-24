# cmpunlocker

Unlock tool for the NVIDIA CMP 170HX (GA100) mining card. Restores full SM compute throughput and unlocked HBM2e memory geometry that are restricted in firmware/OTP configuration.


**[Join our Discord community](https://discord.gg/CdHSakKSFv)** for support and discussions.

---
## Proof of Concept

Below are memory and performance results after applying the unlock:

### Memory Unlock Results

<img alt="memory unlock" src="https://github.com/user-attachments/assets/ae062bd8-e3a7-4e73-b9a4-fbcde53f3c7b" width="100%" style="max-width: 900px;" />

### Performance Benchmarks ([OpenCL-Benchmark](https://github.com/ProjectPhysX/OpenCL-Benchmark))

<img alt="performance benchmarks" src="https://github.com/user-attachments/assets/2501506d-420f-4014-9574-b1bd0290eb60" width="100%" style="max-width: 900px;" />

---

## Requirements

- Linux (x86-64)
- Root access
- NVIDIA CMP 170HX
- A driver version listed in `driver/VERSION`, with matching NVIDIA libraries and firmware installed
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads matching stock `open-gpu-kernel-modules` sources)
- Python 3 (used for build preparation and compiled safety checks)

---

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

The profile option is retained for backward compatibility and must agree with
the detected PCI device ID:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

The researched 10GB → 80GB geometry is available only as an explicit
experimental target:

```bash
sudo ./install.sh --experimental-80g
```

This mode currently requires one isolated `10de:2082` 10GB hardware variant
(identified by PCI ID, not the currently loaded driver's `memory.total`), with
no other unlockable GPU, subsystem `10de:1557`, revision `a1`, VBIOS `92.00.66.00.02`,
nvidia-open 610.43.02, and the pinned stock GSP firmware. It has source,
boundary, and module-build coverage, but no completed 80G hardware stability run. See
[the cmp-easyunlock analysis](docs/EASYUNLOCK-80G.md).

The driver changes both memory geometry and firmware-protected memory ranges.
Do not hot-reload the NVIDIA modules or rely on a warm reboot. Shut the machine
down completely, remove standby power long enough for the card to lose state,
and then power it on again.

## Memory Safety

Memory geometry is selected from the PCI device ID at runtime: `10de:20c2`
uses the 64 GiB geometry and `10de:2082` uses 40 GiB by default or the explicit
experimental 80 GiB target. Reported
capacity alone is not proof that the protected firmware range is excluded from
the public allocator. Before running a workload, the current boot log must
contain both of these successful checks:

```text
SEC2_DEBUG_FB_LAYOUT: ... status=safe ... build=cmpunlocker-safety-v5-2082-40g
SEC2_DEBUG_PMA_GUARD: ... status=safe ... build=cmpunlocker-safety-v5-2082-40g
```

An 80G research build instead shows
`cmpunlocker-layout-v5-2082-80g-unverified`. Its two `status=safe` fields mean
only that the individual logical layout and allocator-accounting checks passed;
they do not prove independent physical HBM cells. `verify.sh` checks the exact
marker and installed module provenance, then deliberately exits unsuccessfully
for 80G because physical low/high address uniqueness is unverified.

Any rejected layout, allocator mismatch, or missing check is a stop condition.
The preceding `cmpunlocker-safety-v3` build completed a post-reboot hardware
test on a `10de:20c2` card with driver 610.57.04, including a 56 GiB
bidirectional copy and full readback. The current v5 revision adds
target-bound fingerprints, transactional module installation, stricter
device/firmware gates, and consistent PRAMIN handling. A `10de:2082` card has
completed a 40 GiB boot with both safe proofs and PCIe Gen2; the 80 GiB target
remains experimental and must not be treated as production-stable.

## What Gets Unlocked

| Feature | Status |
|---|---|
| Full SM compute throughput (SS0/SS1) | Working ✓ |
| Memory geometry | 64 GiB (`10de:20c2`); 40 GiB (`10de:2082`, default); 80 GiB (`10de:2082`, logical-layout research only, physical mapping unverified) |
| PCIe Gen 2 speeds | Working ✓ |
| Full BAR1 Size (64GB) | Working ✓ |
| JTAG (Host2Jtag register access) | Working ✓ |
| Persistence across reboot (patched modules) | Working ✓ |

---

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./remove.sh --yes
```

The removal script leaves the running NVIDIA modules untouched. Shut the
machine down completely, remove standby power long enough for the card to lose
state, and only then power it on so the stock driver starts from reset hardware.

## Support & Community

Having issues? Need help? Join our [Discord community](https://discord.gg/CdHSakKSFv) to discuss with other users and get support.
