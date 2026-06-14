#!/usr/bin/env bash
# Run QEMU AArch64 with U-Boot, MMC (mmc.img), and UDP fastboot support.
#
# Usage:
#   ./run_qemu.sh [user|tap]
#
# Networking modes:
#   user (default) - SLIRP, no root needed
#                    fastboot: fastboot -s udp:127.0.0.1 <cmd>
#   tap            - requires a pre-configured tap0 bridge on the host
#                    fastboot: fastboot -s udp:<QEMU_IP> <cmd>
#
# U-Boot auto-boot:
#   On startup U-Boot runs bootflow scan which picks up boot.scr from the
#   FAT32 boot partition (mmc 0:1). The script loads /image.fit and calls
#   bootm to start the kernel.
#
# To exit QEMU: Ctrl-A  X

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UBOOT_BIN="${SCRIPT_DIR}/../build/uboot/u-boot.bin"
MMC_IMG="${SCRIPT_DIR}/../build/mmc.img"
ENVSTORE="${SCRIPT_DIR}/../build/envstore.img"

MODE="${1:-user}"

die()  { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m[*]\033[0m $*"; }

[[ -f "${UBOOT_BIN}" ]] || die "U-Boot not found: ${UBOOT_BIN} — run ./scripts/build.sh uboot first"
[[ -f "${MMC_IMG}" ]]   || die "MMC image not found: ${MMC_IMG} — run ./scripts/make_mmc.sh first"

# Persistent U-Boot environment flash (pflash index 1)
mkdir -p "$(dirname "${ENVSTORE}")"
if [[ ! -f "${ENVSTORE}" ]]; then
    info "Creating ${ENVSTORE} (64 MiB pflash for U-Boot env)..."
    qemu-img create -f raw "${ENVSTORE}" 64M
fi

# Network
if [[ "${MODE}" == "tap" ]]; then
    NET_ARGS=(
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no
        -device e1000,netdev=net0
    )
    info "Network: tap (tap0) — fastboot -s udp:<QEMU_IP>"
else
    # UDP 5554 forwarded for fastboot; UDP 69 forwarded for TFTP if needed
    NET_ARGS=(
        -netdev "user,id=net0,hostfwd=udp::5554-:5554"
        -device e1000,netdev=net0
    )
    info "Network: user (SLIRP) — fastboot -s udp:127.0.0.1"
    info "  U-Boot IP: 10.0.2.15   serverip: 10.0.2.2"
fi

info "U-Boot:   ${UBOOT_BIN}"
info "MMC:      ${MMC_IMG}"
info "Envstore: ${ENVSTORE}"
echo ""
echo "  [Press Ctrl-A X to quit QEMU]"
echo ""

exec qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a57 \
    -m 2G \
    -smp 2 \
    -nographic \
    -bios "${UBOOT_BIN}" \
    -drive if=pflash,format=raw,index=1,file="${ENVSTORE}" \
    -device sdhci-pci \
    -drive if=none,id=mmc0,format=raw,file="${MMC_IMG}" \
    -device sd-card,drive=mmc0 \
    "${NET_ARGS[@]}"
