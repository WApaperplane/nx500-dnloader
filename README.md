# NX500 bootloader 解剖 + dnloader 骨架

> 三星 NX500（DRIMe5s）的 `dnloader.bin` 从未公开——它是 Main PCB Recovery
> （维修手册 7-6 节）唯一的门，也是"变砖后彻底无救"的根源。
>
> 本仓库不移植别的机型，而是**直接从 NX500 自己的 `boot0.bin` 反汇编**，
> 给出：① 完整的硬件常量表 ② boot0 的启动分派逻辑 ③ 一个 912 字节的
> 位置无关 dnloader 骨架（QEMU 实跑验证通过）。

English: [README_en.md](README_en.md)

---

## 0. 重大进展：已发现免拆机隐藏恢复模式（仅限 NX500 软砖恢复 / Unbrick）

借助本仓库对 `boot0` recovery 分支（GPIO 19/27/30/31）的逆向结果，并对照三星官方 NX500 GPL 内核源码 `include/gpio_map_nx500.h`，已独立定位并在真实 NX500 硬件上验证了**免拆机、无需短接主板、无需串口、无需 `downloader.bin` 的内置固件恢复模式**（适用于 `nx-on-wake` 失败、`systemctl rescue` 卡死等软砖场景）：

**外部按键组合（实机验证通过）：**

1. 下载官方原版未修改的 NX500 固件（如 v1.12），将 `nx500.bin` 解压到干净的 **FAT32** SD 卡根目录。
2. 拔出电池，插入 SD 卡，将后背屏幕**完全向上翻起至自拍位**，重新装入电池（保持电源开关关闭）。
3. 同时按住 **MOBILE (Wi-Fi)** 键 + **AEL** 键 + **全按快门**，再拨动电源开关开机。
4. 屏幕出现蓝底 **Recovery Mode** 界面（`F/W Check` / `Update` / `Update Finish`）后松手，按屏幕提示**长按快门键**开始刷写 `nx500.bin`。

> **注意与边界：**
> - **务必使用官方未修改固件**，刷写期间（`Updating / Do not power off.`）确保电量充足，**切勿断电或拔电池**，直至出现 `Update Finish`。
> - **实机验证范围**：已在因 `nx-on-wake` 软砖的 NX500 上完整走通 `Recovery Mode` → `F/W Check` → `Updating` → `Update Finish` 并正常开机；**未在 NX1 或其他机型上验证**（NX1 GPIO 定义不同且无翻转屏）。
> - **与 Boot ROM `downloader.bin` 恢复的区别**：该免拆机恢复依赖 `boot0` 与内部 `rImage`（p13）完好，可解决系统层/休眠镜像软砖；只有当 `boot0` 本身损坏或无法进入 `boot0` 时，才需要主板 Boot ROM 级 `downloader.bin` 或 UART 救砖。

---

## 1. 结论先行

| 问题 | 答案 |
|---|---|
| dnloader 要不要移植 NX300 的源码？ | **不要**。boot0 已具备全部能力，缺的只有 SD 驱动 |
| DDR 参数要逆吗？ | **不需要**。bootROM 早已初始化 DDR（boot0 的 stub 直接 `mov pc,#0x80000000` 为证） |
| UART 基址？ | **0x10038000**，ARM PL011，115200 8N1 |
| SD 卡控制器？ | **0x08800000**（DesignWare MMC） |
| SD 卡电源引脚？ | **GPIO 179**（boot0 在进 recovery 前会先把它拉高） |
| boot0 会不会自己加载内核？ | **会**。recovery 分支就是 `load_image(0x86007FC0, …) + 跳 A9` |
| 有没有现成的救砖工具？ | **有**。boot0 内置 shell：开机时 UART 收到回车即可进入，命令含 `test flash read/erase` |

---

## 2. 这个骨架是什么

912 字节的裸二进制，**唯一使命是回答三个未知**：

| 输出的那一行 | 回答了什么问题 |
|---|---|
| `[dn] load addr : 0x........` | bootROM 把 dnloader 加载到哪个地址（此前完全未知） |
| `[dn] CR / FR / IBRD` | UART 时钟有没有给、初始化是否生效 |
| 有没有任何输出 | bootROM 认不认这个文件格式 |

一次上电就能同时判定：格式是否被接受、加载地址是多少、串口通不通。
这比打印 hello world 有价值得多——它把三个未知压缩成一次实验。

### 设计上的三个硬约束

1. **位置无关** —— 加载地址未知，所以代码里**没有任何绝对地址**。
   地址一律 = `r4`（运行时 `_start`）+ 链接期偏移。
2. **不用栈** —— bootROM 跳过来时 `SP` 不可信。QEMU 实测 `SP = 0x00000000`，
   一旦 `push` 立刻崩溃。全程靠寄存器传值。
