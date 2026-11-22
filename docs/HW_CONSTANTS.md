# NX500 / DRIMe5s 硬件常量表（实测 + 双源交叉验证）

所有地址均为**物理地址**。`SYSTEM_BASE = 0x00000000`，所以物理地址 = 偏移值本身。

证据标注：
- **`[boot0]`** —— 从本机 dump 的 `boot0.bin` 反汇编得出（`--adjust-vma=0x02000000`）
- **`[gpl]`** —— 取自 NX500 GPL 源码包 `arch/arm/mach-drime5/include/mach/map.h`
- **`[both]`** —— 两路独立得出且一致（置信度最高）

---

## 1. 存储

| 模块 | 物理基址 | 证据 | 备注 |
|---|---|---|---|
| **SD 卡（dw_mmc）** | **0x08800000** | `[gpl]` `DRIME5_PA_PERI_SLAVE_SDU1` | 大小 0x1000 |
| SD 卡时钟相位控制 | **0x10040000** | `[gpl]` `DRIME5_PA_SDU1_CFG` | bit31 写使能，[5:4] sample，[1:0] drive |
| SD 卡第二控制器（Cadence SDHCI） | 0x08801000 | `[gpl]` `DRIME5_PA_PERI_SLAVE_SDU2` | 大小 0x2000，NX500 未启用 |
| SDIO / WiFi | 0x08C00000 | `[gpl]` `DRIME5_PA_PERI_SLAVE_SDIO` | |
| **eMMC（dw_mmc）** | **0x08C01000** | `[gpl]` `DRIME5_PA_PERI_SLAVE_EMMC` | |
| eMMC 时钟相位控制 | 0x10043000 | `[gpl]` `DRIME5_PA_eMMC_CFG` | |

★ **易错点**：`0x10016000` **不是** eMMC，它是 **GPIO 第 22 组**（见 §2）。
  这个坑我踩过——boot0 在 `emmc_init` 前操作 `[0x100163FC] bit6`，那是 pin 182，不是 eMMC 寄存器。

## 2. GPIO

| 项 | 值 | 证据 |
|---|---|---|
| GPIO 组 0..6 基址 | **0x10000000 + 组×0x1000** | `[both]` |
| GPIO 组 7 基址 | **0x10020000** | `[both]` |
| 数据寄存器 | 组基址 **+0x3FC** | `[boot0]` 0x200a878 |
| 方向寄存器 | 组基址 **+0x400** | `[boot0]` 0x200a7ac |
| 位设置/清除 | 组基址 **+0x400+bit+2**（逐 bit 字节） | `[boot0]` 0x200a7ac |
| 引脚 → 组 映射表 | 0x0200dd10（boot0 自建，SRAM） | `[boot0]` 0x200a8b4 |
| 引脚复用（GMU） | **0x10401000 + 组×4**，[11:8]=pull，[6:0]=func | `[both]` |
| 读写函数 | 读 0x200a878 / 写 0x200a7ac / mux 0x200a8fc | `[boot0]` |

GPIO 基址 `0x10000000` 与 `GPIO_1 = 0x10020000` 在 `[boot0]` 和 `[gpl]` 两路完全一致，
这是"boot0 反汇编可信"的强证据之一。

### NX500 实测引脚号

`DRIME5_GPIOx(y)` = `x*8 + y`（`[gpl]` `include/gpio_map_nx500.h`）

| 信号 | 宏 | 引脚 | 组 / bit |
|---|---|---|---|
| **SD 卡 3.3V 电源** | `GPIO_SD_3_3V_CTL = GPIO22(3)` | **179** | 22 / 3 |
| SD1_D1 | `GPIO23(4)` | 188 | 23 / 4 |
| SD1_D0 | `GPIO23(5)` | 189 | 23 / 5 |
| SD1_CLK | `GPIO23(6)` | 190 | 23 / 6 |
| SD1_CMD | `GPIO23(7)` | 191 | 23 / 7 |
| SD1_D3 | `GPIO24(0)` | 192 | 24 / 0 |
| SD1_D2 | `GPIO24(1)` | 193 | 24 / 1 |
| SD 卡检测 | `GPIO_SD1_CDX = GPIO8(5)` | 69 | 8 / 5 |

