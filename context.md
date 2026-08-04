# cmpunlocker JTAG unlock — context.md

Single source of truth for this investigation. Read this file first, in full, before doing anything.
Update it before ending any session — a fresh agent must be able to resume cold from this file alone.

## Rules (standing instructions from the user)

- Reboots are allowed and expected. **Never use `shutdown` — only `sudo reboot`.** After rebooting,
  wait ~45s then `ssh amogh@mac` back in.
- No comments in any file this project creates (patches, python tools, etc.). This file is prose
  documentation, not code — it is exempt and should stay detailed.
- No git commits unless explicitly asked.
- This repo (`/home/amogh/Downloads/cmpunlocker`) is the canonical driver-patching/installer product
  repo, pushed to `github.com/amoghmunikote/cmpunlocker`. There is a **second, separate** checkout at
  `/home/amogh/Documents/cmpunlocker` (branch `Gen3`) which is a concluded PCIe-Gen3-unlock research
  project with its own 2631-line `context.md` and `tools/gen3/` register-probing scripts — useful as
  prior art (its `Bar0` mmap helper pattern, decode-trap tooling, the "measure, don't assume" standard
  it established) but **not** the repo this JTAG work lives in. Do not confuse the two.
- Hardware: CMP 170HX, GA100 die (same silicon as A100), PCI ID `10de:20c2` (8GB variant). BDF was
  `0000:80:00.0` as of this session — **re-derive with `lspci -d 10de:`, don't hardcode**, other GA100
  boxes in this user's fleet use eGPU docks where BDF drifts across reboots (this one may not, but
  check).

## Goal

Get JTAG working, per the user's rumor: *"JTAG was labeled as elevated to L3... or the registers can
be writable from HS."* Both halves of that rumor are now **measured, not just plausible** — see §1.

## §1 — 2026-08-04: Research + PLM unlock implemented, verification in progress

### Finding: JTAG register block and its privilege gating

`dev_host.h` (ga100 hwref, from the leaked NVIDIA source at `F:\170\CMP` on the Windows host) defines
the on-chip "Host2Jtag" bridge — a PRI-bus/BAR0-mapped register block, NOT a separate serial TAP
interface floating off the PRI bus:

```
NV_PJTAG_ACCESS_CTRL                  0xC800   INSTR_ID[7:0] REG_LENGTH[18:8] DWORD_EN[24:19]
                                                CLUSTER_SEL[29:25] CTRL_STATUS[30] REQ_CTRL[31]
NV_PJTAG_ACCESS_DATA                  0xC804
NV_PJTAG_ACCESS_CONFIG                0xC808   REG_LENGTH[7:0] DWORD_EN[15:8] BURST[16] READ_WRITE[17]
                                                CLUSTER_SEL[24:22] SHFT_DIS[25] ...
NV_PJTAG_ACCESS_MASK                  0xC80C
NV_PJTAG_ACCESS_CONFIG2               0xC810
NV_PJTAG_ACCESS_PRIV_LEVEL_MASK       0xC840   gates CTRL/DATA/CONFIG/MASK/CONFIG2 above
NV_PJTAG_ACCESS_SEC                   0xC844   SHA2_EN[0] MODE[4]=STANDARD(0)/ISM_ONLY(1)
                                                SWITCH_TO_ISM_ONLY[5] SWITCH_TO_STANDARD[6]
NV_PJTAG_ACCESS_SEC_PRIV_LEVEL_MASK   0xC848   gates ACCESS_SEC above
```

PLM register format (standard NVIDIA convention, same as every other PLM in this project's existing
patches): bits `3:0` = read protection, bits `7:4` = write protection, each a 4-bit per-level enable
mask (bit0=L0/host, bit1=L1/PMU-GSP, bit2=L2, bit3=L3/SEC2). `0xF` = all levels enabled, `0x8` =
level-3-only.

`NV_PJTAG_ACCESS_PRIV_LEVEL_MASK`'s write-protection field is explicitly documented as fuse-driven:
`__FUSE_SIGNAL: "pjtag_access"`, default `LEVEL3_ENABLED_FUSE1 = 0x8` when the fuse is blown (which it
is on production silicon).

