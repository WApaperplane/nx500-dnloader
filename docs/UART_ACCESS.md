# NX500 UART 接入现状（截至 2026-11-22）

## 一句话

**UART 控制器 100% 存在且在用，但从哪根线接出来，社区 10 年没有闭合。**
micro-USB 路线已被两个人独立试过并失败，**不要再重复。**

---

## 1. 控制器侧：已完全确证

| 项 | 值 | 证据 |
|---|---|---|
| IP | ARM PL011 | boot0：FR 的 bit5=TXFF / bit6=RXFF，CR 的 bit8/9=TXE/RXE |
| 基址 | **0x10038000** | boot0 反汇编 + GPL 源码 `DRIME5_PA_UART` 双源一致 |
| 参数 | 115200 8N1 | boot0 写 `LCR_H=0x60`、`IBRD=54`、`FBRD=16` |
| 时钟门控 | 0x101FF000 +0x1C | `DRIME5_PA_PERI_CON` |
| 内核侧 | `console=ttyAMA0,115200n8` | boot0 内置 cmdline 模板 |
| 谁初始化它 | **boot0 自己**（0x2000bc8） | ⇒ bootROM 阶段可能没有任何输出 |

★ 最后一条很重要：**boot0 自己才初始化 UART**。所以"上电就应该有串口日志"这个假设是错的——
在 boot0 跑到 0x2000bc8 之前，串口可能完全静默。这解释了部分历史尝试为何"什么都看不到"。

---

## 2. 物理侧：两条候选路线

### 路线 A：micro-USB 复用（MUIC）—— ❌ 已证伪

维修手册 BOM 里确实有 **MUIC = TSU6111RSVR**（TI 的 Micro-USB Switch，与 NX300 同款），
理论上支持把 SoC UART 切到 USB 的 D+/D-。

**但 2016 年有两次独立尝试，全部失败：**

| 谁 | 设备 | 做法 | 结果 |
|---|---|---|---|
| ge0rg（samsung-nx-hacks） | NX300 + NX500 | USB-OTG-UART 线，ID 脚 150K / 620K 接地 | NX300 无输出；**NX500 连 dmesg 都没有** |
| vasile（dpreview） | NX500 | 改用普通 micro-USB 母座 + 电阻接在 ID 与 GND 之间（正确接法），开机时插着 | **"No comms on micro-usb configured as UART"**，最后送回原厂 |

来源：
- https://github.com/ge0rg/samsung-nx-hacks/issues/7
- https://www.dpreview.com/forums/threads/not-sending-my-brick-in-yet-will-try-to-unbrick-through-boot-console.4004545

★ vasile 那条还纠正了一个常见错误：**OTG 线的 ID 脚内部已短接到 GND，串电阻无效**，
必须用普通线、把电阻接在 ID 与 GND 之间，并在开机前插好。

★★ 所以：**除非能证明 TSU6111 需要额外的 GPIO/I²C 配置，否则这条路不必再试。**

### 路线 B：主板测试焊盘 —— ◐ 线索有，但未定位

社区一直提"主板上有一组 **2×4 接触焊盘**"（iFixit 的 **NX300** 主板更换教程照片里能看到）：

- https://de.ifixit.com/Guide/Samsung+NX300+Motherboard+Replacement/36344

**NX500 上没人确认过这组焊盘在哪、是不是 UART。**

维修手册第 5/6 章的主板框图文本里出现了这些信号名：

```
SDC 3" FVGA / OLED / 3Axis(BMA254)
I2S0_MCLK/BCLK/LRCLK/DAC/ADC
MUIC TSU6111RSVR
eMMC 4.5 (1.8V)
SDIO / SDIO_D0:D3/CLK/CMD / SD_D0:D3/CLK/CMD
USB_DM/DP , MUIC_SCL/SDA
HDMI_CEC / HPD / SCL/SDA
LCD_MIPI_D0:1/CLK
```

★★ **注意：框图里没有 UART**。这可能意味着 UART 只引到了测试焊盘，没有画进信号框图。

维修手册的元件表里，与调试相关的是：

```
SW_DEBUG1000 / SW_DEBUG1001     ← 两个调试开关/跳线
TP1000 ... TP1027               ← 连续一大组测试点（TP-C0-45PIE 焊盘）
TP5007-5009 / TP6001,6007,6008 / TP7001-7005,7009,7010
```

★ `SW_DEBUG1000/1001` 在元件表中紧邻 `TP1000/TP1001` 之前 —— **TP1000 组很可能就是调试/UART 组**。
但手册只给料号（`TP-C0-45PIE` = 焊盘类型），**没有信号定义**，所以无法直接定论。

---

## 3. 如果要做，实际需要什么

| 步骤 | 工具 | 难度 |
|---|---|---|
| 拆后盖到主板 | 十字 #000、T6、撬棒 | 低（iFixit 教程 13 步） |
| 找 TX 焊盘 | 万用表/逻辑分析仪，上电看 115200 的方波 | **中——难点在这里** |
| 焊 3 根线（GND/TX/RX） | 尖头烙铁、0.1mm 漆包线 | 中 |
| 读日志 | 3.3V USB-TTL（CH340/CP2102） | 低 |

★★ **关键判断：难的不是焊接，是"在几十个焊盘里认出哪几个是 UART"。**
而这需要拆机 + 仪器，属于"有救砖需求的人才愿意付的成本"。

对一台**正常工作的 NX500** 来说，拆机的期望收益是负的。

---

## 4. 所以最优路径是

1. **不要自己硬上**。等真有救砖需求，或者等社区有人为了查清这个问题去拆机。
2. **发帖时把问题问准**，别问"怎么接 UART"，而是问：
   - 有没有人拆过 NX500 主板？能否拍那组 2×4 焊盘的高清照片？
   - 或者：谁的原厂 NX500 变砖了、愿意当实验品？
3. **明确告诉大家 micro-USB 路已死**（省掉下一个人一个周末）。

★ 一旦拿到那组焊盘的照片和位置，剩下的事（焊线、读日志、跑 dnloader）都是半小时的活。
