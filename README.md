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
- A matching **nvidia-open 610.57.04, 610.43.03, or 610.43.02** installation (kernel module, userspace libraries, and GSP firmware must be the same release)
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads matching stock `open-gpu-kernel-modules` sources)
- Python 3 (used during patched-source preparation and validation)

---

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

The installer normally needs no profile option. Runtime geometry is always
selected from each GPU's PCI device ID (`10de:20c2` uses the 64 GB geometry;
`10de:2082` uses the 40 GB geometry). `--profile` only overrides the installed
metadata label; it cannot force one card to use the other card's geometry:

```bash
sudo ./install.sh --profile=8gb
sudo ./install.sh --profile=10gb
```

The installer does not edit bootloader sources or live boot artifacts. Before
the final power cycle, configure the CPU-appropriate IOMMU enable parameter
(`intel_iommu=on` or `amd_iommu=on`) plus `iommu=pt` with the distribution's
boot tooling. The installer verifies an existing setting and prints the
required manual action when it is absent. IOMMU must also be enabled in
BIOS/UEFI.

Installation serializes install/remove activity and validates all five NVIDIA
modules plus matching firmware. The module-directory handoff is journaled, but
distribution initramfs tools publish directly to live boot artifacts and are
not fully crash-atomic. If installation exits nonzero, do not power-cycle;
follow its recovery or manual-reconciliation message before rerunning it.
Installation also fails before mutation when the exact NVIDIA DKMS tuple has
an `(Original modules exist)` state or a physical
`original_module/$KVER/$ARCH` payload; normalize that DKMS conflict outside
cmpunlocker first.

After a successful installation, perform a complete power cycle:

```bash
sudo shutdown -h now
```

Power the machine on only after it has fully shut down. The patched modules
remain installed on disk, but every successful installation or removal must be
followed by this complete power-off/power-on transition. A module reload or
warm reboot is not an accepted activation step.

## What Gets Unlocked

| Feature | Status |
|---|---|
| Full SM compute path (SS0/SS1) | Implemented |
| Memory geometry (64GB on 8GB cards, 40GB on 10GB cards) | Implemented; runtime acceptance requires `sudo ./verify.sh` exit 0 |
| PCIe Gen 2 retraining | Implemented; runtime acceptance requires `sudo ./verify.sh` exit 0 |
| JTAG (Host2Jtag register access) | Implemented |
| Patched modules persist on disk until removal | Implemented |

The current safety revision has passed offline source, build, and validator
checks, but has not yet been accepted on a new cold boot. The table describes
implemented paths, not a runtime health result for this revision.

---

## Uninstall

To remove cmpunlocker, run:

```bash
sudo ./remove.sh --yes
```

Removal uses a global forward-only barrier: after it commits, retries advance
only toward a verified stock on-disk state. A rollback-directory orphan without
that barrier, or an interrupted external DKMS build with residue, is preserved
and requires manual reconciliation of the complete multi-kernel set. The
legacy `/opt/cmpunlocker` directory is removed only when it is a safe, empty,
unmounted canonical directory; nonempty content is preserved. After a
failed removal, do not power-cycle; follow its exact recovery or
manual-reconciliation message. After a successful removal, use
`sudo shutdown -h now` and power the machine on again.

## Safety verification

Run the verifier after every install and complete power-off/power-on:

```bash
sudo ./verify.sh
```

The verifier checks more than the capacity reported by `nvidia-smi`: it also
checks the runtime GSP protected-memory boundary, PMA region safety,
current-boot Xid/scrub/OOM records, and PCIe generation. Only exit status 0
from `sudo ./verify.sh` is an acceptance result; a displayed capacity of 64 GB
or 40 GB by itself is not a healthy verdict. Running
`tools/analyze-kernel-log.py` directly and receiving exit status 0 means only
that its checked log hazards were not found; it is not full runtime acceptance.

The safety fix removes the old late-PMA behavior that exposed the top 142 MiB
GSP protected carve-out as public memory. The observed failure chain was a CE2
physical write into that range, Xid 31/region violation, scrub timeout, and
then PMA/context OOM. The 2 GiB capacity slack is only a product policy, not a
memory-safety proof. For `10de:2082`, absence of a valid native 40 GiB region
table fails closed; cmpunlocker does not synthesize one.

## Support & Community

Having issues? Need help? Join our [Discord community](https://discord.gg/CdHSakKSFv) to discuss with other users and get support.
