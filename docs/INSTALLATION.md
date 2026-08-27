# Installation

Here are the steps to install cmpunlocker on your system.

---

## Requirements

- NVIDIA CMP 170HX (8GB or 10GB)
- Linux operating system (Ubuntu, Debian, Fedora, etc.)
- Kernel headers matching the running kernel (linux-headers-$(uname -r) / kernel-devel)
- Python 3
- **nvidia-open 610.43.0x already installed** (libs + firmware)
- Root access to the system (sudo privileges)
- Secure Boot disabled
- Network access on first install (downloads matching stock open-gpu-kernel-modules sources)

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

To force a certain memory profile, use the `--profile` option:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

GPU-to-GPU BAR1 P2P is on by default. Pass `--no-p2p` to leave it off. When
enabled, the installer also adds `pci=realloc pci=hpmmioprefsize=2T`. 64GB
BAR1 on every GPU is required; the optional host-kernel patches in
`kernel-patches/` are what make that BAR come up from a normal boot. After
reboot, `nvidia-smi topo -p2p r` reporting OK is not proof — verify with a
real peer copy.

Then perform a cold reboot (full power off, then boot).

`install.sh` does not patch the host kernel. For 64GB BAR1, build a `-cmp`
kernel from `kernel-patches/` (6.8: `linux-6.8/`), boot it, then run
`install.sh` again. See `kernel-patches/README.md`.

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./uninstall.sh --yes
```

Then perform a cold reboot (full power off, then boot).
