#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

UBOOT_VER="v2026.10"
UBOOT_DIR="src/u-boot"
KERNEL_VER="6.18.65"
KERNEL_DIR="src/linux-${KERNEL_VER}"
KERNEL_URL="https://mirrors.aliyun.com/linux-kernel/v6.x/linux-${KERNEL_VER}.tar.xz"
KERNEL_URL_FALLBACK="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VER}.tar.xz"
KERNEL_SHA_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc"
UBOOT_URL="https://codeload.github.com/u-boot/u-boot/tar.gz/refs/tags/${UBOOT_VER}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://mirrors.aliyun.com/ubuntu-ports}"
CROSS_COMPILE="aarch64-linux-gnu-"
JOBS="${JOBS:-$(nproc)}"
IMAGE="ubuntu-arm64.img"
IMAGE_SIZE="8G"
ROOTFS="rootfs"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法:
  ./build.sh              完整构建: 下载/编译 U-Boot、Linux，然后 sudo 生成 Ubuntu rootfs 和磁盘镜像
  ./build.sh --build-only 只做用户态部分(下载源码、编译 U-Boot 和内核，无需 root)
  sudo ./build.sh --root-phase  只做 root 部分(debootstrap rootfs、写镜像)
  ./build.sh --clean      清理构建产物(rootfs、镜像、U-Boot/内核编译中间文件)
环境变量:
  JOBS=N                  并行编译任务数(默认 nproc)
EOF
}

require_normal_user() {
    [[ $EUID -ne 0 ]] || die "请以普通用户运行 ./build.sh（脚本会在需要 root 时自己调用 sudo）"
}

