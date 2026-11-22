# boot0 完整解剖 —— dnloader 的正确下手方式（2026-11-22）

> 素材：`_deliverables/fwbackup/boot0.bin`（eMMC boot0 分区 4 MiB 全量 dump，md5 `ec406739bb8135bdd6c4c0681e55597b`）
> 方法：`arm-linux-gnueabi-objdump -D -b binary -m arm --adjust-vma=0x02000000`
> 结论：**dnloader 不需要移植 NX300，应该从 NX500 自己的 boot0 里削。**

---

## 0. 一句话

boot0 里**已经包含 dnloader 需要的全部能力**（eMMC 读、DDR 写、UART、跳转、甚至一个交互 shell）。
真正缺的只有 **SD 卡驱动**那一块。而上一版文档判断的"最大风险：DDR 参数未逆"是**错的**——
**bootROM 早就把 DDR 初始化好了**，boot0 和 dnloader 都免费继承。

---

## 1. 物理布局（实证）

eMMC boot0 分区的真实结构——注意**两套向量表**：

```
偏移 0x0000   512 B      一级 stub
  ├─ 0x00..0x1C  8 条向量: b 0x24 / b 0x30 / ... / b 0x44
  ├─ 0x20        u32 0x02000000          ← 自身加载地址
  ├─ 0x24        u32 0xf1020013          ← magic（与主体 0x220 处同值）
  ├─ 0x28        mov r0,#0x80000000 ; mov pc,r0   ← 只做一件事：跳 DDR
  └─ 0x100..0x1FF  字符串: "DRIME5_" / "D5_DMC_ES__" / "REV0000"
                        / "bootloader.bin" / "uImage" / "devicem4.bin" / "rom.bin"

偏移 0x0200   56,289 B   boot0 主体  ★★★ 这就是 SLP 的 img1「boot0@512」
  ├─ 0x200..0x21C  第二套向量表: 06 00 00 ea → b 0x220
  ├─ 0x220        mov r0,#0 ; mcr p15 (invalidate TLB / I-cache)
  ├─ 0x230        mrc p15 → bic #0x2000, #0x7 ; orr #0x200,#0x8000 ; mcr p15  (关 MMU/cache)
  └─ 0x248 起     真正的 C 启动序
```

**字面量自证**：全镜像中所有字符串引用都是 `0x0200xxxx` 形式（如 `0x0200d34e` = "Starting A9 for upgrade."），
即 **主体运行基址 = 0x02000000（SRAM）**。而 stub 跳 `0x80000000` 说明 bootROM 已把 DDR 初始化并装载了主体——
**这是"无需逆 DDR 参数"的直接证据**。

★ `0x0200db84 = 0xFFFFFFFF`（镜像内最后一组数据），语义 = "不覆盖 boot mode"的哨兵（见 §3）。
★ `0x0200E074` / `0x0200E424` **在镜像之外**（> 0xDD00，全 FF 区），是 **bootROM 留给 boot0 的接口**。

---

## 2. 硬件常量表（可直接写代码）

