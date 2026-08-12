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

The compatibility `--profile` option may be used only when it agrees with the
detected hardware:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

The researched 80G target is opt-in and experimental:

```bash
sudo ./install.sh --experimental-80g
```

It currently requires one isolated stock-state `10de:2082` (no other
unlockable GPU), subsystem `10de:1557`, revision `a1`, VBIOS
`92.00.66.00.02`, MIG disabled, Default compute mode, nvidia-open 610.43.02,
and the pinned stock GSP firmware SHA-256 with a stock `0x1000` GA100
signature. Do not use it for production until it has completed real hardware
testing above 40 GiB.

After installation, fully shut down the machine and remove standby power long
enough for the GPU to lose state. A warm reboot or module reload is not a valid
transition. After power-on, run:

```bash
sudo ./verify.sh
```

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./remove.sh --yes
```

Then perform the same complete power-off/power-on transition before the stock
driver is allowed to initialize the card.