★★ **pin 179 是本轮最重要的发现之一**：boot0 的 recovery 分支在打印
`"Starting A9 for recovery."` **之前**，先做了 `gpio_set_pull(179,0x800)` +
`gpio_set_func(179,0x7f,0)` + `gpio_set_value(179,1)`。
`[gpl]` 独立证明 179 == `GPIO_SD_3_3V_CTL`。
⇒ **boot0 在进入 recovery 前给 SD 卡上电**，即 recovery 走 SD 卡路径。

## 3. UART

| 项 | 值 |
|---|---|
| 基址 | **0x10038000**（`[both]`，`DRIME5_PA_UART`） |
| IP | **ARM PL011**（`[boot0]`：FR 的 bit5=TXFF / bit6=RXFF，CR 的 bit8/9=TXE/RXE） |
| 参数 | 115200 8N1（`LCR_H = 0x60`） |
| UART1 | 0x10039000 |
| 外设控制 | **0x101FF000**（`[both]`，`DRIME5_PA_PERI_CON`），+0x1C = UART_CLK_RESET，+0x9C = UART_CLK_GATE |

### PL011 寄存器（boot0 实际使用的偏移）

| 偏移 | 名称 | boot0 写入值 | 语义 |
|---|---|---|---|
| +0x00 | DR | — | 读写同一寄存器（收/发） |
| +0x04 | RSR/ECR | 0xFFFFFFFF | 错误清除（RX 出错时） |
| +0x18 | FR | — | bit5 TXFF（满）、bit6 RXFF（有数据） |
| +0x24 | IBRD | **54** | 整数分频 |
| +0x28 | FBRD | **16** | 小数分频 |
| +0x2C | LCR_H | **0x60** | 8 位、无校验、1 停止位、FIFO 关 |
| +0x30 | CR | **0x300 → 0x301** | TXE \| RXE → \| UARTEN |
| +0x34 | IFLS | **0x1F0** | FIFO 触发水位 |
| +0x38 | IMSC | **0x12** | RX/TX 中断屏蔽 |
| +0x48 | DMACR | **0** | DMA 关 |

★ 上述写入值全部取自 boot0 `0x2000ba4`（分频）与 `0x2000bc8`（初始化）的实机代码，
  QEMU 回归测试中读回 `CR=0x301`、`IBRD=0x36` 均正确。

## 4. 时钟 / 电源 / 系统控制

| 模块 | 基址 | 用途 |
|---|---|---|
| **CMU** 时钟管理 | 0x10400000 | |
| **GMU**（GPIO Mux Unit） | 0x10401000 | 引脚复用，见 §2 |
| RMU 复位管理 | 0x10402000 | |
| PMU 电源管理 | 0x10403000 | |
| **PCU** 电源控制 | **0x10404000** | boot0 的 `warm boot` 判据：bit29 & bit26 == 0x24 |
| RTC | 0x10405000 | |
| 启动原因 | **0x1040400C** | bit4/3/2/1/0 → 12 种启动源 |
| PTC | 0x10030000 | |
| ADC | 0x1003C000 | 电池电压 |

★ `0x10404000` 我一开始误标为"引导标志寄存器"，`[gpl]` 表明它是 **PCU**。
  用法（bit29/26 组合判 warm boot）不受影响。

## 5. 内存与 IPIG

| 项 | 值 | 证据 |
|---|---|---|
| **SRAM** | **0x02000000** | `[both]` `DRIME5_PA_SRAM` |
| **boot0 主体加载基址** | **0x02000000** | `[boot0]` 全部字符串字面量均为 `0x0200xxxx` |
| DDR（内核运行区） | 0x80000000 起，512 MB | `[boot0]` cmdline `mem=512M` |
| 内核 uImage 落点 | **0x86007FC0**（含 64B 头）/ 入口 **0x86008000** | `[boot0]` + p6/p13 uImage 头 |
| A9 启动参数区 | **0x86000100** | `[boot0]` 0x20042f8 |
| resume magic | **0x2BEDF00D** @ `*(0x86000000)-4` | `[boot0]` 0x20049c8 |
| 模式握手 | 0x03B34800 + type×0x100 | `[boot0]` 0x2006c54 |
| IPCC | 0x07E00000 | `[gpl]` |
| CORE_CTRL | 0x07F00000 | `[gpl]` |