check_deps() {
    local missing=()
    local cmds=(git make gcc bison flex bc dtc swig python3 curl tar sha256sum
                aarch64-linux-gnu-gcc qemu-system-aarch64 qemu-img debootstrap sudo)
    local c
    for c in "${cmds[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ! -f /usr/bin/qemu-aarch64-static ]]; then
        missing+=("qemu-aarch64-static")
    fi
    if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        missing+=("binfmt_misc qemu-aarch64")
    fi
    if ((${#missing[@]})); then
        die "缺少依赖: ${missing[*]}
请先安装:
  sudo apt install -y qemu-system-arm qemu-user-static debootstrap \\
    build-essential gcc-aarch64-linux-gnu bison flex bc device-tree-compiler \\
    libssl-dev libgnutls28-dev uuid-dev swig python3-dev python3-setuptools"
    fi
}

fetch_sources() {
    mkdir -p src images

    if [[ ! -d "$UBOOT_DIR" ]]; then
        log "下载 U-Boot ${UBOOT_VER}"
        local tar="src/u-boot-${UBOOT_VER}.tar.gz"
        curl -fL --retry 3 -o "$tar" "$UBOOT_URL"
        tar -xzf "$tar" -C src
        mv "src/u-boot-${UBOOT_VER#v}" "$UBOOT_DIR"
        rm -f "$tar"
    else
        log "U-Boot 源码已存在: $UBOOT_DIR"
    fi

    if [[ ! -d "$KERNEL_DIR" ]]; then
        log "下载 Linux ${KERNEL_VER}"
        local tar="src/linux-${KERNEL_VER}.tar.xz"
        curl -fL --retry 3 -o "$tar" "$KERNEL_URL" \
            || curl -fL --retry 3 -o "$tar" "$KERNEL_URL_FALLBACK"
        curl -fsL -o src/sha256sums.asc "$KERNEL_SHA_URL"
        ( cd src && grep "linux-${KERNEL_VER}.tar.xz" sha256sums.asc | sha256sum -c - )
        tar -xf "$tar" -C src
        rm -f "$tar" src/sha256sums.asc
    else
        log "Linux 源码已存在: $KERNEL_DIR"
    fi
}

configure_uboot() {
    log "配置 U-Boot (qemu_arm64_defconfig + virtio/ext4 + 内嵌 bootcmd)"
    make -C "$UBOOT_DIR" qemu_arm64_defconfig >/dev/null
    cat >> "$UBOOT_DIR/.config" <<'EOF'
CONFIG_BOOTCOMMAND="setenv bootargs root=/dev/vda rw rootwait console=ttyAMA0; ext4load virtio 0:0 ${kernel_addr_r} /boot/Image; booti ${kernel_addr_r} - ${fdtcontroladdr}"
EOF
    make -C "$UBOOT_DIR" olddefconfig >/dev/null
    grep -q '^CONFIG_VIRTIO_BLK=y' "$UBOOT_DIR/.config" || die "U-Boot 配置缺少 VIRTIO_BLK"
    grep -q '^CONFIG_CMD_EXT4=y' "$UBOOT_DIR/.config" || die "U-Boot 配置缺少 CMD_EXT4"
}

build_uboot() {
    if [[ ! -f "$UBOOT_DIR/.config" ]] \
        || ! grep -q '^CONFIG_VIRTIO_BLK=y' "$UBOOT_DIR/.config" \
        || ! grep -q '^CONFIG_CMD_EXT4=y' "$UBOOT_DIR/.config"; then
        configure_uboot
    fi
    log "编译 U-Boot (jobs=$JOBS)"
    make -C "$UBOOT_DIR" -j"$JOBS" CROSS_COMPILE="$CROSS_COMPILE"
    cp "$UBOOT_DIR/u-boot.bin" images/u-boot.bin
}

configure_kernel() {
    log "配置 Linux arm64 (defconfig + virtio/ext4/devtmpfs/PL011 内置)"
    make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" defconfig >/dev/null
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable VIRTIO_BLK --enable VIRTIO_MMIO --enable VIRTIO_NET --enable VIRTIO_PCI \
        --enable EXT4_FS --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
        --enable SERIAL_AMBA_PL011 --enable SERIAL_AMBA_PL011_CONSOLE \
        --enable RTC_DRV_PL031 --enable VIRTIO_CONSOLE --enable BLK_DEV_INITRD
    make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig >/dev/null
    grep -q '^CONFIG_VIRTIO_BLK=y' "$KERNEL_DIR/.config" || die "内核配置缺少 VIRTIO_BLK=y"
    grep -q '^CONFIG_EXT4_FS=y' "$KERNEL_DIR/.config" || die "内核配置缺少 EXT4_FS=y"
    grep -q '^CONFIG_DEVTMPFS_MOUNT=y' "$KERNEL_DIR/.config" || die "内核配置缺少 DEVTMPFS_MOUNT=y"
}

build_kernel() {
    if [[ ! -f "$KERNEL_DIR/.config" ]] \
        || ! grep -q '^CONFIG_VIRTIO_BLK=y' "$KERNEL_DIR/.config" \
        || ! grep -q '^CONFIG_EXT4_FS=y' "$KERNEL_DIR/.config" \
        || ! grep -q '^CONFIG_DEVTMPFS_MOUNT=y' "$KERNEL_DIR/.config"; then
        configure_kernel
    fi
    log "编译 Linux Image + 模块 (jobs=$JOBS)"
    make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image modules
    cp "$KERNEL_DIR/arch/arm64/boot/Image" images/Image

    log "安装内核模块到 staging 目录 images/modules"
    rm -rf images/modules
    make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        INSTALL_MOD_PATH="$BASE_DIR/images/modules" INSTALL_MOD_STRIP=1 modules_install
    find images/modules/lib/modules -maxdepth 2 \( -name build -o -name source \) -type l -delete
}

root_setup() {
    [[ $EUID -eq 0 ]] || die "--root-phase 需要 root 权限"
    [[ -f images/Image ]] || die "缺少 images/Image，请先运行 ./build.sh --build-only"
    [[ -f images/u-boot.bin ]] || die "缺少 images/u-boot.bin，请先运行 ./build.sh --build-only"
    [[ -d images/modules/lib/modules ]] || die "缺少 images/modules，请先运行 ./build.sh --build-only"

    export DEBIAN_FRONTEND=noninteractive

    if [[ ! -f "$ROOTFS/etc/debian_version" ]]; then
        log "debootstrap Ubuntu 24.04 LTS (noble) arm64 -> $ROOTFS"
        mkdir -p "$ROOTFS"
        debootstrap --arch=arm64 --foreign --variant=minbase --components=main,universe \
            noble "$ROOTFS" "$UBUNTU_MIRROR"
        install -m755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
        log "debootstrap 第二阶段"
        chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
    else
        log "rootfs 已存在: $ROOTFS"
    fi

    log "挂载伪文件系统并安装软件包"
    cleanup_mounts() {
        local d
        for d in dev/pts dev sys proc; do
            umount "$ROOTFS/$d" 2>/dev/null || umount -l "$ROOTFS/$d" 2>/dev/null || true
        done
    }
    cleanup_mounts
    trap cleanup_mounts EXIT

    mountpoint -q "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc"
    mountpoint -q "$ROOTFS/sys" || mount -t sysfs sysfs "$ROOTFS/sys"
    mountpoint -q "$ROOTFS/dev" || mount --bind /dev "$ROOTFS/dev"
    mountpoint -q "$ROOTFS/dev/pts" || mount --bind /dev/pts "$ROOTFS/dev/pts"

    cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
    printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
    chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

    chroot "$ROOTFS" apt-get update
    chroot "$ROOTFS" apt-get install -y --no-install-recommends \
        systemd-sysv systemd-timesyncd udev dbus openssh-server sudo \
        iproute2 iputils-ping kmod procps nano less ca-certificates curl tzdata
    rm -f "$ROOTFS/usr/sbin/policy-rc.d"

    log "配置主机名/用户/串口/网络"
    echo "ubuntu-arm64" > "$ROOTFS/etc/hostname"
    cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 ubuntu-arm64
::1 localhost ip6-localhost ip6-loopback
EOF
    printf '/dev/vda / ext4 defaults 0 1\n' > "$ROOTFS/etc/fstab"

    echo "root:root" | chroot "$ROOTFS" chpasswd
    if ! chroot "$ROOTFS" id ubuntu >/dev/null 2>&1; then
        chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo ubuntu
    fi
    echo "ubuntu:ubuntu" | chroot "$ROOTFS" chpasswd

    ln -sf /usr/share/zoneinfo/Etc/UTC "$ROOTFS/etc/localtime"
    echo "Etc/UTC" > "$ROOTFS/etc/timezone"
    echo 'LANG=C.UTF-8' > "$ROOTFS/etc/default/locale"
    chroot "$ROOTFS" systemd-machine-id-setup || true
    chroot "$ROOTFS" systemctl mask systemd-firstboot.service >/dev/null 2>&1 || true

    mkdir -p "$ROOTFS/etc/systemd/network"
    cat > "$ROOTFS/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=e*

[Network]
DHCP=yes
EOF
    rm -f "$ROOTFS/etc/resolv.conf"
    printf 'nameserver 10.0.2.3\nnameserver 223.5.5.5\n' > "$ROOTFS/etc/resolv.conf"
    chroot "$ROOTFS" systemctl enable systemd-networkd.service >/dev/null
    chroot "$ROOTFS" systemctl enable ssh.service >/dev/null

    mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
    ln -sf /lib/systemd/system/serial-getty@.service \
        "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

    mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
    cat > "$ROOTFS/etc/ssh/sshd_config.d/99-password-auth.conf" <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
EOF

    log "安装内核 Image 和模块到 rootfs"
    install -m644 images/Image "$ROOTFS/boot/Image"
    mkdir -p "$ROOTFS/lib/modules"
    cp -a images/modules/lib/modules/. "$ROOTFS/lib/modules/"
    chown -R root:root "$ROOTFS/lib/modules"
    rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

    log "清理 rootfs 缓存"
    chroot "$ROOTFS" apt-get clean
    rm -rf "$ROOTFS/var/lib/apt/lists"/* "$ROOTFS/debootstrap"
    find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true

    cleanup_mounts
    trap - EXIT

    log "生成磁盘镜像 $IMAGE ($IMAGE_SIZE)"
    rm -f "$IMAGE"
    truncate -s "$IMAGE_SIZE" "$IMAGE"
    mkfs.ext4 -F -q -L ubuntu -m 0 -d "$ROOTFS" "$IMAGE"
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown "$SUDO_UID:$SUDO_GID" "$IMAGE"
    fi
    log "完成: $IMAGE"
}

clean_all() {
    log "清理构建产物"
    rm -rf images "$IMAGE"
    if [[ -d "$ROOTFS" ]]; then
        sudo rm -rf "$ROOTFS"
    fi
    if [[ -d "$UBOOT_DIR" ]]; then
        make -C "$UBOOT_DIR" distclean >/dev/null 2>&1 || true
    fi
    if [[ -d "$KERNEL_DIR" ]]; then
        make -C "$KERNEL_DIR" ARCH=arm64 mrproper >/dev/null 2>&1 || true
    fi
    log "源码目录 src/ 保留"
}

case "${1:-}" in
    -h|--help)
        usage
        ;;
    --clean)
        require_normal_user
        clean_all
        ;;
    --root-phase)
        shift
        root_setup
        ;;
    --build-only)
        require_normal_user
        check_deps
        fetch_sources
        build_uboot
        build_kernel
        log "用户态构建完成。执行 sudo ./build.sh --root-phase 生成 rootfs 和镜像"
        ;;
    "")
        require_normal_user
        check_deps
        fetch_sources
        build_uboot
        build_kernel
        log "用户态构建完成，请求 sudo 权限生成 Ubuntu rootfs 和磁盘镜像"
        exec sudo "$BASE_DIR/build.sh" --root-phase
        ;;
    *)
        usage
        die "未知参数: $1"
        ;;
esac