**Measured live on this card, before the patch (read-only BAR0 mmap, no writes):**
```
0xC840 (PJTAG_ACCESS_PRIV_LEVEL_MASK)     = 0xffffff8f   (write protection nibble = 0x8, L3-only)
0xC844 (PJTAG_ACCESS_SEC)                 = 0x00000010   (MODE=1, ISM_ONLY)
0xC848 (PJTAG_ACCESS_SEC_PRIV_LEVEL_MASK) = 0xffffff8f   (write protection nibble = 0x8, L3-only)
0x1620 (PBUS_ACCESS)                      = 0x003040ff   (bit5 JTAG enable = 1, already on)
0x1634 (PBUS_ACCESS__PRIV_LEVEL_MASK)     = 0x000000cf   (L2+L3 write only — not touched, already
                                                            irrelevant since bit5 is already 1)
```
This is the rumor's first half, measured: **JTAG write access is hard-locked to privilege level 3.**

### Finding: RM's own source confirms the fix is HS/L3-derived

`kernel/gpu/pascal/gpugp100.c`, `gpuJtagReadSeq_GP100`/`gpuJtagWriteSeq_GP100` (lines ~110-290,
no GA100-specific override found — GA100 is expected to reuse this HAL routine, not yet confirmed
empirically): after writing `NV_PJTAG_ACCESS_CTRL`, both functions check
`if (GPU_REG_RD32(pGpu, NV_PJTAG_ACCESS_CTRL) == 0)` and if so print:
*"No write access to host2jtag (most likely due to decode traps). May need to use HULK license to
lower security"* and return `NV_ERR_NOT_SUPPORTED`. This is the rumor's second half, confirmed by
NVIDIA's own driver engineers: the intended unlock path is an HS-derived privilege-lowering operation.

### The existing HS/L3 write primitive this project already has, and the fix applied

`driver/patches/0001-sec2-postbl-plm-ss-cfg.patch` (present in both repo checkouts) patches
`src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` to run a SEC2 Booter DMA-overflow ROP chain at every GSP
boot (function `kgspSec2PostblTimingRefillPayload` + `kgspExecuteBooterLoad_HAL`, guarded by
`_kgspSec2PostblTimingEnabled()` which checks PCI device ID `0x20C2`/`0x2082`). It walks a
`plmTable[]` of `(addr, value, name)` triples, writing each via the Booter's elevated context and
verifying by readback, logging `SEC2_DEBUG: PLM[n] NAME(addr) attempt=N status=0x.. reg=0x..` to
`dmesg`. Before this session it opened 9 registers (`WPR_CFG`, `FBPA`, `WPR`, `FEAT`, `XVE`, `XVE_B`,
`XVE_C`, `FEAT2`, `OPT_PLM`) to `0xffffffff` on every boot — proven safe and reboot-persistent across
many prior sessions (it's how the existing memory/compute unlocks stay armed).

**Change made this session** (on new branch `JTAG`, off `master`): extended `plmTable[]` in that same
patch with two more entries, using the identical mechanism:
```c
{ 0x0000c840U, 0xffffffffU, "PJTAG_PLM" },
{ 0x0000c848U, 0xffffffffU, "PJTAG_SEC_PLM" },
```
and bumped the loop bound `plmIdx < 9` → `plmIdx < 11`. Exact hunk: `@@ -4821,6 +4849,122 @@` →
`@@ -4821,6 +4849,124 @@` (two added lines, old side unaffected — pure addition). No new mechanism,
no new patch file — this is a 4-line extension of an already-working, already-live primitive.

`sudo ./install.sh` rebuilt cleanly (`patch -p1` applied without conflict, modules built and loaded:
"Patched modules installed (profile 8gb)"). Rebooted with `sudo reboot` (not shutdown).

### Independent gate found, likely a hard wall (not this session's target)

`diag/mods/gpu/amperegpu.cpp`, `AmpereGpuSubdevice::UnlockHost2Jtag` implements a **separate** SHA2
challenge/response ("testmaster") unlock over dedicated JTAG chains defined in `dev_h2j_unlock.h`:
`JTAG_SEC_CFG` (instr ID 8, chain len 55), `JTAG_SEC_CHK` (ID 7, len 295), `JTAG_SEC_CMD` (ID 9, len
47), `JTAG_SEC_UNLOCK_STATUS` (ID 249, len 663). Sequence: write SEC_CFG with the feature bitmask to
unlock → write SEC_CHK with secure keys → write SEC_CMD=1 to start SHA2 calc → read SEC_CHK back
(lets the calc finish) → write SEC_CMD=0 → read SEC_UNLOCK_STATUS → verify requested bits landed.
Needed for deeper features like `en_ist_debug` (in-system-test / secure debug) and `en_jtag2host`.
Its own comment: *"For unfused parts the secCfg can be 0xFFFFFFFF, and the contents of secureKeys can
be all zeros. For fused parts secCfg must be appropriate for the secureKeys and are provided by the
Green Hill Server."* — NVIDIA's internal key-issuance system. This card is fused/production, so this
is architecturally the same trust boundary that already blocked HULK-cert-based approaches elsewhere
in this project. **Not the target of this session's fix** — base Host2Jtag register access (the
`0xC840`/`0xC848` PLMs) is the deliverable. Testing the "unfused" no-op path anyway is a cheap,
optional stretch (§ Next steps).

