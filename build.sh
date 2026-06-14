#!/usr/bin/env bash
# Build U-Boot, Linux kernel, or both.
#
# Usage:
#   ./build.sh [uboot|kernel|all]
#
# Commands:
#   uboot   - build U-Boot only
#   kernel  - build Linux kernel (defconfig + Image + initrd)
#   all     - build both (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"

info() { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
die()  { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }

mkdir -p "${BUILD_DIR}"

do_uboot() {
    info "Building U-Boot..."
    bash "${SCRIPT_DIR}/build_uboot.sh"
    ok "U-Boot done: ${BUILD_DIR}/uboot/u-boot.bin"
}

do_kernel() {
    info "Building Linux kernel..."
    bash "${SCRIPT_DIR}/build_kernel.sh" defconfig
    bash "${SCRIPT_DIR}/build_kernel.sh" build
    bash "${SCRIPT_DIR}/build_kernel.sh" initrd
    ok "Kernel done: ${BUILD_DIR}/kernel/arch/arm64/boot/Image"
}

CMD="${1:-all}"
case "${CMD}" in
    uboot)  do_uboot ;;
    kernel) do_kernel ;;
    all)
        do_uboot
        do_kernel
        ;;
    *)
        echo "Usage: $0 [uboot|kernel|all]"
        exit 1
        ;;
esac
