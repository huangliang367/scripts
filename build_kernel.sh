#!/bin/bash
# Build Linux kernel for AArch64 and optionally run on QEMU.
#
# Usage:
#   ./build_kernel.sh [defconfig|build|initrd|run|all]
#
# Commands:
#   defconfig  - generate .config via defconfig
#   build      - compile the kernel (uses -j nproc)
#   initrd     - build a minimal busybox initramfs
#   run        - launch QEMU with the built kernel
#   all        - defconfig + build + initrd + run  (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=arm64
CROSS_COMPILE="${CROSS_COMPILE_GNU:-aarch64-linux-gnu-}"

# Validate toolchain is accessible via PATH
command -v "${CROSS_COMPILE}gcc" >/dev/null || {
    echo -e "\033[1;31m[!]\033[0m Toolchain not found: ${CROSS_COMPILE}gcc" >&2
    echo "  Set CROSS_COMPILE_GNU to your aarch64-linux-gnu- toolchain prefix," >&2
    echo "  or add it to PATH. Example:" >&2
    echo "    export CROSS_COMPILE_GNU=/path/to/toolchain/bin/aarch64-linux-gnu-" >&2
    exit 1
}
JOBS=$(nproc)

KERNEL_DIR="${SCRIPT_DIR}/../linux"
BUILD_DIR="${SCRIPT_DIR}/../build/kernel"
INITRD_DIR="${BUILD_DIR}/initrd"
INITRD_IMG="${BUILD_DIR}/initrd.cpio.gz"

KERNEL_IMAGE="${BUILD_DIR}/arch/arm64/boot/Image"

# ── helpers ────────────────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[+]\033[0m $*"; }
die()   { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }

kmake() {
    make -C "${KERNEL_DIR}" \
         O="${BUILD_DIR}" \
         ARCH="${ARCH}" \
         CROSS_COMPILE="${CROSS_COMPILE}" \
         -j"${JOBS}" \
         "$@"
}

# ── steps ──────────────────────────────────────────────────────────────────────

do_defconfig() {
    info "Generating defconfig for arm64 → ${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    kmake defconfig

    # Enable ext4 filesystem and MMC block device for Debian rootfs
    cat >> "${BUILD_DIR}/.config" <<'EOF'
CONFIG_EXT4_FS=y
CONFIG_BLK_DEV_SD=y
CONFIG_MMC=y
CONFIG_MMC_BLOCK=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PCI=y
EOF

    ok "Config written to ${BUILD_DIR}/.config"
}

do_build() {
    [[ -f "${BUILD_DIR}/.config" ]] || die ".config not found — run 'defconfig' first"
    info "Building kernel (ARCH=${ARCH}, CROSS_COMPILE=${CROSS_COMPILE}, -j${JOBS})"
    kmake Image
    ok "Kernel image: ${KERNEL_IMAGE}"
}

do_initrd() {
    info "Building minimal initramfs (aarch64)"

    rm -rf "${INITRD_DIR}"
    mkdir -p "${INITRD_DIR}"/{bin,sbin,etc,proc,sys,dev,tmp}

    # ── locate aarch64 busybox ─────────────────────────────────────────
    # Priority: 1) cached in build dir  2) Docker-provided  3) download  4) C fallback
    BUSYBOX=""
    for candidate in \
            "${BUILD_DIR}/busybox" \
            "/usr/aarch64-linux-gnu/bin/busybox" ; do
        if [[ -f "${candidate}" ]]; then
            ARCH_TAG=$(file "${candidate}" | grep -o "ARM aarch64" || true)
            if [[ "${ARCH_TAG}" == "ARM aarch64" ]]; then
                BUSYBOX="${candidate}"
                break
            fi
        fi
    done

    if [[ -z "${BUSYBOX}" ]]; then
        info "No local aarch64 busybox — trying download..."
        # busybox.net provides multiarch static binaries
        for url in \
            "https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv8l" ; do
            if wget -q --timeout=30 --tries=2 -O "${BUILD_DIR}/busybox" "$url" 2>/dev/null; then
                ARCH_TAG=$(file "${BUILD_DIR}/busybox" | grep -o "ARM aarch64" || true)
                if [[ "${ARCH_TAG}" == "ARM aarch64" ]]; then
                    BUSYBOX="${BUILD_DIR}/busybox"
                    chmod +x "${BUSYBOX}"
                    ok "Downloaded aarch64 busybox from $(basename "$(dirname "$url")")"
                    break
                fi
                rm -f "${BUILD_DIR}/busybox"
            fi
        done
    fi

    # ── create init ────────────────────────────────────────────────────
    if [[ -n "${BUSYBOX}" ]]; then
        info "Using aarch64 busybox: ${BUSYBOX}"
        cp "${BUSYBOX}" "${INITRD_DIR}/bin/busybox"
        chmod +x "${INITRD_DIR}/bin/busybox"
        for cmd in sh ls cat echo mount mkdir switch_root; do
            ln -sf busybox "${INITRD_DIR}/bin/${cmd}" 2>/dev/null || true
        done
        cat > "${INITRD_DIR}/init" <<'INITEOF'
#!/bin/sh
mount -t proc  none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || true

echo ""
echo "  *** AArch64 initramfs: waiting for MMC rootfs ***"
echo ""

for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -b /dev/mmcblk0p2 ]; then
        echo "  Found /dev/mmcblk0p2"
        break
    fi
    echo "  Waiting for /dev/mmcblk0p2... (${i}/10)"
    sleep 1
