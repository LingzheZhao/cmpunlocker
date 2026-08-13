# BAR1 peer-to-peer research plan

## Status and scope

BAR1 peer-to-peer access is a separate research track from the framebuffer
memory-safety change. The first supported research matrix is deliberately
limited to:

- `10de:20c2` with the validated 64 GiB framebuffer geometry; and
- `10de:2082` with the validated 40 GiB framebuffer geometry.

The experimental `10de:2082` 80 GiB geometry is excluded. It has not proved
that its upper and lower logical address ranges refer to independent physical
HBM cells, and a 64 GiB BAR1 aperture cannot cover an 80 GiB framebuffer.

BAR1 is the host-visible Peripheral Component Interconnect Express memory
window into a GPU framebuffer. The Bayley proof of concept uses the target
GPU's BAR1 bus address as a system-memory aperture in the requesting GPU's
page-table entries. This bypasses the non-working proprietary mailbox peer
aperture. It is not NVLink and does not create a transparent pooled memory.

## Reference implementation and provenance

The primary executable reference is
[`bayley/cmpunlocker`](https://github.com/bayley/cmpunlocker), reviewed at
commit `5a7bb4b7e5056306fe49e8b824787659abb19914`.

Its README reports real four- and eight-GPU directed-pair results, including
an alias-resistant pattern. The repository does not currently contain the
peer-test source or a machine-readable result receipt, so those measurements
are valuable community evidence rather than a test that this repository can
yet reproduce independently.

The important pieces are:

| Reference | Purpose |
|---|---|
| `2a1a463` / `0011-p2p-bar1.patch` | Enable the BAR1 peer path and rewrite peer page-table entries to the remote BAR1 bus address. |
| `0013-skip-mailbox-peer-preinit.patch` | Keep mailbox peer identifiers from permanently excluding BAR1 peer mode. |
| `0015-bar1p2p-readcap-override.patch` | Work around NVIDIA's conservative or incorrect platform read-capability result. |
| `2dc12a4` / `kernel-patches/0002-*` | Select a 64 GiB BAR1 before normal PCI enumeration. |
| `2dc12a4` / `kernel-patches/0001-*` | Include child alignment padding when Linux sizes parent bridge windows. |

The Amogh BAR1 and peer branches remain useful as the provenance and
minimal-mechanism references. Bayley supersedes them as the integration and
real-transfer reference, but not as production-ready source.

## Why the reference patches are not copied directly

The current Bayley patch stack demonstrates working transfers, but it also:

- changes generated default hardware-dispatch entries rather than selecting
  the alternate handlers only for the two CMP device identifiers;
- enables Resizable BAR globally in one driver table;
- disables input/output virtual-address-space lifetime assertions and silently
  tolerates mappings whose owner has already disappeared; and
- forces the peer-read capability for a CMP device without qualifying each
  GPU pair's root-complex and socket topology.

Those are acceptable clues in a proof of concept, not acceptable invariants
for this repository. The final implementation must preserve the original
mapping lifetime checks and make every alternate path target- and pair-gated.

## Platform address-space requirement

Each endpoint BAR1 is 64 GiB, but a downstream bridge normally needs room for
both that BAR and the roughly 32 MiB BAR3. Because the child window begins on a
64 GiB boundary, its conservative parent-window footprint is:

```text
align_up(64 GiB + 32 MiB, 64 GiB) = 128 GiB per GPU
```

This gives a planning estimate of 256 GiB for two GPUs, 384 GiB for three,
512 GiB for four, 768 GiB for six, and 1 TiB for eight, before other devices
and firmware holes. A BIOS option named "MMIO High Base" is not proof of that
much usable space: the window size and the host-bridge resources exported to
Linux must also be large enough.

`pci=hpmmioprefsize=` can ask Linux to reserve a larger hot-plug window. It
cannot create an address aperture that firmware did not expose.

Run the read-only preflight after boot:

```bash
sudo python3 tools/check-p2p-platform.py
```

The tool checks that every target GPU has a non-zero, non-overlapping 64 GiB
BAR1 and prints the observed topology. A pass means only that PCI enumeration
is ready for later peer tests. It never reports that peer transfer is working.

## Implementation stages

1. Keep the existing native framebuffer, write-protected-region, and physical
   memory allocator guards unchanged.
2. Bring up 64 GiB BAR1 for every target GPU and fail closed if any BAR is
   missing, smaller, or overlapping.
3. Add target-gated BAR1 hardware-abstraction handlers without modifying the
   default handlers used by other NVIDIA GPUs.
4. Skip mailbox peer pre-registration only for a pair that has explicitly
   selected BAR1 peer mode.
5. Fix the input/output virtual-address-space mapping ownership and teardown
   order instead of suppressing its assertions.
6. Qualify read and write capability per directed GPU pair. Do not infer this
   only from the device identifier.
7. Keep `10de:2082` 80 GiB mode incompatible with this static 64 GiB BAR1 path.

## Required transfer acceptance

For `N` GPUs, test all `N * (N - 1)` directed pairs. A capability query or
`nvidia-smi topo -p2p` is not evidence because the experimental driver can
force those advertised values.

Each directed test must:

1. allocate independent source and destination buffers;
2. fill the destination with a poison pattern absent from the source;
3. fill the source with a value derived from byte offset, source GPU,
   destination GPU, test round, and random seed;
4. execute real peer reads and real peer writes;
5. evict the relevant GPU cache or use a working set much larger than it;
6. verify both buffers completely, so a mapping that aliases local memory
   cannot pass; and
7. repeat after peer disable/enable, context destruction, and abnormal process
   termination while checking for NVIDIA Xid, PCI Advanced Error Reporting,
   and input/output memory-management faults.

On a six-GPU dual-socket system, report the matrix explicitly:

- 12 directed pairs whose GPUs are attached to the same CPU socket;
- 18 directed pairs that cross CPU sockets; and
- 30 directed pairs in total.

A same-socket pass must not be described as a six-GPU full mesh. Cross-socket
failure also does not invalidate a useful pair of three-GPU same-socket
islands.
