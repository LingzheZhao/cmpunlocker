# Architecture

## Overview

cmpunlocker restores full  compute and memory capabilities to the NVIDIA CMP 170HX by patching the nvidia-open kernel modules. The unlock runs automatically during driver initialization and persists across reboots.

The CMP 170HX is physically a complete GA100 die (same silicon as the A100) but with compute and memory artificially restricted via firmware and OTP configuration. cmpunlocker bypasses these restrictions at the driver level without requiring hardware modifications.

---

## The Problem

The CMP 170HX ships with:

- **Disabled SMs (Streaming Multiprocessors)**: SS0 and SS1 (Suspension State registers) artificially disable clusters of SMs
- **Restricted memory geometry**: The HBM2e controller is configured for 8GB
  or 10GB; the supported unlock targets are 64GB/40GB, plus a researched but
  hardware-unvalidated 80GB target for the 10GB card
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
5. **Validate and finalize** — restore the stock signature, let the GSP build its
   native FB map, and fail closed unless the WPR/FB/PMA boundaries match

---

## Technical Components

### SEC2 Booter & PLM

The SEC2 Booter executes firmware sequences (PLMs: "Program Logic Modules") during GPU power-on and reset. Normally, PLMs are locked to a restricted set via security fuses.

cmpunlocker:
- Patches the driver to open the PMM (Permute Mask Model) during boot
- Sets PLM permissions to `0xffffffff` (all PLMs enabled)
- Injects custom PLM sequences that reconfigure GPU state

Expected dmesg output:
```
SEC2_DEBUG: PLMs opening to 0xffffffff
SEC2_DEBUG: Executing unlock sequence...
```

Booter status codes like `0x31` or `0xffff` during early PLM passes are often harmless if the final boot succeeds.

---

### Memory Geometry (CFG1 & LMR)

The GPU memory controller is configured by two registers:

| Card | CFG1 | LMR | Unlocked Capacity |
|---|---|---|---|
| 8GB | `0x02779000` | `0x0000020B` | 64GB |
| 10GB (default) | `0x02669000` | `0x0000028A` | 40GB |
| 10GB (experimental) | `0x02779000` | `0x0000028B` | 80GB |

- **CFG1**: Memory configuration register (address mapping, bank layout)
- **LMR**: LM (Local Memory) Request register (capacity/geometry selector)

cmpunlocker writes both during the unlock sequence. The kernel selects the
8GB/10GB hardware variant from the PCI ID. The build target selects whether a
`10de:2082` uses 40G or the explicit experimental 80G geometry, and the same
selection is compiled into SEC2 write, Booter readback, FB validation, PMA
validation, and the build fingerprint.

---

### Compute State (SS0 & SS1)

SS0 and SS1 are Suspension State registers that control which SM clusters are active:

- Stock firmware sets these to disable ~50% of the SMs
- cmpunlocker writes the reviewed values `SS0=0x88888888` and
  `SS1=0x00000008`, then requires exact readback
- The GPU can then use full compute throughput

Expected dmesg output:
```
SEC2_DEBUG: SS0 = 0xffffffff
SEC2_DEBUG: SS1 = 0xffffffff
```

---

### FB & Physical Memory Allocator validation

After core reconfiguration, the GSP publishes its native framebuffer map. The
driver does not extend or repair that map. It checks exact coverage, alignment,
the protected top carveout, WPR metadata, and public byte count before heap/PMA
registration. It then requires PMA's reported total to equal the validated
public bytes. Any mismatch aborts initialization.

---

### PCIe Link Speed (Gen 2)

The PCIe link is trained down to Gen 1 by stock firmware. cmpunlocker retrains it to Gen 2:

- Opens the XP3G/XVE/OPTB PLM registers to `0xffffffff`, same pattern as the other PLM unlocks
- Clears the OPT_GEN23 lock and writes the XP3G override registers to request Gen 2
- Forces a link retrain against the GPU and its upstream PCIe bridge
- An early-boot systemd service re-requests Gen 2 on a short retry loop, since the window the driver opens the capability in is brief and can be missed

Expected dmesg output:
```
SEC2_DEBUG: PCIe pre  CAP=... STAT=... speed=1
SEC2_DEBUG: PCIe post CAP=... STAT=... speed=2
```

---

### BAR1 resize (64GB)

During PCI probe, before GSP boot, cmpunlocker unlocks Resizable BAR on
`10de:20c2` and `10de:2082` and attempts to grow BAR1 up to 64GB.

---

### JTAG (Host2Jtag)

Host2Jtag register access is locked behind the same class of PLM permission as the Booter and memory controller:

- Stock firmware leaves the PJTAG PLM registers closed, blocking JTAG-based register access
- cmpunlocker writes `0xffffffff` to the PJTAG PLM registers alongside the rest of the PLM-opening sequence
- With them open, JTAG access to the GPU works the same as on an unrestricted A100

---

## Boot Flow

1. **Driver loads** → nvidia-open kernel modules initialize
2. **GSP power-on** → SEC2 Booter executes (normally-locked path)
3. **cmpunlocker intercepts** → PMM is opened, custom PLM sequences run
   - PLMs set to unrestricted mode (including XP3G and PJTAG)
   - CFG1/LMR written (memory geometry)
   - SS0/SS1 written (compute state)
   - PCIe link retrained to Gen 2
   - Stock signature restored; native FB/WPR and PMA layouts validated
4. **GSP boot completes** → GPU is now fully unlocked
5. **Driver ready** → `nvidia-smi` shows about 65536 MiB (8GB hardware),
   40960 MiB (10GB default), or 81920 MiB (10GB experimental), with both safe
   proof logs present

---

## Persistence Across Reboot

The unlock is applied by **patched kernel modules**, not a userspace daemon:

- All five NVIDIA modules are checksummed and transactionally installed to
  `/lib/modules/$(uname -r)/updates/cmpunlocker/`
- A per-module depmod override makes that exact directory win over retained
  stock/DKMS modules; `modinfo` verifies every resolved path
- Every cold boot runs the patched sequence. Hot reload and warm reboot are
  explicitly unsupported because memory/WPR geometry persists in GPU state
- The unlock persists indefinitely until `./remove.sh` is run

The installed inventory, 2082 target, checksums, and target-specific build
fingerprint are stored beside the modules and verified after boot.

---

## Known Limitations

- **Secure Boot must be disabled** — patched modules are unsigned
- **Requires a version listed in `driver/VERSION`** — the stock proprietary
  driver has different boot paths and cannot be patched the same way
- **80G is experimental** — source/build validation is complete, but sustained
  hardware validation above 40 GiB is not
- **Linux only** — GSP boot path is Linux-specific (Windows WDDM driver is fundamentally different)
- **Kernel headers required** — modules must be compiled for the running kernel version