## 6. dw_mmc 寄存器（DesignWare MMC，SD 与 eMMC 共用）

`[gpl]` `drivers/mmc/host/dw_mmc.h`

| 偏移 | 名称 | 偏移 | 名称 |
|---|---|---|---|
| 0x000 | CTRL | 0x040 | MINTSTS |
| 0x004 | PWREN | 0x044 | RINTSTS |
| 0x008 | CLKDIV | 0x048 | STATUS |
| 0x010 | CLKENA | 0x04C | FIFOTH |
| 0x014 | TMOUT | **0x050** | **CDETECT**（卡检测） |
| 0x018 | CTYPE | 0x054 | WRTPRT |
| 0x01C | BLKSIZ | 0x06C | VERID |
| 0x020 | BYTCNT | 0x074 | UHS_REG |
| 0x024 | INTMASK | 0x080 | BMOD |
| 0x028 | CMDARG | 0x084 | PLDMND |
| 0x02C | **CMD** | 0x100 | FIFO DATA（240A 及以后为 0x200） |

CRTL 关键位：`RESET(0)` `FIFO_RESET(1)` `DMA_RESET(2)` `INT_ENABLE(4)` `DMA_ENABLE(5)`
CMD 关键位：`START(31)` `USE_HOLD_REG(29)` `VOLT_SWITCH(28)` `CCS_EXP(23)`
RINTSTS：`CMD_DONE(2)` `DATA_OVER(3)`

## 7. boot0 关键函数索引

| 地址 | 作用 |
|---|---|
| 0x2000b24 | `uart_putc`（直写 0x10038000，PL011） |
| 0x2000af4 | `uart_getc` |
| 0x2000ba4 | `uart_baud_init`（IBRD/FBRD/LCR_H） |
| 0x2000bc8 | `uart_init`（含 PERI_CON 时钟释放） |
| 0x2000c24 | `print_string`（经 bootROM 钩子 `*(0x0200E424)`，可被替换） |
| 0x200a878 | `gpio_get_value` |
| 0x200a7ac | `gpio_set_value` |
| 0x200a8b4 | `gpio_set_pull` |
| 0x200a8fc | `gpio_set_func`（pinmux） |
| 0x20033d8 | `boot_reason()` |
| 0x2003368 | `start_a9(type, addr, size, src)`；type 2 = M4，type 4 = A9 |
| 0x20073bc | `load_image(addr, size, src)` |
| 0x2006c54 | `boot_mode_handshake(1, type)` |
| 0x2006f0c | `emmc_init()` |
| 0x2003f00 | **bootloader shell**（等 UART 回车进入） |
| 0x20034d4 | `main` |
| 0x20049c8 | snapshot / warmboot resume |

## 8. boot0 启动分派（结论）

```
[ctrl+6] == 1  ⟺  ctrl->byte[0xC0] == 1   →  "Starting A9 for upgrade."
                                            （参数取 ctrl+0x48/0x40/0x44）
否则                                        →  "Starting A9 for linux."（加载 p6）

四 GPIO(27/31/19/30) 全读 0 时才到达：
        gpio_set_value(179, 1)              ← ★ 给 SD 卡上电
        "Starting A9 for recovery."
        load_image(0x86007FC0, 0x002D4801, 0x4C4C) + 跳 A9

开机时 UART 收到 0x0D（10 次轮询内）：
        0x2003f00 bootloader shell
        命令：boot [mode] / test ddr / test flash read|erase
```

`ctrl = *(void**)0x0200E074`，该指针由 bootROM 传入（位于 boot0 镜像之外）。