3. **UART 完整重初始化** —— 不假设 bootROM 已经配好，且重复初始化无害。

### 头部与 boot0 逐字节同构

```
000000  07 00 00 ea   ← b 0x24        （与 NX500 boot0.bin 完全相同）
000020  00 00 00 02   ← 0x02000000
000024  13 00 02 f1   ← cps #0x13     （与 boot0 完全相同）
```

刻意模仿 boot0 的 stub 布局，最大化"被 bootROM 接受"的概率。

---

## 3. QEMU 实跑验证（已通过）

```sh
cd src && sh run_qemu_test.sh
```

实际输出：

```
=== NX500 dnloader skeleton v0.2 ===
[dn] load addr : 0x60100000      ← 链接在 0，实跑在 0x60100000：位置无关成立
[dn] cpsr      : 0x600001d3      ← SVC 模式，I/F 已关
[dn] sp        : 0x00000000      ← SP 是 0，证明不能依赖栈
[dn] --- uart self-check ---
[dn] CR        : 0x00000301      ← TXE|RXE|UARTEN
[dn] FR        : 0x00000090      ← TXFE|RXFE
[dn] IBRD      : 0x00000036      ← 54，写入可读回
[dn] heartbeat: ..........
```

测试用 `vexpress-a9`（Cortex-A9 / ARMv7，与真机同架构），只把 UART 基址换成
`0x10009000`。原始输出见 `evidence/qemu_test_output.txt`。

---

## 4. 还没验证的部分（诚实清单）

| 项 | 状态 | 为什么没验证 |
|---|---|---|
| 真机能否加载并执行 | ❌ | 需要 UART（micro-USB 或测试点），作者无此条件 |
| bootROM 在 SD 上认什么文件名 | ❌ | 无文档；维修手册说 `dnloader.bin` |
| 加载地址是否也是 0x02000000 | ❌ | 骨架就是为这个设计的——它会自己打印出来 |
| SD 卡初始化能否跑通 | ❌ | 骨架还不含 SD 驱动，只有 UART |
| 四 GPIO(19/27/30/31) 是否就是短接点 | ✅ | **已实证为外部按键+翻转屏**（`WIFI`+`AEL`+`全快门`+`自拍翻转`），可免拆机进 `rImage` 刷官方 `nx500.bin`（NX1 未验证） |

**这个仓库的价值在于把"完全空白"变成"只差一次上电实验"。**

---

## 5. 目录

```
├── src/
│   ├── dnloader_skeleton.S    ← 装配源（912 B 产物）
│   ├── build.sh               ← 交叉编译 → dnloader.bin
│   ├── run_qemu_test.sh       ← QEMU 回归测试
│   └── dnloader.bin           ← 可直接放 SD 卡根目录
├── docs/
│   ├── HW_CONSTANTS.md        ← ★ 硬件常量总表（带双源交叉验证标注）
│   ├── UART_ACCESS.md         ← ★ UART 接入现状：micro-USB 路已证伪，焊盘路待定位
│   └── BOOT0_ANATOMY.md       ← boot0 完整解剖
└── evidence/
    └── qemu_test_output.txt
```

---

## 6. 复现

```sh
# 需要 arm-linux-gnueabi-gcc（Ubuntu: gcc-arm-linux-gnueabihf 或 arm-linux-gnueabi）
cd src
sh build.sh          # → dnloader.bin, 912 B
sh run_qemu_test.sh  # → QEMU 实跑输出
```

反汇编 boot0（需要自己的 `boot0.bin` dump，4 MiB）：

```sh
dd if=boot0.bin of=/tmp/b0.bin bs=1 count=56289
arm-linux-gnueabi-objdump -D -b binary -m arm \
    --adjust-vma=0x02000000 /tmp/b0.bin > /tmp/b0.dis
```

★ 基址 `0x02000000` 不是猜的：全镜像的字符串字面量都是 `0x0200xxxx` 形式。
★ 主体从**分区偏移 0x200** 开始（56,289 B），即 SLP 里的 `img1 boot0@512`。

---

## 7. 致谢与免责

- 硬件常量来自 NX500 官方 GPL 源码包（`arch/arm/mach-drime5/`）与本机 `boot0.bin`
  的独立反汇编，两者交叉验证一致处已标注 `[both]`。
- **写 eMMC boot 分区有把机器彻底变砖的风险**。本仓库只提供静态分析与一个
  只读的探测程序，不含任何写操作。请自行备份 `boot0` / `boot1` / `p1` 分区。
- 特别提醒：**p1（adj 校准：IQ/VFPN/色阴影/坏点）是固件包不包含、也唯一不可再生的
  分区**。备份优先级最高。
