#!/usr/bin/env bash
# Build a minimal Debian rootfs for AArch64.
#
# Usage:
#   ./build_rootfs.sh [output-dir]  (default: debian-rootfs)
#
# Requirements:
#   - debootstrap
#   - qemu-user-static (for chroot operations)
#   - sudo (for debootstrap second stage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/../build/debian-rootfs}"
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://mirrors.aliyun.com/debian"
PREBUILD_DIR="${SCRIPT_DIR}/../prebuild"
ROOTFS_CACHE="${PREBUILD_DIR}/debian-${DEBIAN_SUITE}-arm64-rootfs.tar.gz"

info() { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
die()  { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }

# ── sanity checks ─────────────────────────────────────────────────────────────
for tool in debootstrap sudo; do
    command -v "${tool}" >/dev/null || die "Missing tool: ${tool}"
done

# Check qemu-aarch64-static for cross-building
QEMU_AARCH64="$(command -v qemu-aarch64-static 2>/dev/null || true)"
if [[ -z "${QEMU_AARCH64}" ]]; then
    die "qemu-aarch64-static not found — install qemu-user-static"
fi

# ── cache check ────────────────────────────────────────────────────────────────
mkdir -p "${PREBUILD_DIR}"

if [[ -f "${ROOTFS_CACHE}" ]]; then
    info "Using cached rootfs: ${ROOTFS_CACHE}"
    if [[ -d "${OUTPUT_DIR}" ]]; then
        info "Removing existing rootfs: ${OUTPUT_DIR}"
        sudo rm -rf "${OUTPUT_DIR}"
    fi
    mkdir -p "${OUTPUT_DIR}"
    sudo tar -xzf "${ROOTFS_CACHE}" -C "${OUTPUT_DIR}"
    ok "Rootfs extracted from cache: ${OUTPUT_DIR} ($(du -sh "${OUTPUT_DIR}" | cut -f1))"
    echo ""
    echo "  Contents:"
    echo "    /etc/debian_version: $(cat "${OUTPUT_DIR}/etc/debian_version" 2>/dev/null || echo 'N/A')"
    echo "    Root password: (empty)"
    echo "    Network: DHCP on eth0"
    echo "    Console: ttyAMA0 @ 115200"
    exit 0
fi

# ── clean and create output ───────────────────────────────────────────────────
if [[ -d "${OUTPUT_DIR}" ]]; then
    info "Removing existing rootfs: ${OUTPUT_DIR}"
    sudo rm -rf "${OUTPUT_DIR}"
fi

mkdir -p "${OUTPUT_DIR}"

# ── debootstrap first stage ───────────────────────────────────────────────────
info "Running debootstrap first stage (${DEBIAN_SUITE}, arm64)..."

debootstrap --arch=arm64 \
    --foreign \
    --include=openssh-server,vim,net-tools,iproute2,isc-dhcp-client,sudo \
	--no-check-gpg \
    "${DEBIAN_SUITE}" \
    "${OUTPUT_DIR}" \
    "${DEBIAN_MIRROR}"

# ── install qemu-aarch64-static for second stage ──────────────────────────────
info "Installing qemu-aarch64-static into rootfs..."
sudo cp "${QEMU_AARCH64}" "${OUTPUT_DIR}/usr/bin/"

# ── debootstrap second stage ──────────────────────────────────────────────────
info "Running debootstrap second stage (chroot)..."
sudo chroot "${OUTPUT_DIR}" /debootstrap/debootstrap --second-stage

# ── configure the rootfs ──────────────────────────────────────────────────────
info "Configuring Debian rootfs..."

# Set root password to empty (auto-login for development)
sudo chroot "${OUTPUT_DIR}" bash -c 'passwd -d root'

# Configure hostname
echo "debian-qemu" | sudo tee "${OUTPUT_DIR}/etc/hostname" > /dev/null

# Configure apt sources to use Aliyun mirror
sudo tee "${OUTPUT_DIR}/etc/apt/sources.list" > /dev/null <<EOF
deb http://mirrors.aliyun.com/debian bookworm main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian bookworm-updates main contrib non-free non-free-firmware
EOF

# Configure /etc/fstab for MMC rootfs
sudo tee "${OUTPUT_DIR}/etc/fstab" > /dev/null <<'EOF'
/dev/mmcblk0p2  /       ext4    defaults        0 1
/dev/mmcblk0p1  /boot   vfat    defaults        0 2
proc            /proc   proc    defaults        0 0
sysfs           /sys    sysfs   defaults        0 0
devtmpfs        /dev    devtmpfs defaults       0 0
EOF

# Configure network interfaces (DHCP)
sudo tee "${OUTPUT_DIR}/etc/network/interfaces" > /dev/null <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# Configure console for serial login
# Debian bookworm uses systemd; enable serial console getty
sudo chroot "${OUTPUT_DIR}" systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || \
    sudo ln -sf /lib/systemd/system/serial-getty@.service \
        "${OUTPUT_DIR}/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

# Clean up
info "Cleaning up..."
sudo rm -f "${OUTPUT_DIR}/usr/bin/qemu-aarch64-static"

# ── cache rootfs ──────────────────────────────────────────────────────────────
info "Caching rootfs to ${ROOTFS_CACHE}..."
sudo tar -czf "${ROOTFS_CACHE}" -C "${OUTPUT_DIR}" .
ok "Rootfs cached: ${ROOTFS_CACHE}"

ok "Debian rootfs built: ${OUTPUT_DIR} ($(du -sh "${OUTPUT_DIR}" | cut -f1))"
echo ""
echo "  Contents:"
echo "    /etc/debian_version: $(cat "${OUTPUT_DIR}/etc/debian_version")"
echo "    Root password: root"
echo "    Network: DHCP on eth0"
echo "    Console: ttyAMA0 @ 115200"
