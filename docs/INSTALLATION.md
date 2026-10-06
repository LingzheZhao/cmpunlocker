# Installation

Here are the steps to install cmpunlocker on your system.

---

## Requirements

- Linux (x86-64)
- Root access
- NVIDIA CMP 170HX
- **nvidia-open 610.xx.xx+ already installed** (libs + firmware)
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads matching stock `open-gpu-kernel-modules` sources)
- Python 3 (used at build time to select 8GB/10GB geometry)

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

To force a certain memory profile, use the `--profile` option:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

GPU-to-GPU BAR1 P2P is on by default. Pass `--no-p2p` to leave it off. When
enabled, the installer also adds `pci=realloc pci=hpmmioprefsize=2T`. 64GB
BAR1 on every GPU is required; the optional host-kernel patches in
`kernel-patches/` are what make that BAR come up from a normal boot. P2P is
reported only for pairs whose static BAR1 mapping succeeded; still verify with
a real peer copy after reboot.

With two or more GPUs behind one PCIe switch, multi-GPU P2P also needs ACS
redirect off. Linux turns it on whenever an IOMMU driver is active, also with
`iommu=pt`, and peer traffic between GPUs on one switch then goes up to the
root complex. On 8 GPUs, two per switch, an NCCL ring drops to 0.47 GB/s,
against 6.38 GB/s with redirect off. Clear it at runtime on the bridges above
the GPUs with
[`acs-redir.sh`](https://github.com/WU-CVGL/cluster-setup/blob/main/scripts/gpu-p2p/acs-redir.sh),
only with `iommu=pt` and while no GPU is assigned to a VM, and set
`NCCL_P2P_LEVEL=SYS` so NCCL uses P2P across root ports too. See
[DEBUGGING.md](DEBUGGING.md#multi-gpu-p2p-rings-are-slow-behind-pcie-switches)
and [GPU P2P on GeForce and CMP](https://github.com/WU-CVGL/cluster-setup/blob/main/docs/05_GPU_P2P_GeForce_and_CMP.md).

ECC (DRAM and SRAM) is on by default. Pass `--no-ecc` to leave it off.
`nvidia-smi` reports ECC as enabled with zero errors whenever the ECC patches
are built in; that report is synthetic and does not show whether ECC works.

Then perform a cold reboot (full power off, then boot).

`install.sh` does not patch the host kernel. For 64GB BAR1, build a `-cmp`
kernel from `kernel-patches/` (6.8: `linux-6.8/`), boot it, then run
`install.sh` again. See `kernel-patches/README.md`.

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./remove.sh --yes
```

Then perform a reboot.