### Registers found but not yet live-checked (mmap window was too small this session)

`NV_PGC6_BSI_FGC6_JTAG_PRIV_LEVEL_MASK` (`0x118068`, GC6/BSI power-island JTAG chain gate) and
`NV_PTRIM_SYS_JTAGINTFC` (`0x1373A0`, JTAG interface clock enable) were found in the leak but this
session's read-only probe used a `0x20000`-byte mmap window and errored ("seek out of range") on
both. Not believed to be blockers — `NV_PBUS_ACCESS` bit 5 (general JTAG enable) already reads `1` —
but re-check with a full-size BAR0 mmap if the Host2Jtag transaction test (§ Next steps) fails.

### Reference implementation for the actual read/write protocol

`kernel/gpu/pascal/gpugp100.c:110-290`, `gpuJtagReadSeq_GP100`/`gpuJtagWriteSeq_GP100` — the exact
bit-banging sequence (poll `CTRL_STATUS` bit 30 after writing `ACCESS_CTRL`/`ACCESS_CONFIG`, then
read/write `ACCESS_DATA` per dword, `REQ_CTRL`=bit31 triggers the transaction). This is what
`tools/jtag/host2jtag.py` (this branch) ports, using the `Bar0` mmap read/write helper pattern already
established in the Documents repo's `tools/gen3/cap2_latch_test.py` / `bar0_dt.py` (BDF auto-detect,
`alive(bar)` liveness check, snapshot/restore before/after risky writes).

### Verification results — all confirmed, JTAG (Host2Jtag) transport is working

Post-reboot, `sudo dmesg | grep -E 'PLM\[|PJTAG'` showed both new entries opened on the first attempt:
```
PLM[9]  PJTAG_PLM(0xc840)     attempt=0 status=0xffff reg=0xffffffff
PLM[10] PJTAG_SEC_PLM(0xc848) attempt=0 status=0xffff reg=0xffffffff
```
No regressions: `nvidia-smi --query-gpu=name,memory.total,pcie.link.gen.current,pcie.link.gen.max`
→ `NVIDIA CMP 170HX, 65536 MiB, 2, 2` (memory/compute/Gen2 unlocks all intact).

Independent read-only BAR0 re-probe (outside the driver, same script as the pre-patch baseline)
confirmed the change directly: `0xC840 = 0xffffffff` and `0xC848 = 0xffffffff` (both were `0xffffff8f`
before). `0xC844` (ACCESS_SEC) is unchanged at `0x00000010` (MODE=ISM_ONLY) — not touched by this fix,
noted as a possible follow-up (see below).