| 名称 | 地址 / 值 | 证据 |
|---|---|---|
| **UART** | **0x10038000** | 7 处字面量：0x2000b20/b60/bc4/c1c、0x2003be0、0x200cc1c/cc20；+0x18 = 状态 |
| UART putc（真实现） | 0x2000b24 | 直写 0x10038000 |
| UART putc（钩子） | `*(0x0200E424)` | 0x2000c24 用 `ldr r2,[0x0200E424]; blx r2` —— bootROM 可覆盖输出通道 |
| **GPIO** | **0x10000000 + (组<<12)** | 组=pin>>3（pin&0x38==0x38 时用 0x10020000）；数据 +0x3FC，方向 +0x400，位设置 +0x402+bit |
| gpio_get | 0x200a878 | `ldrb r0,[base+0x3fc]; and r0,1<<bit; asr` |
| gpio_set | 0x200a7ac | `strb val<<bit,[base+0x400+bit+2]` 后 `strb dir,[base+0x400]` |
| PINMUX / PAD | 0x10401000 区 | 0x200a8b4(pin,pull) / 0x200a8fc(pin,mask,val)；pin→组映射表 @ 0x0200dd10 |
| **eMMC 控制器** | **0x10016000** | +0x3FC bit6 = 时钟/供电使能；init = 0x2006f0c（返回 <0 = 失败） |
| 引导标志寄存器 | 0x10404000 | bit29 & bit26 == 0x24 ⇒ warm boot；写回时清这两位 |
| 启动原因 | 0x1040400C | 0x20033d8 `boot_reason()`：bit4→4 / bit3→4 / bit2→2 / bit1→1 / bit0→(GPIO59 判定) |
| **控制块指针** | `*(0x0200E074)` | bootROM 传入；`+0xc0` = 模式字节，`+0x40/+0x44/+0x48` = 三参数 |
| mode 覆盖变量 | 0x0200DB84 | 初值 -1；`>= 0` 时 `mode = (u8)值` |
| **A9 参数区** | **0x86000100** | 0x20042f8 写：+0x100=5, +0x104=?, +0x114=4, +0x118=?, +0x11c=**0x20000000**, +0x120=**0x86000000**, +0x128=? |
| **内核落点** | **0x86007FC0**（含 64B uImage 头）/ 入口 **0x86008000** | p6/p13 的 uImage load & entry 均为 0x86008000 |
| resume magic | **0x2BEDF00D** @ `*(0x86000000) - 4` | 0x20049c8：读 `[0x86000000]` → 校验 → `blx` |
| 模式握手区 | **0x03B34800 + type*0x100** | 0x2006c54(type=4 时用 0x03B34800 常量) |

---

## 3. 启动分派（完整逻辑）

```c
main(r0 = boot_reason_hint)
{
    mode = r0;                                    // 0=cold 1=snapshot 2=warm
    if (mode != 0 && ((*(u32*)0x10404000 >> 24) & 0x24) == 0x24) {
        *(u32*)0x10404000 &= ~(bit26|bit29);
        mode = 2;  print("> warm boot");
    } else {
        *(u32*)0x10401404 = 3;
        if (emmc_init() < 0) { print("> emmc initialize fail"); return 0; }
        *(u32*)0x100163FC |= 0x40;
        if (detect_boot_reason(sp+16) == 1) { mode = 1; print("> snapshot boot"); }
        else                                { mode = 0; print("> cold boot"); }
    }

    if (*(i32*)0x0200DB84 >= 0)  mode = (u8)*(i32*)0x0200DB84;   // 覆盖

    ctrl = *(u8**)0x0200E074;                     // ★ bootROM 控制块
    b = ctrl->byte[0xC0];
    if      (b == 1) flag = 1;                    // → upgrade
    else if (b == 2 && (u8)(mode-1) > 1) flag = 2;// → 冷启动时保留 2
    else    flag = 0;
    [ctrl+6] = flag;

    /* 然后是四条互斥出站路径 */
    if (flag == 1) {
        print("Starting A9 for upgrade.");
        start_a9(4, ctrl[0x48], ctrl[0x40], ctrl[0x44]);   // 从 eMMC 加载并启动
    } else {
        print("Starting A9 for linux.");
        ... 加载 p6 uImage ...
    }

    /* recovery 分支：只有在四个 GPIO 全部读到 0 时才到达 */
    if (gpio_get(27) || gpio_get(31) || gpio_get(19) || gpio_get(30))  goto normal;
    if (*(u8*)0x0200DDE0 > 2) { gpio_set_pull(179,0x800); gpio_set_func(179,0x7f,0); gpio_set_value(179,1); }
    print("Starting A9 for recovery.");
    start_a9(4, 0x86007FC0, 0x002D4801, 0x4C4C);
    ...
}
```

其中：
- `start_a9(type, addr, size, src)` → `0x2006c54(1, type)` 后 `load_image(addr, size, src)`
- `load_image`（0x20073bc）：`if (*0x0200e380==0) emmc_init(); if (src==0) return -40; ...`
- type 2 = **M4**（devicem4 / boot1 分区，117,184 B，Thumb-2 代码）
- type 4 = **A9**

★★ 关键：**recovery 分支 = `load_image(0x86007FC0, 0x2D4801, 0x4C4C)` + 跳 A9**。
它落到 `0x86007FC0 = 0x86008000 - 0x40`，正是 **uImage 文件起点（含 64 字节头）**。
⇒ **boot0 自己就会"从 eMMC 读一个内核到 DDR 并启动"**。这就是 recovery 的全部。

---

