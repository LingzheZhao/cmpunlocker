#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${CMP_BOOTER_CACHE:-${PROJECT_DIR}/driver/.build}"
JOBS="${CMP_BOOTER_JOBS:-4}"
KVER="$(uname -r)"
KSRC="/lib/modules/${KVER}/build"
VERSION=615.78.08
LEGACY_VERSION=610.57.04

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || { echo 'CMP_BOOTER_JOBS must be positive' >&2; exit 1; }
[[ -d "${KSRC}" ]] || { echo "Missing kernel headers: ${KSRC}" >&2; exit 1; }
for command in curl sha256sum tar python3 patch make gcc modinfo; do
    command -v "${command}" >/dev/null || { echo "Missing ${command}" >&2; exit 1; }
done
mkdir -p "${CACHE}" "${PROJECT_DIR}/driver/.build"
BUILD="$(mktemp -d "${PROJECT_DIR}/driver/.build/booter-experiment.XXXXXX")"
printf 'Build directory: %s\n' "${BUILD}"
exec > >(tee "${BUILD}/build.log") 2>&1

fetch() {
    local version="$1" expected="$2" archive="${CACHE}/open-gpu-kernel-modules-$1.tar.gz"
    if [[ ! -f "${archive}" ]]; then
        curl --proto '=https' --proto-redir '=https' -fL \
            "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${version}.tar.gz" \
            -o "${archive}.partial"
        mv "${archive}.partial" "${archive}"
    fi
    printf '%s  %s\n' "${expected}" "${archive}" | sha256sum -c -
}
fetch "${VERSION}" eac0ecd52facab28ad2963cf7e03ae8d2289d596ad590c703b5f72d65899e2bf
fetch "${LEGACY_VERSION}" 619d7b5ce1f79c3211afdbf87d02b2174d268b10d005c5b8f994be22299be681
tar --no-same-owner --no-same-permissions -xzf "${CACHE}/open-gpu-kernel-modules-${VERSION}.tar.gz" -C "${BUILD}"
SOURCE="${BUILD}/open-gpu-kernel-modules-${VERSION}"
LEGACY_MEMBER="open-gpu-kernel-modules-${LEGACY_VERSION}/src/nvidia/generated/g_bindata_kgspGetBinArchiveBooterLoadUcode_GA100.c"
tar -xOf "${CACHE}/open-gpu-kernel-modules-${LEGACY_VERSION}.tar.gz" "${LEGACY_MEMBER}" > "${BUILD}/legacy-ga100-booter.c"

mapfile -t PATCHES < <(python3 - "${PROJECT_DIR}/driver/build.sh" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"PATCH_ORDER=\(\n(.*?)\n\)", text, re.S)
if match is None:
    raise SystemExit("PATCH_ORDER missing")
print("\n".join(match.group(1).split()))
PY
)
[[ ${#PATCHES[@]} -gt 0 ]] || { echo 'No patches found' >&2; exit 1; }
for name in "${PATCHES[@]}"; do
    patch --batch --forward -p1 -d "${SOURCE}" -i "${PROJECT_DIR}/driver/patches/${name}"
done
python3 "${PROJECT_DIR}/tools/prepare-cmp-booter.py" "${SOURCE}" "${BUILD}/legacy-ga100-booter.c"

make -C "${SOURCE}" -j"${JOBS}" modules SYSSRC="${KSRC}" CC=gcc
mkdir "${BUILD}/modules"
for module in nvidia nvidia-modeset nvidia-uvm nvidia-drm nvidia-peermem; do
    ko="${SOURCE}/kernel-open/${module}.ko"
    [[ "$(modinfo -F version "${ko}")" == "${VERSION}" ]] || { echo "Wrong version: ${ko}" >&2; exit 1; }
    [[ "$(modinfo -F vermagic "${ko}")" == "${KVER} "* ]] || { echo "Wrong kernel: ${ko}" >&2; exit 1; }
    cp "${ko}" "${BUILD}/modules/"
done
printf '%s\n' "${VERSION}" > "${BUILD}/modules/driver_version"
printf '%s\n' "${KVER}" > "${BUILD}/modules/kernel_version"
printf '%s\n' "${LEGACY_VERSION}" > "${BUILD}/modules/cmp_privilege_booter"
(
    cd "${BUILD}/modules"
    sha256sum ./*.ko driver_version kernel_version cmp_privilege_booter > SHA256SUMS
)
printf 'Experimental modules built and checked: %s/modules\n' "${BUILD}"
printf 'No modules installed or loaded.\n'