`tools/jtag/host2jtag.py` was built (faithful port of `gpuJtagReadSeq_GP100`/`WriteSeq_GP100`,
`Bar0` mmap helper in the same style as the Documents repo's `tools/gen3` scripts, BDF auto-detect via
`lspci -d 10de: -D -mm`) and deployed to this branch. A real Host2Jtag read transaction
(chainLen=32, clusterSel=0, instrId=0) was run and instrumented step by step:
```
wrote ACCESS_CTRL=0x80002000, immediate readback=0xc0002000   (was 0x0 before the PLM fix — this
                                                                 is the exact condition RM's own code
                                                                 treats as "no write access")
CTRL_STATUS bit = 1   (settled after 1 poll — hardware handshake completes)
ACCESS_DATA = 0x00000000
```
**This is the concrete success criterion from the plan, all three parts confirmed**: (a) `ACCESS_CTRL`
readback non-zero after write, (b) `CTRL_STATUS` handshake reaches 1 without timing out, (c) a real
(if zero-valued — instrId 0 is not a documented chain, so a zero/reserved result is expected, not a
sign of failure) `ACCESS_DATA` read completes. **JTAG (Host2Jtag) register access is unlocked and the
transport protocol works.** Next work should pick real `clusterSel`/`instrId` values for specific
engines (SEC2/GSP/PMU chiplets, ISM speedometer chains) to read meaningful chip state — none were
identified/tried yet beyond this proof-of-transport read.

**Stretch test (§ SHA2 testmaster unlock) — measured, as predicted, blocked.** Ran the full
"unfused parts" `UnlockHost2Jtag` sequence via `host2jtag.py`'s write/read primitives: wrote
`SEC_CFG`(instrId 8, len 55)=`0xFFFFFFFF`, `SEC_CHK`(instrId 7, len 295)=`0`, `SEC_CMD`(instrId 9, len
47)=`1`, read `SEC_CHK` back (all-zero), wrote `SEC_CMD`=`0`, read `SEC_UNLOCK_STATUS`(instrId 249,
len 663) → **all 21 dwords zero, no feature bits unlocked.** This is a measured negative result, not
an assumption: on this fused/production part the "unfused parts" shortcut does not work, confirming
the earlier prediction that this gate needs NVIDIA-issued per-chip secure keys (the "Green Hill
Server" dependency) and is out of reach locally. Do not re-attempt this path without new key material.

### Open follow-ups for a future session

- Try meaningful `clusterSel`/`instrId` combinations against real engine JTAG chains (SEC2/GSP/PMU,
  ISM ring-oscillator speedometer per `GetIsmClkKhz`/MODS `ism/gpuism.cpp`) now that transport works.
- `0xC844` (ACCESS_SEC) still reads `MODE=ISM_ONLY` (`0x10`) — untested whether writing
  `SWITCH_TO_STANDARD` (bit 6) changes behavior/unlocks additional instruction IDs; PLM for this
  register (`0xC848`) is now open so the write itself should succeed — try it and record the result.
- `0x118068` (`PGC6_BSI_FGC6_JTAG_PRIV_LEVEL_MASK`) and `0x1373A0` (`PTRIM_SYS_JTAGINTFC`) were never
  live-probed this session (not needed — transport already works without them) — low priority.
- Confirm whether GA100 truly reuses the `_GP100` HAL routine for Jtag read/write (assumed, not
  confirmed from HAL dispatch tables) — irrelevant in practice since `host2jtag.py` talks to the
  registers directly and doesn't go through RM's HAL at all, but worth knowing if RM-side JTAG
  RmControl calls (`NV208F_CTRL_CMD_GPU_*_JTAG_CHAIN`) are ever wanted instead.

Read-only probe script used this session (safe, PROT_READ only, adjust offsets as needed):
```python
import mmap, os, struct
bdf = '0000:80:00.0'  # re-derive with lspci -d 10de: — do not trust this hardcoded value
path = f'/sys/bus/pci/devices/{bdf}/resource0'
fd = os.open(path, os.O_RDONLY | os.O_SYNC)
mm = mmap.mmap(fd, 0x20000, mmap.MAP_SHARED, mmap.PROT_READ)
def rd(off):
    mm.seek(off)
    return struct.unpack('<I', mm.read(4))[0]
```
