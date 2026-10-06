# Debugging

Before you go asking in the Discord for help, here is a FAQ you should take a look at:

---

## "nvidia-smi: command not found"

- The installer likely didn't run or even failed. Re-run `sudo ./install.sh` and cold reboot.

---

## nvidia-smi shows 8192 or 10240 MiB (not 65536 or 40960)

- All the PLMs must show `0xffffffff`. Run `sudo dmesg | grep SEC2_DEBUG`to confirm.

- If this still persists, refer to the Discord protocol at the end of the document.

---

## P2P shows OK in nvidia-smi but copies hang or move no data

- `nvidia-smi topo -p2p` only reflects advertised caps. Confirm BAR1 is 64GB on
  every GPU (`sudo dmesg | grep 'CMP BAR1'` / `lspci -vv` Region 1).
- Driver-time BAR1 resize cannot grow parent bridge windows. Apply the patches
  in `kernel-patches/` and reboot.
- Check the static BAR1 map with `sudo dmesg | grep CMPUNLOCK_BAR1P2P`. A good
  boot shows `static BAR1 mapped offset 0x0` with the full FB size on every
  GPU, and no `clamping`, `mapping failed` or `BAR1 P2P unavailable` line.
- On CMP 170HX the BAR1 P2P type is set in `kbusInitRegistryOverrides`
  (KernelBus construct), not in `_kbifInitRegistryOverrides`. KernelBif is
  built before the PCI device ID is read, so a device-ID test there never
  matches. If the type stays MAILBOX, RM reserves the P2P mailbox at the
  bottom of BAR1. That moves the static map to offset 512 MiB (`0x20000000`),
  where the client FB no longer fits (`clamping`), and disables the BAR1 P2P
  caps, so every pair reports P2P not supported.
- RM, nv_gpu_ops and UVM add the static offset themselves. Offset 0 is about
  covering all of FB, not about address arithmetic.
- Do not add `RMForceStaticBar1` or `RMPcieP2PType` to
  `NVreg_RegistryDwords`. GSP 610.43.02 returns `NV_ERR_INVALID_REGISTRY_KEY`
  and leaves WPR2 up. For CMP IDs the driver itself sets static BAR1 to
  ENABLE and the P2P type to BAR1; a valid `RMForceStaticBar1` value skips
  that code, so the P2P type stays MAILBOX.
- After that failure the card needs a cold power-off, not `reboot`.
- ACS redirect on a switch (`ReqRedir+`) forces peer traffic up to the root
  complex. Check `lspci -vv | grep ACSCtl`, and see
  [Multi-GPU P2P rings are slow behind PCIe switches](#multi-gpu-p2p-rings-are-slow-behind-pcie-switches).
- Do not set `NVreg_RegistryDwords="ForceP2P=0x11"` and do not unload/reload
  the nvidia module on a live system.

---

## Multi-GPU P2P rings are slow behind PCIe switches

- Linux turns on ACS Request and Completion Redirect on the root ports and
  switch ports whenever an IOMMU driver is active, also with `iommu=pt`.
  `sudo lspci -vv | grep ACSCtl` then shows `ReqRedir+ CmpltRedir+`.
- With redirect on, P2P between two GPUs behind one switch goes up to the root
  complex and back down the same uplink. A pair still runs at full speed, but
  rings through two GPUs on one switch slow down, and the 8-GPU ring
  collapses.
- Measured on 8 GPUs, two behind each of four PCIe switches, each switch on its
  own root port of one EPYC 7J13, Gen2 x16. NCCL `all_reduce`, 1 GiB, bus
  bandwidth in GB/s, median of 3; the P2P columns use `NCCL_P2P_LEVEL=SYS`:

  | GPUs | build without P2P (SHM) | P2P, redirect on | P2P, redirect off |
  |---|---|---|---|
  | 2, one switch | 1.70 | 6.22 | 6.29 |
  | 4, two switches | 1.93 | 4.29 | 6.36 |
  | 4, one per switch | 4.19 | 6.33 | 6.34 |
  | 8 | 2.17 | 0.47 | 6.38 |

- Clear the redirect bits at runtime on the bridges above the GPUs with
  [`acs-redir.sh`](https://github.com/WU-CVGL/cluster-setup/blob/main/scripts/gpu-p2p/acs-redir.sh)
  (`status`, `off`, `restore`), run at boot from a systemd oneshot. A reboot
  restores the kernel's defaults.
- Use this only with `iommu=pt`. With a translating IOMMU, peer addresses are
  IOVAs, and a switch would route them without translation.
- Use it only while no GPU is assigned to a VM. With redirect off, a GPU in a
  VM reaches the other GPUs without going through the IOMMU. `install.sh` arms
  the cards for passthrough by default; restore the redirect before assigning
  one to a VM.
- `pci=disable_acs_redir=` does the same at boot, but it matches bridges by PCI
  ID, so it also hits every other bridge with that ID, such as the root ports
  of NICs and NVMe drives. When the root ports and switch ports have different
  IDs, the value is a `;`-separated list, and GRUB's generated `linux` line
  cuts it at the first `;`, so the kernel gets only the first ID.
- NCCL's default keeps SHM between GPUs on different root ports. Set
  `NCCL_P2P_LEVEL=SYS` (for example in `/etc/nccl.conf`, mounted read-only
  into containers) to use P2P there too.
- Setup, the boot unit and the full measurements:
  [GPU P2P on GeForce and CMP](https://github.com/WU-CVGL/cluster-setup/blob/main/docs/05_GPU_P2P_GeForce_and_CMP.md).

---

## BAR1 is still 64MB after `pci=realloc`

- Cmdline realloc cannot grow a BAR that enumeration already sized as 64MB.
  The host-kernel patches in `kernel-patches/` have to run before
  `pci_read_bases()`. `dmesg | grep 'CMP 170HX'` should show
  `BAR1 REBAR programmed to 64GB` with `cap 0x1ffc00`, not `0xffffffff`.

---

## PCIe still at Gen1 after install

- Confirm IOMMU passthrough mode is enabled. Depending on your operating system, enabling IOMMU passthrough can vary.

- If this still persists, refer to the Discord protocol at the end of the document.

---

## A rebuilt nvidia.ko shows the same srcversion

- `modinfo -F srcversion` hashes only the sources built under `kernel-open/`.
  The RM core (`src/nvidia`), where most patches here apply, is linked in as
  the binary object `nv-kernel.o`, so builds that differ there report the same
  srcversion. Three different cmpunlocker builds on one host reported the same
  srcversion while their `nvidia.ko` hashes differed.
- To tell builds apart, compare
  `sha256sum /lib/modules/$(uname -r)/updates/cmpunlocker/nvidia.ko`, and check
  the boot log for the lines the new patches add.

---

## Discord protocol

If you have tried the above steps and are still having issues, please follow these steps to get help in the [Discord community](https://discord.gg/CdHSakKSFv):

1. Open a ticket in the #issue-support channel.

2. Provide the following information in your ticket:
   - Your operating system and version
   - Your GPU model and driver version
   - The output of `sudo dmesg | grep SEC2_DEBUG`
   - Latest install log (if applicable)

