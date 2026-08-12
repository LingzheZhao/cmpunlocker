#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="${PROJECT_DIR}/driver/patches"
MATRIX_ROOT="$(mktemp -d /tmp/cmpunlocker-source-matrix.XXXXXX)"
trap 'rm -rf -- "${MATRIX_ROOT}"' EXIT INT TERM

declare -A ARCHIVE_SHA256=(
    ["610.57.04"]="619d7b5ce1f79c3211afdbf87d02b2174d268b10d005c5b8f994be22299be681"
    ["610.43.03"]="9df87d753cd9c05aa0eedc462af9b35debb549a657136e863282f94c96ee2640"
    ["610.43.02"]="62fbbe29527e30be32cb38b30dfad2e94db1ca87f77a58090e563c7669857e60"
)
PATCH_ORDER=(
    sec2-postbl-plm-ss-cfg.patch
    booter-verify.patch
    late-pma.patch
    bar0-pramin-clamp.patch
    ce-scrub-workarounds.patch
    persistent-sw-state.patch
    pcie-gen2.patch
    pcie-gen2-probe-retrain.patch
    name-string.patch
    sec2-payload-safety.patch
)

python3 "${PROJECT_DIR}/tools/test-memory-geometry-consistency.py"

while IFS= read -r version; do
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    archive="${MATRIX_ROOT}/${version}.tar.gz"
    curl --proto '=https' --proto-redir '=https' -L --fail \
        -o "${archive}" \
        "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${version}.tar.gz"
    printf '%s  %s\n' "${ARCHIVE_SHA256[${version}]}" "${archive}" | sha256sum -c -
    tar --no-same-owner --no-same-permissions -xzf "${archive}" -C "${MATRIX_ROOT}"
    source_root="${MATRIX_ROOT}/open-gpu-kernel-modules-${version}"

    for patch_name in "${PATCH_ORDER[@]}"; do
        patch --fuzz=0 --batch --forward -s -d "${source_root}" -p1 \
            < "${PATCH_DIR}/${patch_name}"
    done

    for target in 40gb 80gb; do
        python3 "${PROJECT_DIR}/tools/configure-memory-geometry.py" \
            "${source_root}" --ten-gb-target "${target}"
        HOSTCC=gcc python3 "${PROJECT_DIR}/tools/test-fb-region-validator.py" \
            "${source_root}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
        HOSTCC=gcc python3 "${PROJECT_DIR}/tools/test-pma-guard.py" \
            "${source_root}/src/nvidia/src/kernel/gpu/mem_mgr/mem_mgr.c"
    done
    rm -rf -- "${source_root}" "${archive}"
done < "${PROJECT_DIR}/driver/VERSION"

echo "source matrix: PASS"
