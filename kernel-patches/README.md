# Kernel patches

Two patches against the **host kernel**, not the NVIDIA driver. `install.sh`
does not apply them. They are **not** required for the memory / SM / PCIe Gen2
unlock — that all works on a stock kernel. They exist to make **BAR1 P2P**
usable, and to make the large BAR1 come up on a normal boot instead of needing
a `kexec` trick.

A default `install.sh` run patches the NVIDIA modules for BAR1 P2P. Do not
pass `RMForceStaticBar1` / `RMPcieP2PType` through `NVreg_RegistryDwords` —
GSP 610.43.02 rejects those keys. Without these kernel patches, some GPUs
silently keep a 64MB BAR1 and BAR1 P2P cannot cover framebuffer.

Sourced from [bayley/cmpunlocker](https://github.com/bayley/cmpunlocker). The
hunks were written against Linux 7.0; they may need a one-line context tweak
on other series. Keep the distro kernel installed as a GRUB fallback.

## 0001 — `pbus_size_mem()`: size bridge windows for child alignment padding

`pbus_size_mem()` accumulates a bridge window's size with

```c
size += max(r_size, align);
```

which is correct only when a child's size is a multiple of its alignment. Every
child has to *start* at an aligned address, so a child whose size is not a
multiple of its alignment leaves a gap before the next one, and that gap is never
budgeted. The window then comes out too small to place all the children even
though the arithmetic says it fits.

Example: four GPUs each needing a 64GB BAR1 (64GB alignment) plus a 32MB BAR3.
Each downstream port window is 64GB+32MB and must begin on a 64GB boundary, so
it really occupies 128GB. Four such children need 512GB; summing sizes without
padding only reserved 256GB, and two GPUs silently got no BAR1.

The same padding repeats per root port. Size the BIOS MMIO-high window (and
`pci=hpmmioprefsize`) for the whole span. The failure mode without this patch
is silent — enumeration reports success and some GPUs simply have no Region 1 —
so check all of them, not just the first:

```bash
for d in $(lspci -D -d 10de: -n | awk '{print $1}'); do
    echo "$d $(sudo lspci -vv -s $d | grep -c 'Region 1')"
done
```

`ALIGN(r_size, align)` budgets the padding. It is identical to `max()` whenever
`r_size <= align`, which covers every ordinary device BAR (size == alignment), so
only the mis-sized bridge windows change.

This is a generic PCI bug, not a CMP one — it just needs unusually large,
unusually aligned BARs to become visible.

## 0002 — `pci_fixup_early` quirk: program BAR1 REBAR to 64GB before enumeration

The card ships with BAR1 fused to 64MB. Two CYA registers unlock the Resizable
BAR capability to advertise up to 64GB, but doing that from the nvidia driver at
probe time is too late: enumeration has already sized every bridge window for a
64MB BAR1, so `pci_resize_resource()` has nowhere to put the larger BAR and steps
back down.

`pci_fixup_early` runs in `pci_setup_device()` **before** `pci_read_bases()`, so
doing the unlock there makes enumeration see a 64GB BAR1 directly. Two details
matter:

- `dev->resource[]` is not populated that early, so BAR0 is read straight from
  config space.
- Memory decode is not necessarily enabled yet. With it off, every MMIO read
  returns `0xffffffff` and every write is silently discarded — the quirk appears
  to succeed while doing nothing. It is enabled for the duration and restored
  afterwards, and all-ones is treated as "window not responding", leaving the BAR
  at its stock size rather than programming it blind.

Needs 0001 as well, or the parent window is under-sized and only some GPUs get a
BAR.

## Building

Use kernel source that matches the series you actually boot (`uname -r`), not
an arbitrary distro `linux-source` metapackage. Apply both patches, keep the
stock kernel as a GRUB fallback via `LOCALVERSION=-cmp`, and pin whatever
packages your distro uses to install that series so an upgrade does not
silently drop the patches.

```bash
# Debian/Ubuntu example: source for the running series, then:
patch -p1 < /path/to/kernel-patches/0001-*.patch
patch -p1 < /path/to/kernel-patches/0002-*.patch

cp /boot/config-"$(uname -r)" .config
scripts/config --set-str LOCALVERSION "-cmp"
scripts/config --disable LOCALVERSION_AUTO
scripts/config --disable MODULE_SIG_ALL
scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --disable DEBUG_INFO
scripts/config --enable  DEBUG_INFO_NONE
make olddefconfig
make -j"$(nproc)"

sudo make modules_install
sudo cp arch/x86/boot/bzImage /boot/vmlinuz-"$(make -s kernelrelease)"
sudo update-initramfs -c -k "$(make -s kernelrelease)"
sudo update-grub
```

If the patched kernel misbehaves, pick the stock GRUB entry: 64MB BARs, no P2P.

**Pin the kernel packages afterwards.** A distro kernel upgrade arrives without
these patches and silently drops both P2P and the large BARs. Hold the image
and headers packages for the series you boot, including the running
`linux-image-$(uname -r)` / `linux-headers-$(uname -r)` (or the equivalent on
rpm/pacman).

## Verifying

```bash
sudo dmesg | grep 'CMP 170HX'
#  CMP 170HX: BAR1 REBAR programmed to 64GB before enumeration (cap 0x1ffc00 ctrl 0x1001)
#  cap/ctrl of 0xffffffff means the register window was not reachable

for d in $(lspci -D -d 10de: -n | awk '{print $1}'); do
    echo "===== $d ====="
    sudo lspci -vv -s "$d" | grep -E 'Region 1|Region 3'
done
# Region 1 should be [size=64G] on every GPU
```
