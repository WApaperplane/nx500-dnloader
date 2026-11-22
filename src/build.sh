#!/bin/sh
# NX500 dnloader skeleton 构建脚本（WSL / Linux 交叉编译）
# 用法: sh build.sh
set -e

CC=${CC:-arm-linux-gnueabi-gcc}
OC=${OC:-arm-linux-gnueabi-objcopy}

cd "$(dirname "$0")"

echo "--- 编译 ---"
$CC -nostdlib -nostartfiles -ffreestanding \
    -march=armv7-a -marm -mno-thumb-interwork \
    -O2 -Wall \
    -Wl,--build-id=none \
    -Wl,-Ttext=0x0 \
    -o dnloader.elf dnloader_skeleton.S

echo "--- 提取裸二进制 ---"
$OC -O binary dnloader.elf dnloader.bin

echo "--- 结果 ---"
ls -l dnloader.bin
echo -n "md5: "; md5sum dnloader.bin | cut -d' ' -f1

echo
echo "--- 头部 0x30 字节（应为 8 条向量 + 02000000）---"
od -Ax -tx1 -N48 dnloader.bin

echo
echo "--- 检查是否存在绝对地址重定位（应全部是 pc 相对）---"
arm-linux-gnueabi-objdump -d dnloader.elf | grep -E "ldr\s+r[0-9]+, \[pc" | head -5
