#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

[[ -f images/u-boot.bin ]] || { echo "缺少 images/u-boot.bin，请先运行 ./build.sh" >&2; exit 1; }
[[ -f ubuntu-arm64.img ]]  || { echo "缺少 ubuntu-arm64.img，请先运行 ./build.sh" >&2; exit 1; }

supports_user_net() {
    "$1" -M virt -netdev help 2>/dev/null | grep -qx 'user'
}

QEMU_BIN="${QEMU_BIN:-}"
if [[ -z "$QEMU_BIN" ]]; then
    for q in "$(command -v qemu-system-aarch64 2>/dev/null || true)" /usr/bin/qemu-system-aarch64; do
        [[ -n "$q" && -x "$q" ]] || continue
        if supports_user_net "$q"; then
            QEMU_BIN="$q"
            break
        fi
    done
fi
[[ -n "$QEMU_BIN" ]] || QEMU_BIN="$(command -v qemu-system-aarch64)"

NET_ARGS=()
if supports_user_net "$QEMU_BIN"; then
    NET_ARGS=(-netdev user,id=net0,hostfwd=tcp::2222-:22
              -device virtio-net-device,netdev=net0)
else
    echo "WARN: $QEMU_BIN 不支持 user 网络后端，跳过网卡（仅串口登录）" >&2
fi

echo "QEMU: $QEMU_BIN"
echo "启动 U-Boot -> Linux -> Ubuntu 24.04 arm64"
if ((${#NET_ARGS[@]})); then
    echo "SSH: ssh -p 2222 ubuntu@127.0.0.1  (密码 ubuntu)"
fi
echo "退出 QEMU: Ctrl-A 然后 X"
echo

exec "$QEMU_BIN" \
    -M virt \
    -cpu cortex-a72 \
    -smp "${SMP:-2}" \
    -m "${MEM:-2048}" \
    -bios images/u-boot.bin \
    -drive if=none,file=ubuntu-arm64.img,format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    "${NET_ARGS[@]}" \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-device,rng=rng0 \
    -nographic
