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
- Do not add `RMForceStaticBar1` or `RMPcieP2PType` to
  `NVreg_RegistryDwords`. GSP 610.43.02 returns `NV_ERR_INVALID_REGISTRY_KEY`
  and leaves WPR2 up; BAR1 P2P type is forced in the driver for CMP IDs.
- After that failure the card needs a cold power-off, not `reboot`.
- ACS redirect on a switch (`ReqRedir+`) forces peer traffic up to the root
  complex. Check `lspci -vv | grep ACSCtl`.
- Do not set `NVreg_RegistryDwords="ForceP2P=0x11"` and do not unload/reload
  the nvidia module on a live system.

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

## Discord protocol

If you have tried the above steps and are still having issues, please follow these steps to get help in the [Discord community](https://discord.gg/CdHSakKSFv):

1. Open a ticket in the #issue-support channel.

2. Provide the following information in your ticket:
   - Your operating system and version
   - Your GPU model and driver version
   - The output of `sudo dmesg | grep SEC2_DEBUG`
   - Latest install log (if applicable)

