#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_NAME="gen2.service"
SERVICE_SOURCE="${PROJECT_DIR}/systemd/${SERVICE_NAME}"
SERVICE_TARGET="/etc/systemd/system/${SERVICE_NAME}"
HAMMER_SOURCE="${SCRIPT_DIR}/hammer.sh"
HAMMER_TARGET="/usr/local/sbin/gen2-hammer"
LOG_FILE="/var/log/gen2.log"

source "${PROJECT_DIR}/common/lib.sh"

usage() {
    cat <<EOF
Usage:
  sudo $0 install   Install and enable the early-boot Gen2 service
  sudo $0 remove    Disable and remove the service (driver remains installed)
  sudo $0 verify    Verify negotiated link speed and show the boot log
  $0 status         Show whether the service is installed and enabled

install never starts the retrain loop in the current session; it only arms
the service for the next boot.
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this action as root"
}

supported_gpus() {
    local id output
    for id in 20c2 2082; do
        output="$(lspci -D -d "10de:${id}" 2>/dev/null)" || return 1
        [[ -z "${output}" ]] || awk '{print $1}' <<< "${output}"
    done
}

link_generation() {
    local status="$1" generation
    if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
        generation=$((0x${status} & 0x0f))
        if (( generation >= 1 && generation <= 7 )); then
            echo "${generation}"
            return 0
        fi
    fi
    echo "?"
}

install_service() {
    local module="/lib/modules/$(uname -r)/updates/cmpunlocker/nvidia.ko"
    local gpu_output
    local -a gpus=()

    require_root
    command -v install >/dev/null || die "install command not found"
    command -v lspci >/dev/null || die "lspci not found (install pciutils)"
    command -v setpci >/dev/null || die "setpci not found (install pciutils)"
    [[ -f "${HAMMER_SOURCE}" ]] || die "Missing ${HAMMER_SOURCE}"
    [[ -f "${SERVICE_SOURCE}" ]] || die "Missing ${SERVICE_SOURCE}"

    gpu_output="$(supported_gpus)" || die "lspci failed while enumerating supported GPUs"
    mapfile -t gpus < <(printf '%s' "${gpu_output}")
    [[ ${#gpus[@]} -gt 0 ]] || die "No supported CMP 170HX found (10de:20c2 / 10de:2082)"
    info "Detected: ${gpus[*]}"

    if [[ ! -f "${module}" ]]; then
        die "Patched cmpunlocker module not found: ${module}"
    fi
    if ! grep -aFq 'CMP Gen2:' "${module}" 2>/dev/null; then
        die "Installed module does not contain the Gen2 probe-retrain patch; refusing to arm a useless retrain service"
    fi
    ok "Installed NVIDIA module contains the Gen2 probe-retrain patch"

    install -m 0755 "${HAMMER_SOURCE}" "${HAMMER_TARGET}"
    install -m 0644 "${SERVICE_SOURCE}" "${SERVICE_TARGET}"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null
    ok "Enabled ${SERVICE_NAME} for the next boot"
    info "The service was not started now; the active desktop PCIe link was not touched."
    info "Recovery boot option: systemd.mask=${SERVICE_NAME}"
}

remove_service() {
    require_root
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_TARGET}" "${HAMMER_TARGET}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    ok "Removed ${SERVICE_NAME}; cmpunlocker driver and memory unlock were left intact"
    if [[ -f "${LOG_FILE}" ]]; then
        info "Preserved diagnostic log: ${LOG_FILE}"
    fi
}

show_status() {
    if [[ -f "${SERVICE_TARGET}" ]]; then
        ok "Service file installed: ${SERVICE_TARGET}"
    else
        warn "Service file is not installed"
    fi
    systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true
    systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
}

verify_links() {
    local gpu bridge status generation speed width max_speed result smi_summary gpu_output
    local failures=0
    local indeterminate=0
    local -a gpus=()

    require_root
    if ! command -v lspci >/dev/null || ! command -v setpci >/dev/null; then
        err "lspci/setpci are unavailable; PCIe generation cannot be measured"
        printf '%s\n' "PCIe verification result: INDETERMINATE"
        return 2
    fi
    if ! gpu_output="$(supported_gpus)"; then
        err "lspci failed while enumerating supported GPUs"
        printf '%s\n' "PCIe verification result: INDETERMINATE"
        return 2
    fi
    mapfile -t gpus < <(printf '%s' "${gpu_output}")
    if [[ ${#gpus[@]} -eq 0 ]]; then
        err "No supported CMP 170HX could be enumerated"
        printf '%s\n' "PCIe verification result: INDETERMINATE"
        return 2
    fi

    printf '%-16s %-16s %-8s %-14s %-8s %s\n'         "GPU" "Upstream" "LnkSta" "Current speed" "Width" "Result"
    for gpu in "${gpus[@]}"; do
        bridge="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${gpu}")")")"
        if status="$(setpci -s "${gpu}" CAP_EXP+12.w 2>/dev/null)"; then
            generation="$(link_generation "${status}")"
        else
            status="unreadable"
            generation="?"
        fi
        speed="$(cat "/sys/bus/pci/devices/${gpu}/current_link_speed" 2>/dev/null || echo unknown)"
        width="$(cat "/sys/bus/pci/devices/${gpu}/current_link_width" 2>/dev/null || echo unknown)"
        max_speed="$(cat "/sys/bus/pci/devices/${gpu}/max_link_speed" 2>/dev/null || echo unknown)"
        if [[ "${generation}" =~ ^[0-9]+$ ]] && (( generation >= 2 )); then
            result="GEN2 OK"
        elif [[ "${generation}" =~ ^[0-9]+$ ]]; then
            result="GEN1"
            failures=$((failures + 1))
        else
            result="UNKNOWN"
            indeterminate=$((indeterminate + 1))
        fi
        printf '%-16s %-16s %-8s %-14s x%-7s %s\n'             "${gpu}" "${bridge}" "0x${status}" "${speed}" "${width}" "${result}"
        info "${gpu}: sysfs max=${max_speed}; negotiated generation is authoritative"
    done

    if command -v nvidia-smi >/dev/null && command -v timeout >/dev/null; then
        echo
        if smi_summary="$(timeout 10s nvidia-smi \
            --query-gpu=pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.gen.max \
            --format=csv 2>/dev/null)" && [[ -n "${smi_summary}" ]]; then
            printf '%s\n' "${smi_summary}"
        else
            warn "nvidia-smi summary is unavailable or timed out; skipping informational display"
        fi
    elif command -v nvidia-smi >/dev/null; then
        warn "timeout command is unavailable; skipping optional nvidia-smi display"
    fi

    echo
    if [[ -f "${LOG_FILE}" ]]; then
        info "Last early-retrain log:"
        tail -n 30 "${LOG_FILE}"
    else
        warn "No ${LOG_FILE}; the early service has not run yet"
    fi

    if (( failures > 0 )); then
        err "${failures} GPU(s) are still negotiated at Gen1"
        printf '%s\n' "PCIe verification result: GEN1"
        return 1
    fi
    if (( indeterminate > 0 )); then
        err "PCIe generation is unreadable for ${indeterminate} GPU(s)"
        printf '%s\n' "PCIe verification result: INDETERMINATE"
        return 2
    fi
    ok "All supported GPUs are negotiated at Gen2 or better"
    printf '%s\n' "PCIe verification result: OK"
}

case "${1:-}" in
    install) install_service ;;
    remove) remove_service ;;
    verify) verify_links ;;
    status) show_status ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 1 ;;
esac