## 4. 交互 shell（★ 被忽略的最大资产）

`0x2003f00` 是完整的 bootloader shell：512 B 栈、128 B 命令行缓冲、处理 CR(13)/BS(8)。

进入条件（`0x20035c8`）：

```c
for (i = 0; i < 10; i++) {
    if ((*(u32*)0x10038018 & 0x40) && *(u32*)0x10038000 == 13) { shell(); break; }
}
```

即 **开机瞬间在 UART(0x10038000) 上收到一个回车** 就进 shell。命令（来自字符串表）：

```
bootloader> boot [mode]            0:cold 1:snapshot 2:warm
            test help
            test ddr [Test Count]
            test flash read [Block No.]
            test flash erase [Start] [End]
            test flash erase snapshot
```

⇒ **`test flash erase` + `boot` 已经是一个可用的救砖工具**，不需要 dnloader。
只不过窗口极短（10 次轮询、无延时），需要**连续狂发 0x0D**。

---

## 5. 镜像实况（p6 / p13）

| 分区 | 类型 | uImage data size | load = entry | md5 |
|---|---|---|---|---|
| **p6** uImage 10M | zImage | 3,175,976 | **0x86008000** | `1a43f1f26c9ca6686f75e13b595fe588` |
| **p13** rImage 10M | zImage | 6,169,752 | **0x86008000** | `ead68102a0dc43f4189e19cbb7169fd1` |

两者都是 `Linux-3.5.0`、comp=0、解压后分别为 4.5 MB / **9.2 MB**。
p13 解包验证：
- `0x64` = zImage magic `0x016f2818`；`0x6c` = 6,169,752；`0x70` = `mov r7,r1` 自解压入口
- `0x55C0` 起 gzip 流
- **无 initramfs**（全镜像只有一个 `070701`，是 `init/initramfs.c` 里的字符串常量）
- `recovery` 的 10 次命中全部来自 `fs/jbd2/recovery.c` 等内核源码串

⇒ p13 不是"自带恢复程序的内核"，只是一个**更大的、带更多驱动的内核**。
"rImage" 的语义仍是"recovery 时启动的那个内核"，用户态仍来自 p10 rootfs。

---

## 6. 对 dnloader 的重新定义（★ 本文核心）

### 上一版（2026-11-21）的判断，错在哪

| 旧判断 | 实际 | 后果 |
|---|---|---|
| DDR 参数未逆 = 最大风险 | **bootROM 已初始化 DDR**，boot0 主体直接被装到 0x80000000 后跳转 | **该风险不存在**，不必逆 |
| bsp 整层要重写（UART/PMIC/eMMC） | UART=0x10038000、eMMC=0x10016000、GPIO 位带已全部拿到 | 工作量砍掉大半 |
| NX300 dnloader 可以当模板 | 它是 NAND + DRIMeIV，NX500 是 eMMC + DRIMe5s | 模板价值仅剩 FatFs + SDHCI 协议 |

### 真正缺的只有一块

| 能力 | boot0 有吗 | dnloader 需要吗 |
|---|---|---|
| UART 输出 | ✅ 0x10038000 / putc 钩子 | ✅ 有现成常量 |
| DDR 初始化 | 不需要（bootROM 做） | 不需要 |
| eMMC 读 | ✅ 0x10016000 + 0x2006f0c | 可选 |
| **SD 卡读** | ❌ 零个 "SD" 字符串 | ✅ **唯一缺口** |
| FAT 文件系统 | ❌ | ✅（FatFs 纯软件可直接编译） |
| 跳转执行 | ✅ load_image + start_a9 | ✅ |
| 交互 shell | ✅ 0x2003f00 | 加分项 |

⇒ **最小 dnloader = UART(已知) + SD 驱动(待挖) + FatFs(纯软件) + 跳转(已知)**。
DDR 与 UART 初始化都已免掉。

---

## 7. 三条路线的真实成本（修正版）

### 路线 A：只想救砖 → 接 UART，进 shell，什么都不用写

成本：一个 3.3V USB-TTL + 找到测试点。
收益：`test flash erase` / `test flash read` / `boot` 三件套立即可用。
**这条路的性价比远高于写 dnloader**，且是后两条的前提。

### 路线 B：让 boot0 走 recovery 分支（不写代码，但要动机器）

