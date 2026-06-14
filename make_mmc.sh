#!/usr/bin/env bash
# Build mmc.img:
#   - GPT disk image (4 GiB)
#   - boot partition: offset 2 MiB, size 64 MiB, FAT32, label "boot"
#   - rootfs partition: offset 66 MiB, size 2048 MiB, ext4, label "rootfs"
#   - FIT Image (kernel + DTB + initrd) placed at /boot/image.fit
#   - Debian rootfs placed in rootfs partition
#
# Requires: mkimage (u-boot-tools), parted, mtools (mcopy, mformat), sudo
#
# Usage:
#   ./make_mmc.sh [output-image] [rootfs-dir]  (default: mmc.img, debian-rootfs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

KERNEL_IMG="${SCRIPT_DIR}/../build/kernel/arch/arm64/boot/Image"
INITRD_IMG="${SCRIPT_DIR}/../build/kernel/initrd.cpio.gz"
DTB_SRC="${SCRIPT_DIR}/../build/uboot/arch/arm/dts/qemu-arm64.dtb"
OUT_IMG="${1:-${SCRIPT_DIR}/../build/mmc.img}"
ROOTFS_DIR="${2:-${SCRIPT_DIR}/../build/debian-rootfs}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

info() { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
die()  { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }

# ── sanity checks ─────────────────────────────────────────────────────────────
[[ -f "${KERNEL_IMG}" ]] || die "Kernel not found: ${KERNEL_IMG} — run ./scripts/build.sh kernel first"
[[ -f "${DTB_SRC}" ]]    || die "DTB not found: ${DTB_SRC}"

for tool in mkimage parted mformat mcopy; do
    command -v "${tool}" >/dev/null || die "Missing tool: ${tool}"
done

# ── build FIT Image ───────────────────────────────────────────────────────────
info "Building FIT Image..."

ITS="${TMPDIR}/kernel.its"
FIT="${TMPDIR}/image.fit"
KERNEL_COPY="${TMPDIR}/Image"
DTB_COPY="${TMPDIR}/qemu-arm64.dtb"

cp "${KERNEL_IMG}" "${KERNEL_COPY}"
cp "${DTB_SRC}"    "${DTB_COPY}"

if [[ -f "${INITRD_IMG}" ]]; then
    INITRD_COPY="${TMPDIR}/initrd.cpio.gz"
    cp "${INITRD_IMG}" "${INITRD_COPY}"
    RAMDISK_NODE='
        ramdisk {
            description = "initramfs";
            data = /incbin/("initrd.cpio.gz");
            type = "ramdisk";
            arch = "arm64";
            os = "linux";
            compression = "none";
            hash { algo = "crc32"; };
        };'
    CONF_RAMDISK='ramdisk = "ramdisk";'
else
    RAMDISK_NODE=""
    CONF_RAMDISK=""
    info "No initrd found — FIT image will have kernel+dtb only"
fi

cat > "${ITS}" <<EOF
/dts-v1/;
/ {
    description = "Linux kernel FIT image for QEMU AArch64";
    #address-cells = <1>;

    images {
        kernel {
            description = "Linux kernel";
            data = /incbin/("Image");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "none";
            load = <0x40400000>;
            entry = <0x40400000>;
            hash { algo = "crc32"; };
        };
        fdt-1 {
            description = "QEMU AArch64 device tree";
            data = /incbin/("qemu-arm64.dtb");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            hash { algo = "crc32"; };
        };${RAMDISK_NODE}
    };

    configurations {
        default = "conf-1";
        conf-1 {
            description = "kernel + dtb";
            kernel = "kernel";
            fdt = "fdt-1";
            ${CONF_RAMDISK}
        };
    };
};
EOF

(cd "${TMPDIR}" && mkimage -f "${ITS}" "${FIT}")
ok "FIT Image: ${FIT} ($(du -sh "${FIT}" | cut -f1))"

# ── create disk image ─────────────────────────────────────────────────────────
info "Creating ${OUT_IMG} (4 GiB GPT)..."
DISK_SIZE=$((4 * 1024))   # MiB

# boot partition: start 2 MiB, size 64 MiB
BOOT_START=2
BOOT_END=$((BOOT_START + 64 - 1))   # inclusive, MiB

# rootfs partition: start 66 MiB, size 2048 MiB
ROOTFS_START=$((BOOT_END + 1))
ROOTFS_END=$((ROOTFS_START + 2048 - 1))

mkdir -p "$(dirname "${OUT_IMG}")"
rm -f "${OUT_IMG}"
dd if=/dev/zero of="${OUT_IMG}" bs=1M count="${DISK_SIZE}" status=progress

parted -s "${OUT_IMG}" \
    mklabel gpt \
    mkpart boot fat32 "${BOOT_START}MiB" "$((BOOT_END + 1))MiB" \
    mkpart rootfs ext4 "${ROOTFS_START}MiB" "$((ROOTFS_END + 1))MiB" \
    set 1 boot on

ok "Partition table written"

# ── format boot partition and copy FIT image ──────────────────────────────────
info "Formatting boot partition (FAT32) and copying FIT image..."

# Offset in bytes and size for the partition
PART_OFFSET=$(( BOOT_START * 1024 * 1024 ))   # 2 MiB in bytes
PART_SIZE=$(( 64 * 1024 * 1024 ))              # 64 MiB in bytes

# mformat/mcopy work directly on the partition offset inside the image
# using the ::path syntax with -i <image>@@<offset>
MTOOLS_IMG="${OUT_IMG}@@${PART_OFFSET}"

mformat -i "${OUT_IMG}@@${PART_OFFSET}" \
    -F -v "boot" \
    -T $(( PART_SIZE / 512 )) \
    ::

mcopy -i "${OUT_IMG}@@${PART_OFFSET}" "${FIT}" ::/image.fit

ok "Copied image.fit to boot partition"

# ── write boot script for U-Boot ──────────────────────────────────────────────
info "Creating U-Boot boot script..."

BOOTCMD_TXT="${TMPDIR}/boot.cmd"
BOOTSCR="${TMPDIR}/boot.scr"

cat > "${BOOTCMD_TXT}" <<'EOF'
setenv bootargs "console=ttyAMA0 earlycon=pl011,0x9000000 root=/dev/mmcblk0p2 rootwait rootfstype=ext4 rw loglevel=8 panic=5"
load mmc 0:1 0x48000000 /image.fit
bootm 0x48000000:kernel 0x48000000:ramdisk ${fdt_addr}
EOF

mkimage -A arm64 -O linux -T script -C none -n "boot" -d "${BOOTCMD_TXT}" "${BOOTSCR}"
mcopy -i "${OUT_IMG}@@${PART_OFFSET}" "${BOOTSCR}" ::/boot.scr

ok "Boot script written to boot partition"

# ── format rootfs partition and copy Debian rootfs ────────────────────────────
ROOTFS_OFFSET=$(( ROOTFS_START * 1024 * 1024 ))
ROOTFS_SIZE=$(( 2048 * 1024 * 1024 ))

if [[ -d "${ROOTFS_DIR}" ]] && [[ -f "${ROOTFS_DIR}/etc/debian_version" ]]; then
    info "Formatting rootfs partition (ext4) and copying Debian rootfs..."

    # Create a temporary ext4 image for the rootfs
    ROOTFS_TMP_IMG="${TMPDIR}/rootfs.ext4"
    dd if=/dev/zero of="${ROOTFS_TMP_IMG}" bs=1M count=2048 status=progress
    mkfs.ext4 -L rootfs "${ROOTFS_TMP_IMG}"

    # Mount and copy using sudo
    MNT_DIR="${TMPDIR}/mnt"
    mkdir -p "${MNT_DIR}"

    # Use loop device to mount and copy
    LOOP_DEV=$(sudo losetup --find --show "${ROOTFS_TMP_IMG}")
    sudo mount "${LOOP_DEV}" "${MNT_DIR}"
    sudo cp -a "${ROOTFS_DIR}/." "${MNT_DIR}/"
    sudo umount "${MNT_DIR}"
    sudo losetup -d "${LOOP_DEV}"

    # Write the rootfs image into the partition offset
    dd if="${ROOTFS_TMP_IMG}" of="${OUT_IMG}" bs=1M seek="${ROOTFS_START}" conv=notrunc status=progress

    ok "Debian rootfs written to rootfs partition"
else
    info "No Debian rootfs found at ${ROOTFS_DIR} — skipping rootfs partition"
    info "  Run ./scripts/build_rootfs.sh first to create one"
fi

info "Done: ${OUT_IMG}"
echo ""
echo "  Boot partition:  offset=${BOOT_START} MiB, size=64 MiB, FAT32"
echo "  Rootfs partition: offset=${ROOTFS_START} MiB, size=2048 MiB, ext4"
echo "  Contents: /image.fit (FIT), /boot.scr (U-Boot script)"
if [[ -d "${ROOTFS_DIR}" ]] && [[ -f "${ROOTFS_DIR}/etc/debian_version" ]]; then
    echo "  Rootfs: Debian $(cat "${ROOTFS_DIR}/etc/debian_version")"
fi
echo "  Run with: ./scripts/run_qemu.sh"
