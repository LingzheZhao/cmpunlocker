# Debugging

Start with the safety verifier:

```bash
sudo ./verify.sh
```

Only exit status 0 is an acceptance result. Do not run GPU workloads after an
exit status of 1 or 2.

Run the acceptance check only after a successful install and the required full
power-off/power-on. If it is run before that transition, it examines the driver
and evidence from the current boot. A failure from the known unsafe old boot is
not a runtime verdict on patched modules that are merely staged on disk.

Do not treat `nvidia-smi` showing 65536 MiB or 40960 MiB as proof that memory
is healthy. The verifier also checks the protected GSP/WPR boundary, PMA
registration, current-boot GPU faults, scrub timeouts, OOM fallout, and PCIe
generation.

## Xid 31, CE region violation, or scrub timeout

The following combination is a hard failure, not ordinary CUDA OOM:

```text
Xid 31 ... ENGINE CE... REGION_VIOLATION ... PHYS_WRITE
_scrubWaitAndSave: Timed out when waiting for scrub jobs to finish
pmaAllocatePages ... NV_ERR_NO_MEMORY
ctxBufPoolReserve ... NV_ERR_NO_MEMORY
```

Any Xid 31 or CE `REGION_VIOLATION` is a hard failure; the physical-write form
above is the signature seen on the affected host. The root cause in the old
path was late PMA registration exposing the native top 142 MiB GSP protected
carve-out as public memory. CE2 then issued a physical write into that range;
the Xid 31/region violation was the primary fault, while scrub timeout and
PMA/context OOM were downstream effects. Stop GPU workloads and preserve the
current-boot journal:

```bash
journalctl -k -b 0 -o short-monotonic --no-pager > kernel-current-boot.log
python3 ./tools/analyze-kernel-log.py kernel-current-boot.log
```

For each GPU identity that the strict analyzer is told to require or can infer
from the supplied log, a clean result requires one ordered, current-boot proof
chain:

```text
WPR meta updated
  -> SEC2_DEBUG_FB_LAYOUT: validated ... status=safe build=cmpunlocker-safety-v3
  -> SEC2_DEBUG_PMA_GUARD: ... status=safe build=cmpunlocker-safety-v3
```

The three records must agree on the expected device `fbSize` and protected
boundary. The native FB-layout record must account for the entire framebuffer
as `publicBytes + reservedRegionBytes == fbSize`. Its `capacityFloor` must be
exactly `fbSize - 2 GiB`, and native public capacity must meet that floor. This
2 GiB slack is a product capacity acceptance policy; it is not proof of the
protected-memory boundary. Boundary safety is established separately by the
matching `protectedStart`/`rsvdStart` fields and the validated region layout.

The final guard's `publicBytes` is the heap-clipped capacity actually exposed
to PMA. It must equal `pmaBytes`, meet the same capacity floor, and may be less
than—but never greater than—the native layout's `publicBytes`.

For `10de:2082`, the proof must describe the exact 40 GiB geometry
(`fbSize=0xa00000000`) and a native table that satisfies the same coverage and
protected-boundary rules. Missing or invalid native 40 GiB evidence fails
closed; no synthetic table is accepted.

Exit 1 means definite hazard or rejected-layout evidence; exit 2 means the log
or ordered v3 chain is incomplete or inconsistent, so no healthy verdict was
issued. Pass the analyzer one chronological source from one current boot. Do
not concatenate journal, dmesg, or different boots; `verify.sh` checks readable
sources independently. Use `--best-effort` only for exploratory summaries,
never for post-install acceptance.

An analyzer exit status of 0 means only that the hazards covered by that log
analysis were not found. It does not validate the complete live GPU inventory,
module identity, capacity, or PCIe state. Only exit status 0 from
`sudo ./verify.sh` is full runtime acceptance.

If the analyzer reports `PMA/protected`, `PMA/WPR`, or `PMA/heap` overlap, do
not attempt a GPU reset or module reload. Install the fixed modules, then use:

```bash
sudo shutdown -h now
```

Power the system on only after it has fully shut down.

`Booter failed with non-zero error code: 0x31` during an explicitly logged
SEC2 PLM attempt is a different firmware status and can be followed by a
successful normal BooterLoad. An `NVRM: Xid ... 31` line is never covered by
that exception.

## Memory still reports 8192 or 10240 MiB

- Confirm the installed and running kernel-module versions match the GSP
  firmware and userspace driver.
- Inspect `SEC2_DEBUG: POST-WRITE` and `WPR meta updated` records in the current
  boot journal.
- Confirm the ordered WPR → native FB-layout → final PMA-guard chain is present,
  and both safety records report `status=safe build=cmpunlocker-safety-v3`.
- Perform a full shutdown and power-on after installation; neither module
  reload nor warm reboot is an accepted activation path.

## PCIe is still at Gen1

- Run `sudo ./tools/service.sh verify`.
- Confirm IOMMU passthrough is active as described in the installation guide.
  Fresh installs do not edit the bootloader; configure it with the
  distribution's boot tooling and complete the required power cycle.
- Treat PCIe retraining as a separate problem from memory safety. Do not run a
  high-address memory test until `sudo ./verify.sh` passes first.

## Requesting support

When opening a support ticket, include:

- Operating system, kernel, GPU PCI ID/BDF, and exact NVIDIA release.
- The output of `sudo ./verify.sh`.
- The current-boot kernel log analyzed above.
- The latest install log, after reviewing it for private paths or host data.

The project community is available through the Discord link in the README.