`ctrl->[0xC0] == 1` 或四个 GPIO(19/27/30/31) 全低。
前者需要 bootROM 传参，后者疑似就是**维修手册说的"短接 TP"**。
★ 未验证：这两个 GPIO 是否真的对应测试点。

### 路线 C：写最小 dnloader（真正的 L3）

```
1. 从 p13 内核（9.2 MB，符号可能未剥离）挖 SD 控制器基址
   —— drivers/mmc/host/dw_mmc 或 sdhci，搜 compatible / 寄存器宏
2. 移植 FatFs（纯 C，无依赖）
3. 代码骨架：
      uart_putc(0x10038000)          ← 常量已有
      sd_init(基址 TBD)
      f_open("nx500.bin") → 读到 0x86007FC0
      跳 0x86008000（或按 boot0 的 A9 参数区格式 0x86000100）
4. 唯一无法离线验证的两个量：
      - bootROM 把 dnloader 加载到哪（NX300 是 0x70200000，NX500 疑为 0x80000000）
      - bootROM 在 SD 上找什么文件名 / 有无校验
```

---

## 8. 我建议的下手顺序

| 步 | 动作 | 依赖 | 产出 |
|---|---|---|---|
| **1** | 从 p13 解包内核里挖 SD/MMC 驱动基址与寄存器布局 | 纯离线 | `SD 基址 + 初始化序列` |
| **2** | 写 dnloader 骨架（UART + 打印 + 空转），交叉编译出裸 bin | 纯离线 | 可烧的 1 KB stub |
| **3** | 接 UART（USB-TTL + 找测试点），开机狂发 0x0D | **硬件** | 进 shell，`test flash read` 验证 eMMC |
| **4** | 用 shell 验证 dnloader 的加载地址假设（试 0x70200000 / 0x80000000） | 硬件 | 确定加载地址 |
| **5** | 补 SD + FatFs，实测从 SD 加载 p13 并跳 | 硬件 | dnloader 完成 |

★ **第 1、2 步不需要相机、不需要拆机、不需要任何硬件**，现在就能做。
★ 第 3 步是整个计划的分水岭：UART 一通，L3 从"无料"变成"有工具"。

---

## 9. 复现命令

```sh
# 全量反汇编（基址 0x02000000）
dd if=boot0.bin of=/tmp/b0.bin bs=1 count=56289
arm-linux-gnueabi-objdump -D -b binary -m arm --adjust-vma=0x02000000 /tmp/b0.bin > /tmp/b0.dis

# p13 解包
python -c "import zlib;d=open('p13.bin','rb').read();print(len(zlib.decompressobj(31).decompress(d[0x55c0:])))"
```

关键函数索引：

| 地址 | 作用 |
|---|---|
| 0x2000b24 | uart_putc |
| 0x2000c24 | print_string（经 0x0200E424 钩子） |
| 0x2000c60 | printf |
| 0x200aa00 | printf（带 TID 前缀，`[%2d:%5lu.%06lu] I/%-12s (BL%3d):`） |
| 0x20033d8 | boot_reason() |
| 0x2003368 | start_a9(type, addr, size, src) |
| 0x20073bc | load_image(addr, size, src) |
| 0x2006c54 | boot_mode_handshake(1, type) |
| 0x2006f0c | emmc_init() |
| 0x2003f00 | bootloader shell |
| 0x20034d4 | main |
| 0x20049c8 | snapshot/warmboot resume（magic 0x2BEDF00D） |

---

## 10. 未闭合

| # | 项 | 状态 |
|---|---|---|
| 1 | `0x002D4801` / `0x4C4C` 作为 load_image 参数的精确语义 | 疑为 (src_offset, block_count)；0x4C4C×512 = 9.54 MiB ≈ 10M 分区 |
| 2 | `*(0x0200E074)` 控制块的结构布局 | 已知 +0x40/44/48 三参数、+0xc0 模式字节；入口来自 bootROM |
| 3 | 四 GPIO(19/27/30/31) 是否就是维修手册的短接 TP | 未验证 |
| 4 | bootROM 加载 dnloader 的地址与文件名规则 | 未验证（需 UART） |
| 5 | SD 控制器基址 | 待从 p13 内核挖（下一步） |
| 6 | shell 的按键窗口时长 | 10 次轮询无延时，需连发 |
