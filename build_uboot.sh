#!/usr/bin/env bash
# Build U-Boot for QEMU AArch64 with UDP fastboot support.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UBOOT_DIR="${SCRIPT_DIR}/../u-boot"

CROSS_COMPILE="${CROSS_COMPILE_ELF:-aarch64-none-elf-}"

# Validate toolchain is accessible via PATH
command -v "${CROSS_COMPILE}gcc" >/dev/null || {
    echo -e "\033[1;31m[!]\033[0m Toolchain not found: ${CROSS_COMPILE}gcc" >&2
    echo "  Set CROSS_COMPILE_ELF to your aarch64-none-elf- toolchain prefix," >&2
    echo "  or add it to PATH. Example:" >&2
    echo "    export CROSS_COMPILE_ELF=/path/to/toolchain/bin/aarch64-none-elf-" >&2
    exit 1
}
DEFCONFIG=qemu_arm64_defconfig
BUILD_DIR="${SCRIPT_DIR}/../build/uboot"
JOBS=$(nproc)
mkdir -p "$BUILD_DIR"

# Extra Kconfig options layered on top of the defconfig.
# UDP fastboot lets the host reach U-Boot via: fastboot -s udp:<QEMU-IP> ...
EXTRA_CONFIGS=(
    "CONFIG_UDP_FUNCTION_FASTBOOT=y"
    "CONFIG_UDP_FUNCTION_FASTBOOT_PORT=5554"
    "CONFIG_FASTBOOT_BUF_ADDR=0x48000000"
    "CONFIG_FASTBOOT_BUF_SIZE=0x10000000"
    # MMC via sdhci-pci (matches QEMU's sdhci-pci device)
    "CONFIG_MMC=y"
    "CONFIG_MMC_SDHCI=y"
    "CONFIG_MMC_PCI=y"
    "CONFIG_CMD_MMC=y"
    # bootdev support for MMC (required for bootflow scan)
    "CONFIG_BOOTDEV_MMC=y"
    # Auto-boot: scan bootdevs and boot first valid bootflow
    "CONFIG_BOOTCOMMAND=\"bootflow scan -lbG\""
    "CONFIG_USE_BOOTCOMMAND=y"
    # fastboot flash to MMC
    "CONFIG_FASTBOOT_FLASH=y"
    "CONFIG_FASTBOOT_FLASH_MMC=y"
    "CONFIG_FASTBOOT_FLASH_MMC_DEV=0"
    "CONFIG_FASTBOOT_MMC_BOOT_SUPPORT=y"
    "CONFIG_FASTBOOT_MMC_USER_SUPPORT=y"
    "CONFIG_FASTBOOT_GPT_NAME=\"gpt\""
    "CONFIG_FASTBOOT_MBR_NAME=\"mbr\""
    # GPT command (gpt write/read)
    "CONFIG_CMD_GPT=y"
)

make -C "$UBOOT_DIR" CROSS_COMPILE="$CROSS_COMPILE" ARCH=arm O="$BUILD_DIR" "$DEFCONFIG"

for cfg in "${EXTRA_CONFIGS[@]}"; do
    key="${cfg%%=*}"
    sed -i "/^${key}[= ]/d;/^# ${key} /d" "$BUILD_DIR"/.config
    echo "$cfg" >> "$BUILD_DIR"/.config
done

make -C "$UBOOT_DIR" CROSS_COMPILE="$CROSS_COMPILE" ARCH=arm O="$BUILD_DIR" olddefconfig
make -C "$UBOOT_DIR" CROSS_COMPILE="$CROSS_COMPILE" ARCH=arm O="$BUILD_DIR" -j"$JOBS" all

echo ""
echo "Done: $BUILD_DIR/u-boot.bin"
