# Architecture

## Overview

cmpunlocker restores full compute and memory capabilities to the NVIDIA CMP
170HX by patching the nvidia-open kernel modules. A successful installation or
removal commits an on-disk module state while leaving the currently running
NVIDIA driver untouched. Activating that committed state requires a complete
shutdown followed by power-on; a warm reboot is not an accepted transition.

The CMP 170HX is physically a complete GA100 die (same silicon as the A100) but with compute and memory artificially restricted via firmware and OTP configuration. cmpunlocker bypasses these restrictions at the driver level without requiring hardware modifications.

---

## The Problem

The CMP 170HX ships with:

- **Disabled SMs (Streaming Multiprocessors)**: SS0 and SS1 (Suspension State registers) artificially disable clusters of SMs
- **Restricted memory geometry**: The HBM2e controller is configured for 8GB or 10GB instead of the full 64GB or 40GB the die supports
- **PCIe Gen 1 cap**: The link is trained down to Gen 1 speeds instead of the Gen 2 the die supports
- **JTAG lockout**: Host2Jtag register access is locked behind PLM permissions
- **Firmware locks**: OTP (One-Time Programmable) fuses prevent reconfiguration at runtime

All of the above are enforced during GSP (GPU System Processor) boot, which happens when the driver loads.

---

## The Unlock Approach

Instead of modifying OTP (which is physically locked), cmpunlocker intercepts the driver's boot flow and reconfigures the GPU before OTP locks take effect:

1. **Open the SEC2 Booter PMM** — disable security restrictions on the Booter so it can execute custom PLM sequences, including the PCIe (XP3G) and JTAG (PJTAG) PLMs
2. **Configure memory geometry** — write CFG1 (config) and LMR (LM Request) registers to unlock full HBM2e capacity
3. **Enable all SMs** — write SS0 and SS1 (Suspension State) to re-enable disabled SM clusters
4. **Retrain the PCIe link** — request and retrain to Gen 2 now that the XP3G PLMs are open
5. **Finalize safely** — preserve the GSP/WPR carve-out returned by firmware and let the normal PMA (Physical Memory Allocator) initialization register only public FB regions

---

## Technical Components

### SEC2 Booter & PLM

The SEC2 Booter executes firmware sequences (PLMs: "Program Logic Modules") during GPU power-on and reset. Normally, PLMs are locked to a restricted set via security fuses.

cmpunlocker:
- Patches the driver to open the PMM (Permute Mask Model) during boot
- Writes the tested per-register masks: the PLM table uses `0xffffffff` except
  `WPR_CFG`, which uses `0xfffff0ff`
- Injects custom PLM sequences that reconfigure GPU state

The implemented per-entry diagnostic has this form:
```
SEC2_DEBUG: PLM[<index>] <name>(0x<addr>) attempt=<n> status=0x<status> reg=0x<value>
```

Booter status codes like `0x31` or `0xffff` during an explicitly logged PLM
attempt can be followed by a successful normal BooterLoad, but that alone is
not a health verdict. Post-boot acceptance requires `sudo ./verify.sh` to
return exit status 0.

---

### Memory Geometry (CFG1 & LMR)

The GPU memory controller is configured by two registers:

| Card | CFG1 | LMR | Unlocked Capacity |
|---|---|---|---|
| 8GB | `0x02779000` | `0x0000020B` | 64GB |
| 10GB | `0x02669000` | `0x0000028A` | 40GB |

- **CFG1**: Memory configuration register (address mapping, bank layout)
- **LMR**: LM (Local Memory) Request register (capacity/geometry selector)

cmpunlocker writes both during the unlock sequence. Geometry is selected at
runtime for each GPU by PCI device ID: `10de:20c2` receives the 64 GB values and
`10de:2082` receives the 40 GB values. The installer's optional `--profile`
argument changes only the stored metadata label and never overrides this PCI-ID
selection.

---

### Compute State (SS0 & SS1)

SS0 and SS1 are Suspension State registers that control which SM clusters are active:

- Stock firmware sets these to disable compute clusters
- cmpunlocker writes the project-tested values `SS0=0x88888888` and `SS1=0x00000008`
- The GPU can then use full compute throughput

Expected dmesg output:
```
SEC2_DEBUG: POST-WRITE SS0=0x88888888 SS1=0x00000008
```

---

### FB, GSP/WPR, and PMA safety

After core reconfiguration, GSP recalculates the frame-buffer layout for the
new geometry. The top of FB contains the non-WPR heap, WPR metadata, GSP heap,
firmware image, boot binary, and VGA workspace. These ranges are not ordinary
VRAM and must remain reserved.

