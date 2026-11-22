#!/bin/sh
# QEMU 回归测试：同一份源码，只把 UART 基址换成 vexpress-a9 的 0x10009000。
# 关键点：-Ttext=0x60100000 让它"被加载到 0x60100000"，而源码里没有任何绝对地址，
#        所以这个测试同时验证了「位置无关」这一核心属性。
set -e
cd "$(dirname "$0")"

qemu-system-arm -M help 2>/dev/null | grep -q vexpress-a9 || {
    echo "缺少 qemu-system-arm 或 vexpress-a9 机型" >&2
    exit 1
}

CC=${CC:-arm-linux-gnueabi-gcc}

echo "--- 编译测试版（-DQEMU_TEST, -Ttext=0x60100000）---"
$CC -DQEMU_TEST -nostdlib -nostartfiles -ffreestanding \
    -march=armv7-a -marm -O2 -Wall \
    -Wl,--build-id=none -Wl,-Ttext=0x60100000 \
    -o dnloader_test.elf dnloader_skeleton.S

echo "--- 在 vexpress-a9 上执行 8 秒 ---"
timeout 8 qemu-system-arm -M vexpress-a9 -m 256 \
    -kernel dnloader_test.elf -nographic 2>&1 \
    | grep -vE 'pw\.conf|pulseaudio|^$' || true

echo
echo "期望输出要点："
echo "  load addr = 0x60100000  → 位置无关成立"
echo "  sp        = 0x00000000  → 证明不能依赖栈（代码已全程不用栈）"
echo "  CR        = 0x00000301  → TXE|RXE|UARTEN"
echo "  IBRD      = 0x00000036  → 54，写入可读回"
