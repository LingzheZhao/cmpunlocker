<div align="center" style="text-align: center;">
  <img width="1280" height="300" alt="cmpunlocker banner" src="https://github.com/user-attachments/assets/6edceb8e-afcb-43a4-b5b2-4321d81284d1" />
</div>

---

## What is cmpunlocker?

<p>
  cmpunlocker restores numerous features that are restricted in firmware/OTP configuration of the NVIDIA CMP 170HX. cmpunlocker has been featured by multiple outlets like wccftech, Tom's Hardware and LinusTechTips.
</p>

<table>
  <tr>
    <td><a href="https://www.youtube.com/watch?v=pvSdeU13hKc" title=""><img src="https://github.com/user-attachments/assets/be0a9cab-19b6-47c4-91cd-cb6a98be406f"></a></td>
    <td><a href="https://www.tomshardware.com/pc-components/gpus/nvidia-crypto-mining-gpus-hacked-to-restore-locked-away-vram-in-order-to-feed-ai-boom-software-mod-unlocks-64gb-of-vram-on-usd250-cmp-170hx" title="Article by Tom's Hardware"><img src="https://github.com/user-attachments/assets/e801b2b3-3002-4346-a9ad-6b228ef62b6a"></a></td>
    <td><a href="https://wccftech.com/nvidia-cmp-170hx-8-10-gb-prices-explode-over-1000-usd-as-tool-unlocks-hidden-64-80gb-vram/" title="Article by wccftech"><img src="https://github.com/user-attachments/assets/475b5acf-999b-430c-8ede-1c39e9fd6b97"></a></td>
  </tr>
</table>

**[Join our Discord community](https://discord.gg/CdHSakKSFv)** for support and discussions.

---

## Proof of Concept

Below are memory and performance results after applying the unlock:

<table>
  <tr>
    <td><b>Memory Unlock Results</b></td>
  </tr>
  <tr>
    <td><img alt="memory unlock" src="https://github.com/user-attachments/assets/ae062bd8-e3a7-4e73-b9a4-fbcde53f3c7b" width="100%" style="max-width: 900px;" /></td>
  </tr>
</table>

<table>
  <tr>
    <td><b>Performance Benchmarks (<a href="https://github.com/ProjectPhysX/OpenCL-Benchmark">OpenCL-Benchmark</a>)</b></td>
  </tr>
  <tr>
    <td><img alt="performance benchmarks" src="https://github.com/user-attachments/assets/2501506d-420f-4014-9574-b1bd0290eb60" width="100%" style="max-width: 900px;" /></td>
  </tr>
</table>

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

The profile option is retained for installation metadata and backward
compatibility. It does not override the PCI device ID selected geometry:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

GPU-to-GPU BAR1 P2P is on by default. Pass `--no-p2p` to leave it off.

This requires 64GB BAR1 on every GPU. Driver-time resize is not enough for
that on multi-GPU systems; apply the optional host-kernel patches in
`kernel-patches/` (`install.sh` does not; 6.8 uses `linux-6.8/`). The
installer adds `pci=realloc pci=hpmmioprefsize=2T` when P2P is enabled.
`nvidia-smi topo -p2p` reporting OK is not proof of working transfers.
With GPUs behind PCIe switches, multi-GPU P2P also needs ACS redirect off and
`NCCL_P2P_LEVEL=SYS`; see [docs/INSTALLATION.md](docs/INSTALLATION.md).

The driver changes both memory geometry and firmware-protected memory ranges.
Do not hot-reload the NVIDIA modules or rely on a warm reboot. Shut the machine
down completely, remove standby power long enough for the card to lose state,
and then power it on again.

## Memory Safety

Memory geometry is selected from the PCI device ID at runtime: `10de:20c2`
uses the 64 GiB geometry and `10de:2082` uses the 40 GiB geometry. Reported
capacity alone is not proof that the protected firmware range is excluded from
the public allocator. Before running a workload, the current boot log must
contain both of these successful checks:

```text
SEC2_DEBUG_FB_LAYOUT: ... status=safe ... build=cmpunlocker-safety-v4
SEC2_DEBUG_PMA_GUARD: ... status=safe ... build=cmpunlocker-safety-v4
```

Any rejected layout, allocator mismatch, or missing check is a stop condition.
`cmpunlocker-safety-v4` has been installed and cold-booted on multiple hosts,
including both `10de:20c2` (64 GiB) and `10de:2082` (40 GiB).

## What Gets Unlocked

| Feature | Status |
|---|---|
| Full SM compute throughput (SS0/SS1) | Working ✓ |
| Memory geometry | 64 GiB (`10de:20c2`); 40 GiB (`10de:2082`) |
| PCIe Gen 2 speeds | Working ✓ |
| Full BAR1 Size (64GB) | Working ✓ |
| ECC, DRAM and SRAM | Default on (`--no-ecc` to disable); `nvidia-smi` ECC status is synthetic |
| GPU-to-GPU P2P (`cudaDeviceEnablePeerAccess`) | Default on; BAR1 P2P, needs 64GB BAR1 and `kernel-patches/` (`--no-p2p` to disable) |
| JTAG (Host2Jtag register access) | Working ✓ |
| VFIO-based passthrough | Default on (`--no-passthrough` to disable) |
| GPU profiling | Working ✓ |
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

## Contributions

Please read [docs/CONTRIBUTING.md](https://github.com/amoghmunikote/cmpunlocker/blob/master/docs/CONTRIBUTING.md) before opening a PR.

## Support & Community

Having issues? Need help? Join our [Discord community](https://discord.gg/CdHSakKSFv) to discuss with other users and get support.
