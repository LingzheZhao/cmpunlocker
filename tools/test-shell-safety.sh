#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_DIR}/common/lib.sh"

TEST_DIR="$(mktemp -d /tmp/cmpunlocker-shell-safety.XXXXXX)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT INT TERM

expect_marker_status() {
    local path="$1" expected="$2" actual=0
    module_contains_cmp_marker "${path}" || actual=$?
    [[ "${actual}" -eq "${expected}" ]] || \
        die "marker inspection for ${path} returned ${actual}, expected ${expected}"
}

printf '%s\n' 'clean stock module fixture' > "${TEST_DIR}/clean.ko"
printf '%s\n' 'cmpunlocker-safety-v5-2082-40g' > "${TEST_DIR}/marked.ko"
printf '%s\n' 'not a compressed stream' > "${TEST_DIR}/corrupt.ko.gz"

expect_marker_status "${TEST_DIR}/clean.ko" 1
expect_marker_status "${TEST_DIR}/marked.ko" 0
expect_marker_status "${TEST_DIR}/corrupt.ko.gz" 2

gzip -c "${TEST_DIR}/clean.ko" > "${TEST_DIR}/clean.ko.gz"
gzip -c "${TEST_DIR}/marked.ko" > "${TEST_DIR}/marked.ko.gz"
expect_marker_status "${TEST_DIR}/clean.ko.gz" 1
expect_marker_status "${TEST_DIR}/marked.ko.gz" 0

echo "shell safety helpers: PASS"
