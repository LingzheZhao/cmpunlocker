# Contributing

Thanks for your interest in contributing to cmpunlocker! This guide covers development, building, testing, and submitting changes.

---

## Development Setup

### Prerequisites

- Linux x86-64 (Ubuntu, Debian, Fedora, or compatible distro)
- Root access (sudo)
- git
- NVIDIA CMP 170HX card with nvidia-open 610.43.0x already installed
- Kernel headers: `linux-headers-$(uname -r)` (Ubuntu/Debian) or `kernel-devel` (Fedora/RHEL)
- Python 3
- curl
- build-essential or equivalent (`gcc`, `make`)

### Clone and Explore

```bash
git clone https://github.com/your-fork/cmpunlocker.git
cd cmpunlocker
```

Key directories:
- `driver/patches/` — Patch files applied to nvidia-open sources
- `driver/build.sh` — Build script that downloads, patches, and compiles modules
- `install.sh` / `remove.sh` — Top-level installer/uninstaller
- `docs/` — Documentation

---

## Build Process

The build flow (from `driver/build.sh`):

1. **Download** — Fetch matching `open-gpu-kernel-modules` sources from NVIDIA GitHub
2. **Patch** — Apply all `.patch` files from `driver/patches/` in order (numbered 0001, 0002, ...)
3. **Profile** — Inject card memory profile (8GB→64GB or 10GB→40GB) into `kernel_gsp.c` via Python regex
4. **Compile** — Build patched modules with `make -j$(nproc)`
5. **Install** — Copy `.ko` files to `/lib/modules/$(uname -r)/updates/cmpunlocker/`
6. **Reload** — Run `depmod -a` and attempt hot-reload; fall back to cold reboot if needed

### Building Manually

```bash
# Compile patched modules for the current kernel
sudo ./driver/build.sh

# Or override the card profile explicitly
sudo CMPUNLOCKER_CARD_PROFILE=8gb ./driver/build.sh

# Custom build directory
sudo CMPUNLOCKER_BUILD_DIR=/tmp/cmp-build ./driver/build.sh
```

Environment variables:
- `CMPUNLOCKER_CARD_PROFILE` — `8gb` or `10gb` (default: auto-detect from nvidia-smi)
- `CMPUNLOCKER_BUILD_DIR` — Working directory for sources and artifacts (default: `driver/.build`)
- `CMPUNLOCKER_DRIVER_VERSION` — Override driver version from `driver/VERSION` (rarely needed)

---

## Testing

### Verify an Install

After building and installing, verify the unlock succeeded:

```bash
# Check memory
nvidia-smi

# Check compute unlock
nvidia-smi --query-gpu=clocks.max.sm --format=csv

# Check unlock sequence ran
sudo dmesg | grep SEC2_DEBUG
# Expected: PLMs opening, CFG1/LMR/SS0/SS1 writes, late PMA

# Check stored profile
cat /lib/modules/$(uname -r)/updates/cmpunlocker/card_profile
```

For 8GB cards: expect ~65536 MiB; for 10GB: ~40960 MiB.

### Testing New Patches

When modifying `driver/patches/`:

1. Edit the patch file
2. Rebuild: `sudo ./driver/build.sh`
3. Verify the unlock worked (see above)
4. If hot-reload didn't work, cold reboot and re-verify

The build script automatically detects if the patch applies cleanly. Failed patches will error before compilation starts.

---

## Adding Support for New Cards

To unlock a different CMP SKU or GA100 variant:

1. **Identify card constants** (you'll need datasheets or reverse-engineering):
   - Physical memory size (e.g., 24GB)
   - Target unlocked geometry (e.g., 80GB)
   - CFG1 register value
   - LMR register value
   - FB (frame buffer) capacity in hex

2. **Update `driver/build.sh`** — Add a new case in the profile selector:
   ```bash
   24gb)
       PROFILE="24gb"
       CFG1="0xXXXXXXXX"         # Your value
       LMR="0xXXXXXXXX"          # Your value
       FB_BYTES="0xXXXXXXXXXXXX"  # Your value
       UNLOCK_LABEL="80GB"
       ;;
   ```

3. **Verify register values** — These must be exact. Incorrect values can cause hangs or memory corruption. Test thoroughly on isolated hardware.

4. **Update patches if needed** — If `kernel_gsp.c` changes in new nvidia-open versions, the regex patterns in `0001-sec2-postbl-plm-ss-cfg.patch` may need adjustment.

5. **Document** — Update README.md and this guide with the new card profile.

---

## Patch Anatomy

Each patch in `driver/patches/` targets a specific unlock component:

| Patch | Component | Purpose |
|---|---|---|
| `0001-sec2-postbl-plm-ss-cfg.patch` | SEC2 Booter, PLM, SS0/SS1, CFG1/LMR | Core unlock sequence |
| `0002-booter-verify.patch` | Booter status verification | Debug output for PLM health checks |
| `0003-late-pma.patch` | Frame buffer & PMA | Memory capacity and SM cluster initialization |
| `0004-bar0-pramin-clamp.patch` | BAR0/PRAMIN access | Bounds checking adjustments |
| `0005-ce-scrub-workarounds.patch` | Copy engine | Memory initialization workarounds |
| `0006-persistent-sw-state.patch` | Software state tracking | Persistence across module reload |

To modify the unlock logic, edit the relevant patch file and rebuild.

---

## Supported Driver Versions

Edit `driver/VERSION` to add or remove supported nvidia-open versions:

```
610.43.43
610.43.50
```

Only versions listed here will be accepted by the build script. This ensures compatibility testing before bumping.

---

## Submitting Changes

1. **Fork the repo** on GitHub

2. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/my-improvement
   ```

3. **Make changes** and test thoroughly on real hardware

4. **Commit with clear messages**:
   ```bash
   git commit -m "Add 24GB CMP card support

   - Add CFG1/LMR/FB values for 24GB→80GB unlock
   - Tested on physical 24GB card
   - Memory and compute unlock verified"
   ```

5. **Push and open a PR**:
   ```bash
   git push origin feature/my-improvement
   ```

6. **Describe your changes** in the PR body:
   - What hardware was tested
   - What dmesg output confirms the fix
   - Links to relevant documentation or discussions

---

## Code Style & Conventions

- **Patch files**: Use unified diff format (`git diff` or `patch -u`). Include context lines.
- **Bash scripts**: Strict mode (`set -euo pipefail`), quote variables, error checking.
- **Comments in patches**: Use standard patch comments (`---` and `+++` headers); C comments go in the patched code.
- **Testing**: Always test on physical hardware before submitting. Describe your test environment (distro, kernel version, card variant).

---

## Getting Help

- **Questions?** Ask in the [Discord community](https://discord.gg/CdHSakKSFv)
- **Found a bug?** Open an issue on GitHub with:
  - Your OS and kernel version (`uname -a`)
  - Your nvidia-open version (`nvidia-smi --query-gpu=driver_version --format=csv,noheader`)
  - Relevant dmesg output
  - Steps to reproduce

---

## Architecture & Design

For an in-depth explanation of how the unlock works, see [ARCHITECTURE.md](ARCHITECTURE.md).

For troubleshooting failed installs, see [DEBUGGING.md](DEBUGGING.md).