cmpunlocker enforces this invariant before the normal Physical Memory Allocator
registers any region:

```text
public_PMA ∩ [gspFwRsvdStart, fbSize) = ∅
```

The driver refuses PMA initialization if WPR metadata is unavailable, its FB
size disagrees with the active geometry, the FB-region table is malformed or
out of bounds, or a public FB region reaches into the protected range. The
former late-PMA path reclassified the native top 142 MiB protected carve-out as
public. On the affected host, a CE2 physical write into that range produced
Xid 31/`REGION_VIOLATION`, followed by a scrub timeout and downstream
PMA/context OOM. That path has been removed; the driver now validates the
native table without extending or synthesizing public regions. In particular,
`10de:2082` must supply a valid native 40 GiB table or initialization fails
closed.

Successful initialization emits an ordered proof chain. The first record
describes the native GSP table; the second describes the materialized,
heap-clipped public ranges consumed by standard PMA registration:

```text
SEC2_DEBUG_FB_LAYOUT: validated fbSize=0x... protectedStart=0x... publicBytes=0x... capacityFloor=0x... reservedRegionBytes=0x... regions=... status=safe build=cmpunlocker-safety-v3
SEC2_DEBUG_PMA_GUARD: fbSize=0x... protectedStart=0x... publicBytes=0x... pmaBytes=0x... status=safe build=cmpunlocker-safety-v3
```

Here `capacityFloor = fbSize - 2 GiB` is a product-capacity acceptance policy,
not the protected-memory proof. Safety comes from exact region coverage, the
reserved top carve-out beginning at `protectedStart`, and the final equality
between heap-clipped `publicBytes` and `pmaBytes`.

The post-BL payload path is also retry-safe. Every refill resets SEC2 before
any in-place payload write or descriptor reallocation; if reset fails, neither
operation proceeds. After a successful reset, the size check restores a
`0xf800` descriptor when needed by allocating the replacement first, then
freeing and swapping out the old descriptor; allocation failure leaves the old
descriptor intact. Undersized mappings are rejected before any fixed-offset
write. Rebuilding the stock signature likewise resets SEC2 before releasing
the payload descriptor. These orderings prevent active SEC2 DMA from targeting
storage while it is being written or freed. The saved stock signature is freed
during GSP teardown.

---

### PCIe Link Speed (Gen 2)

The PCIe link is trained down to Gen 1 by stock firmware. cmpunlocker retrains it to Gen 2:

- Writes `0xffffffff` to the XP3G/XVE/OPTB permission entries; this does not
  change the distinct `WPR_CFG=0xfffff0ff` mask
- Clears the OPT_GEN23 lock and writes the XP3G override registers to request Gen 2
- Forces a link retrain against the GPU and its upstream PCIe bridge
- An early-boot systemd service re-requests Gen 2 on a short retry loop, since the window the driver opens the capability in is brief and can be missed

Implemented diagnostics include:
```
SEC2_DEBUG: PCIe pre  CAP=... STAT=... speed=1
SEC2_DEBUG: PCIe retrain done CAP=... STAT=... speed=2
```

---

### JTAG (Host2Jtag)

Host2Jtag register access is locked behind the same class of PLM permission as the Booter and memory controller:

- Stock firmware leaves the PJTAG PLM registers closed, blocking JTAG-based register access
- cmpunlocker writes `0xffffffff` specifically to the PJTAG PLM entries (while
  `WPR_CFG` uses `0xfffff0ff`)
- With them open, JTAG access to the GPU works the same as on an unrestricted A100

---

## Boot Flow

1. **Driver loads** → nvidia-open kernel modules initialize
2. **GSP power-on** → SEC2 Booter executes (normally-locked path)
3. **cmpunlocker intercepts** → PMM is opened, custom PLM sequences run
   - Tested PLM masks applied, including `WPR_CFG=0xfffff0ff`
   - CFG1/LMR written (memory geometry)
   - SS0/SS1 written (compute state)
   - PCIe link retrained to Gen 2
   - GSP protected ranges preserved and checked before PMA registration
4. **GSP boot completes** → the driver can expose the GPU, but health is not
   established by boot completion or reported capacity
5. **Safety acceptance** → `sudo ./verify.sh` returns exit status 0; a
   65536 MiB or 40960 MiB `nvidia-smi` result alone is insufficient

---

## On-disk persistence and activation

The unlock is applied by **patched kernel modules**, not a userspace daemon:

