# Architecture

## Overview

cmpunlocker restores full  compute and memory capabilities to the NVIDIA CMP 170HX by patching the nvidia-open kernel modules. The unlock runs automatically during driver initialization and persists across reboots.

The CMP 170HX is physically a complete GA100 die (same silicon as the A100) but with compute and memory artificially restricted via firmware and OTP configuration. cmpunlocker bypasses these restrictions at the driver level without requiring hardware modifications.

---

## The Problem

The CMP 170HX ships with:

- **Disabled SMs (Streaming Multiprocessors)**: SS0 and SS1 (Suspension State registers) artificially disable clusters of SMs
- **Restricted memory geometry**: The HBM2e controller is configured for 8GB or 10GB instead of the full 64GB or 40GB the die supports
- **Firmware locks**: OTP (One-Time Programmable) fuses prevent reconfiguration at runtime

All three are enforced during GSP (GPU System Processor) boot, which happens when the driver loads.

---

## The Unlock Approach

Instead of modifying OTP (which is physically locked), cmpunlocker intercepts the driver's boot flow and reconfigures the GPU before OTP locks take effect:

1. **Open the SEC2 Booter PMM** — disable security restrictions on the Booter so it can execute custom PLM sequences
2. **Configure memory geometry** — write CFG1 (config) and LMR (LM Request) registers to unlock full HBM2e capacity
3. **Enable all SMs** — write SS0 and SS1 (Suspension State) to re-enable disabled SM clusters
4. **Finalize** — perform late PMA (Power Management Array) adjustments and allow normal boot to continue

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
| 10GB | `0x02669000` | `0x0000028A` | 40GB |

- **CFG1**: Memory configuration register (address mapping, bank layout)
- **LMR**: LM (Local Memory) Request register (capacity/geometry selector)

cmpunlocker writes both during the unlock sequence. Detection of 8GB vs 10GB happens at install time via Python script (reads `nvidia-smi` output).

---

### Compute State (SS0 & SS1)

SS0 and SS1 are Suspension State registers that control which SM clusters are active:

- Stock firmware sets these to disable ~50% of the SMs
- cmpunlocker writes `0xffffffff` to both, enabling all clusters
- The GPU can then use full compute throughput

Expected dmesg output:
```
SEC2_DEBUG: SS0 = 0xffffffff
SEC2_DEBUG: SS1 = 0xffffffff
```

---

### FB & PMA Adjustments

After core reconfiguration, the frame buffer (FB) and power management array (PMA) are adjusted to support the new memory geometry and active SMs:

- FB is resized to reflect the new memory capacity
- PMA is reconfigured for the enabled SM clusters
- These changes are performed in "late PMA" phase, near the end of boot

---

## Boot Flow

1. **Driver loads** → nvidia-open kernel modules initialize
2. **GSP power-on** → SEC2 Booter executes (normally-locked path)
3. **cmpunlocker intercepts** → PMM is opened, custom PLM sequences run
   - PLMs set to unrestricted mode
   - CFG1/LMR written (memory geometry)
   - SS0/SS1 written (compute state)
   - Late PMA adjustments applied
4. **GSP boot completes** → GPU is now fully unlocked
5. **Driver ready** → `nvidia-smi` shows 65536 MiB (8GB) or 40960 MiB (10GB)

---

## Persistence Across Reboot

The unlock is applied by **patched kernel modules**, not a userspace daemon:

- Modified `nvidia-drm.ko` and `nvidia.ko` are installed to `/lib/modules/$(uname -r)/updates/cmpunlocker/`
- These modules load before the stock NVIDIA modules (due to the `updates/` directory priority)
- Every time the driver initializes (on boot or after a reload), the patched sequence runs
- The unlock persists indefinitely until `./remove.sh` is run

Card profile (8GB vs 10GB) is stored in `/lib/modules/$(uname -r)/updates/cmpunlocker/card_profile` at install time and used during every boot.

---

## Known Limitations

- **Secure Boot must be disabled** — patched modules are unsigned
- **Requires nvidia-open 610.43.0x** — stock NVIDIA proprietary driver has different boot paths and cannot be patched the same way
- **Linux only** — GSP boot path is Linux-specific (Windows WDDM driver is fundamentally different)
- **Kernel headers required** — modules must be compiled for the running kernel version

