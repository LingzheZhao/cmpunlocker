# cmp-easyunlock 80G analysis

## Conclusion

`cmp-easyunlock` is useful as evidence for the 80 GiB geometry, but its driver,
firmware replacement, and loader are not integrated. cmpunlocker keeps its
existing NVIDIA 610 in-memory SEC2 path and exposes 80G only through the
explicit `--experimental-80g` option.

The independently implemented 2082 geometry is:

| Target | CFG1 | LMR | Framebuffer bytes | Expected MiB |
|---|---:|---:|---:|---:|
| Default 40G | `0x02669000` | `0x0000028A` | `0x0000000A00000000` | 40960 |
| Experimental 80G | `0x02779000` | `0x0000028B` | `0x0000001400000000` | 81920 |

## What the third-party project does

The reviewed submodule is pinned at commit `bb2eaa6`. It targets NVIDIA open
driver 580.159.03. Its four firmware files are 30,526,552 bytes each and retain
the same `.fwimage`; the material difference is an appended `0xf800` GA100
signature payload. The 40G and 80G variants differ only in the CFG1/LMR
parameter bytes in that payload. The 80G blob SHA-256 observed during this
review is:

```text
837421153727b67b8a9a1d36767ad9664e0b4e3df48e56755cabf452ebb4c286
```

Its modified 580 driver runs a first SEC2 Booter stage with the appended
payload, resets and reallocates Booter state, then runs a second stage with the
stock `0x1000` signature. Its installer replaces the installed GSP firmware and
stock/DKMS modules. The upstream README labels 80G incomplete/unstable and not
recommended for production.

## Why the implementation is not copied

- The source changes are tied to the 580.159.03 Booter implementation and do
  not apply cleanly to the supported 610 trees.
- Replacing firmware and multiple stock module directories adds failure and
  rollback modes that the current in-memory payload does not need.
- The third-party flow does not provide cmpunlocker's fail-closed native FB
  layout and PMA proofs.
- The third-party repository does not provide a conventional top-level license
  grant for copying its added code or firmware payloads.
- Its README explicitly does not claim production stability for 80G.

No third-party source or firmware bytes are shipped or loaded by cmpunlocker.
The former unverified `dmem.bin` override in cmpunlocker's own patch has also
been removed; the reviewed built-in payload is now the only SEC2 payload path.

## Integration and safety gates

The selected 2082 target is applied together to all three independent consumers:

1. SEC2 CFG1/LMR write and expected FB size.
2. Post-Booter CFG1/LMR readback.
3. PMA target FB size and protected-memory boundary.

The generated module carries a target-specific fingerprint:

```text
cmpunlocker-safety-v5-2082-40g
cmpunlocker-safety-v5-2082-80g-experimental
```

The installer additionally requires one isolated stock-10G `10de:2082` card
with subsystem `10de:1557`, revision `a1`, VBIOS `92.00.66.00.02`, MIG
disabled, Default compute mode, nvidia-open 610.43.02, and the verified stock
GSP SHA-256
`c8fc1a92c90b034bbbe4d56ca94b0dc95afb52d3409a7880186ae03c7dde17f3`
with one stock-size `.fwsignature_ga100` section. The kernel repeats the PCI
device/subdevice gate before entering the SEC2 path.

## Validation status

Strict patch application and compiled FB/PMA tests pass for both 40G and 80G on
610.43.02, 610.43.03, and 610.57.04. This validates source consistency and
fail-closed boundary behavior; it is not an 80G hardware stability result.

Before 80G can lose its experimental label, it needs repeated cold-start tests,
real allocations and full readback above 40 GiB and near the top public
boundary, sustained compute/memory stress, and ECC/Xid monitoring. A failed
80G experiment must be recovered offline and followed by a complete loss of
standby power; hot module rollback and warm reboot are not supported.