- A successful install commits the patched NVIDIA modules to
  `/lib/modules/$(uname -r)/updates/cmpunlocker/`
- Installation verifies the complete on-disk module set; it does not replace
  the modules already driving the running GPUs
- The files remain installed on disk until `./remove.sh` is run
- After a successful installation or removal, complete shutdown and power-on
  are mandatory; hot module reload and warm reboot are not accepted activation
  paths

The `card_profile` file in that directory is an installation metadata label.
It does not select geometry: the patched driver always chooses the 64 GB or
40 GB values from each GPU's PCI device ID.

Install and remove share one root-owned lifecycle lock. Module publication uses
a durable journal outside the kernel's `depmod` scan tree and an atomic
same-filesystem directory handoff. A retry resolves supported build-journal
phases before starting new module publication; ambiguous legacy objects are
rejected rather than silently adopted. The installed set is accepted only when
all five module filenames, internal names, versions, vermagic values, source
versions, safety markers, physical paths, and resolver results agree.

If one exact current-kernel NVIDIA DKMS tuple conflicts with the patched set,
installation records a durable tuple receipt before mutation and converges the
cleanup forward only after the patched module directory has committed. The
DKMS format-1 receipt is valid only when that tuple had no
`(Original modules exist)` status and no physical
`original_module/$KVER/$ARCH` payload before the first receipt. Installation
fails before mutation if either exists; removal does not consume or restore
such payloads. Other DKMS records remain outside the receipt.

Removal has a separate global forward-only barrier. Before publishing it, all
required DKMS build payloads must be durable and CMP modules plus firmware stay
at their original patched state. After the barrier, retries may only advance
the complete kernel set toward stock. If an external DKMS build was interrupted
while its payload hashes were still pending, automatic reset is allowed only
when the version-global `build`, `.tmp_*`, canonical tuple B, and active link
are all proven absent. Any residue is preserved without deletion or rebuild
and requires manual reconciliation. Likewise, rollback-directory orphans
without a forward marker are inventoried globally and rejected without CMP,
firmware, DKMS, `depmod`, or initramfs mutation; kernels sharing those
resources must be reconciled as one set.

Gen2 helper files use hash-bound ownership state. Fresh installations no longer
modify IOMMU command-line sources or generated boot outputs: they only validate
an existing receipt or confirm that the required parameters are already set,
and otherwise require distribution-specific manual configuration. Historical
IOMMU format-1 state is usable only with its exact base/expected (B/E)
snapshots and fixed backend/target authority. Exact legacy GRUB derivations may
be adopted without rewriting boot artifacts; ambiguous sidecars, post-install
edits, pending automatic transactions, and `kernel-install` output require
manual reconciliation.

Initramfs generation is kernel-specific. With `mkinitcpio`, the scripts derive
one auditable `default_image` for the exact kernel and invoke `mkinitcpio` with
an explicit kernel and output path. A nonempty `default_kver` takes priority
over `ALL_kver`, and a nonempty `default_config` takes priority over
`ALL_config`. Ambiguous presets and active UKI/EFI, options, cmdline, splash,
or kerneldest settings are rejected. `update-initramfs`, `dracut`, and
`mkinitcpio` still publish directly to distribution boot artifacts; that live
publication is not completely crash-atomic across distributions and is an
explicit residual risk outside the atomic module-directory handoff.

The legacy `/opt/cmpunlocker` directory has no per-file deletion manifest. It
is removed only when its canonical path and parent are root-owned, safe,
same-device, free of mount points, and the directory is empty. Any contents are
preserved and removal stops for manual reconciliation.

---

## Known Limitations

- **Secure Boot must be disabled** — patched modules are unsigned
- **Supported nvidia-open releases are 610.57.04, 610.43.03, and 610.43.02** — stock NVIDIA proprietary modules use different boot paths
- **Linux only** — GSP boot path is Linux-specific (Windows WDDM driver is fundamentally different)
- **Kernel headers required** — modules must be compiled for the running kernel version
- **A complete shutdown and power-on are mandatory after install or removal**
  — module reload and warm reboot are unsupported transition paths
- **IOMMU boot configuration is manual for fresh installs** — the installer
  verifies existing state but does not rewrite bootloader inputs or generated
  boot artifacts
- **Initramfs publication is not fully crash-atomic across distributions** —
  after an interrupted generator, do not power-cycle until the reported state
  has been reconciled
- **Some removal interruptions require manual reconciliation** — non-forward
  rollback orphans and external DKMS build residue are deliberately preserved
