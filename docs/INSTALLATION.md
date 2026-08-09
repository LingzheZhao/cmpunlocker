# Installation

Here are the steps to install cmpunlocker on your system.

---

## Requirements

- NVIDIA CMP 170HX (8GB or 10GB)
- Linux operating system (Ubuntu, Debian, Fedora, etc.)
- Kernel headers matching the running kernel (linux-headers-$(uname -r) / kernel-devel)
- Python 3
- A matching nvidia-open 610.57.04, 610.43.03, or 610.43.02 installation (kernel module, userspace libraries, and GSP firmware)
- Root access to the system (sudo privileges)
- Secure Boot disabled
- Network access on first install (downloads matching stock open-gpu-kernel-modules sources)

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

The installer does not modify a bootloader source or generated boot artifact.
It checks for the CPU-appropriate IOMMU enable parameter plus `iommu=pt` and
reports manual action when they are absent:

- Intel: add `intel_iommu=on iommu=pt`.
- AMD: add `amd_iommu=on iommu=pt`.
- With GRUB, update the distribution-managed kernel command line and regenerate
  the GRUB configuration using that distribution's documented tool.
- With systemd-boot, `kernel-install`, or another boot manager, update its
  authoritative command-line source and regenerate or reinstall the affected
  boot entry using distribution tooling.

Enable IOMMU in BIOS/UEFI as well. Complete these steps before the final cold
power cycle, then confirm the parameters in `/proc/cmdline` and a populated
`/sys/class/iommu` after power-on.

The early-boot PCIe Gen2 retrain service is also enabled by default. To leave
the service itself unchanged, use `--no-gen2-service`; the Gen2 NVIDIA module
option is still installed and included in the final initramfs:

```bash
sudo ./install.sh --no-gen2-service
```

Most users should not pass `--profile`. Each GPU's geometry is always selected
at runtime by PCI device ID: `10de:20c2` uses the 64 GB geometry and
`10de:2082` uses the 40 GB geometry. The optional flag overrides only the
installed metadata label; it cannot change that geometry selection:

```bash
sudo ./install.sh --profile=8gb
sudo ./install.sh --profile=10gb
```

The installer serializes the complete install/remove lifecycle with a
root-owned lock. Before mutation it verifies matching userspace, firmware, and
one coherent five-module set. Module publication is journaled outside the
kernel module scan tree and uses an atomic directory handoff; rerunning the
installer first resolves any supported module-directory publication phase.

If an exact current-kernel NVIDIA DKMS tuple must be displaced, its identity is
durably receipted before the patched directory is built and the cleanup is
converged forward only after that directory commits. The receipt is retained
for removal; unrelated DKMS records are not included. This DKMS format-1
receipt is supported only when the tuple has neither an
`(Original modules exist)` status nor a physical
`original_module/$KVER/$ARCH` payload before the first receipt. Either
condition makes installation fail before mutation. Normalize or remove that
DKMS conflict outside cmpunlocker; removal will not consume or restore it.

Fresh installation treats IOMMU boot sources and outputs as read-only. A
complete historical format-1 receipt may be validated, and an exact single
legacy GRUB backup may be recognized only when the current source is the
deterministic result of adding the CPU-specific parameters to that backup.
Ambiguous sidecars, post-install edits, pending automatic transactions, or a
`kernel-install` backend require manual reconciliation; cmpunlocker does not
guess the original boot target or rewrite it.

On systems using `mkinitcpio`, cmpunlocker rebuilds one explicitly selected
`default_image` for the exact running kernel. A nonempty `default_kver` takes
priority over `ALL_kver`; a nonempty `default_config` takes priority over
`ALL_config`. The scripts reject ambiguous presets and active UKI/EFI,
options, cmdline, splash, or kerneldest settings. `update-initramfs` and
`dracut` are likewise invoked for the exact running kernel. These tools write
live distribution boot artifacts directly, so initramfs publication is not
fully crash-atomic across distributions even though module-directory
publication is journaled and atomic.

After a successful install, shut down completely with `sudo shutdown -h now`
and power the machine on only after shutdown has finished. The install commits
an on-disk module state and leaves the currently running NVIDIA driver
untouched. A full power-off/power-on is mandatory to activate that state. Do
not hot-reload the NVIDIA modules or use a warm reboot as the activation step.

If installation exits nonzero and instructs you not to power-cycle, do not
shut down or reboot. Correct the reported external conflict first. Rerun the
same command only when the message identifies a supported recovery path;
preserved ambiguous or external state requires manual reconciliation.

After power-on, require the verifier to return exit status 0 before running
workloads:

```bash
sudo ./verify.sh
```

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./remove.sh --yes
```

Removal first proves the complete multi-kernel stock transition and makes any
required external DKMS build payload durable while CMP modules and firmware
remain unchanged. It then publishes one global forward-only barrier. From that
point, retries never republish CMP modules; they advance the entire set toward
verified stock modules, firmware, `depmod`, and initramfs state.

Two interruption classes deliberately stop without automatic cleanup:

- A `.cmpunlocker.remove.*` rollback-directory orphan without the global
  forward marker is inventoried with every related removal state, then all CMP,
  firmware, DKMS, `depmod`, and initramfs mutation stops. Reconcile the whole
  listed set; do not rename or delete one kernel independently.
- If an external DKMS build was interrupted while its durable hashes were
  still pending, automatic reset is permitted only when the version-global
  `build`, `.tmp_*`, canonical tuple B, and active-link residue are all proven
  absent. If any residue exists, removal performs no deletion or rebuild and
  requires manual DKMS reconciliation.

Historical IOMMU format-1 state can be restored only from its exact receipt and
base/expected (B/E) snapshots through a fixed, trusted GRUB target.
`kernel-install` output is not bounded by that receipt and must be restored
manually. Legacy sidecars are migrated only when one exact hashed backup and
deterministic derivation prove ownership; ambiguous or edited state is
preserved.

The legacy `/opt/cmpunlocker` directory is removed only when it is the
canonical path, its parent and directory are root-owned and safe, it is on the
same device as its parent, no mount point exists at or below it, and it is
empty. A nonempty directory is preserved and removal stops for manual
reconciliation; the script never recursively deletes unreceipted contents.

Initramfs generators publish directly to live distribution boot artifacts, so
a hard cut during that phase is not guaranteed to be crash-atomic. If removal
fails, do not power-cycle. Follow its exact recovery or manual-reconciliation
message and rerun only after the reported state is safe.

After a successful removal has restored a stock-ready on-disk state, the
running GPU still does not transition safely through a module reload or warm
reboot. Shut down completely with `sudo shutdown -h now`, wait for power-off,
and then power the machine on.