done

if [ ! -b /dev/mmcblk0p2 ]; then
    echo "  ERROR: /dev/mmcblk0p2 not found, dropping to shell"
    exec sh
fi

mkdir -p /newroot
mount -t ext4 /dev/mmcblk0p2 /newroot

if [ -x /newroot/lib/systemd/systemd ]; then
    REAL_INIT=/lib/systemd/systemd
elif [ -x /newroot/sbin/init ]; then
    REAL_INIT=/sbin/init
else
    echo "  ERROR: no init found in /newroot, dropping to shell"
    exec sh
fi

echo "  Switching to Debian rootfs..."
umount /proc
umount /sys
umount /dev 2>/dev/null || true

exec switch_root /newroot ${REAL_INIT}
INITEOF
    else
        # Last resort: compile a minimal C init that mounts rootfs and execs real init
        info "No aarch64 busybox available — compiling minimal C init"
        cat > /tmp/init_aarch64.c <<'CSRC'
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>

int main(void) {
    mount("proc",     "/proc", "proc",    0, NULL);
    mount("sysfs",    "/sys",  "sysfs",   0, NULL);
    mount("devtmpfs", "/dev",  "devtmpfs",0, NULL);

    printf("\n  *** AArch64 initramfs: waiting for MMC rootfs ***\n\n");

    struct stat st;
    int found = 0;
    for (int i = 1; i <= 10; i++) {
        if (stat("/dev/mmcblk0p2", &st) == 0) {
            printf("  Found /dev/mmcblk0p2\n");
            found = 1;
            break;
        }
        printf("  Waiting for /dev/mmcblk0p2... (%d/10)\n", i);
        sleep(1);
    }
    if (!found) {
        printf("  ERROR: /dev/mmcblk0p2 not found\n");
        for(;;) pause();
    }

    mkdir("/newroot", 0755);
    if (mount("/dev/mmcblk0p2", "/newroot", "ext4", 0, NULL) != 0) {
        perror("  mount rootfs failed");
        for(;;) pause();
    }

    // chroot into new root and exec real init
    chdir("/newroot");
    if (mount("/newroot", "/", NULL, MS_MOVE, NULL) != 0) {
        perror("  mount move failed");
        for(;;) pause();
    }
    chroot(".");
    chdir("/");

    char *argv[] = {"/sbin/init", NULL};
    char *envp[] = {"HOME=/", "TERM=linux", NULL};
    execve("/sbin/init", argv, envp);
    execve("/lib/systemd/systemd", argv, envp);

    printf("  ERROR: no init found\n");
    for(;;) pause();
}
CSRC
        ${CROSS_COMPILE}gcc -static -o "${INITRD_DIR}/init" /tmp/init_aarch64.c
        rm /tmp/init_aarch64.c
        ARCH_TAG=$(file "${INITRD_DIR}/init" | grep -o "ARM aarch64" || true)
        [[ "${ARCH_TAG}" == "ARM aarch64" ]] \
            || die "Compiled init is not aarch64 — check your cross-compiler"
    fi

    chmod +x "${INITRD_DIR}/init"

    info "Packing initramfs → ${INITRD_IMG}"
    (cd "${INITRD_DIR}" && find . | cpio -H newc -o | gzip -9 > "${INITRD_IMG}")
    ok "Initramfs: ${INITRD_IMG} ($(du -sh "${INITRD_IMG}" | cut -f1))"
}

do_run() {
    [[ -f "${KERNEL_IMAGE}" ]] || die "Kernel not found at ${KERNEL_IMAGE} — build first"

    QEMU_ARGS=(
        -M virt
        -cpu cortex-a57
        -m 512M
        -smp 2
        -nographic
        -kernel "${KERNEL_IMAGE}"
        -append "console=ttyAMA0 earlycon=pl011,0x9000000 loglevel=8 panic=5"
        -no-reboot
    )

    if [[ -f "${INITRD_IMG}" ]]; then
        QEMU_ARGS+=(-initrd "${INITRD_IMG}")
    else
        info "No initramfs found — kernel will boot without rootfs (expect kernel panic at mount)"
    fi

    info "Launching qemu-system-aarch64"
    info "  machine: virt | cpu: cortex-a57 | ram: 512M"
    info "  kernel:  ${KERNEL_IMAGE}"
    [[ -f "${INITRD_IMG}" ]] && info "  initrd:  ${INITRD_IMG}"
    echo ""
    echo "  [Press Ctrl-A X to quit QEMU]"
    echo ""

    exec qemu-system-aarch64 "${QEMU_ARGS[@]}"
}

# ── main ───────────────────────────────────────────────────────────────────────

CMD="${1:-all}"

case "${CMD}" in
    defconfig) do_defconfig ;;
    build)     do_build ;;
    initrd)    do_initrd ;;
    run)       do_run ;;
    all)
        do_defconfig
        do_build
        do_initrd
        do_run
        ;;
    *)
        echo "Usage: $0 [defconfig|build|initrd|run|all]"
        exit 1
        ;;
esac
