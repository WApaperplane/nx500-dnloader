/*
 * NX500 dnloader skeleton  v0.2
 * ----------------------------------------------------------------------------
 * 目的：一次回答三个未知，全部纯软件、无需相机即可编译验证。
 *
 *   Q1  bootROM 认不认这个文件？      → 有输出 = 认
 *   Q2  bootROM 把它加载到哪个地址？  → 直接打印自身 PC
 *   Q3  UART 通不通、时钟给没给？      → 读回 CR/FR/IBRD 三个寄存器
 *
 * 设计约束（全部为了"加载地址未知"这一件事）：
 *   - 位置无关：无绝对地址引用；地址一律 = r4(运行时 _start) + 链接期偏移
 *   - 不用栈：bootROM 跳过来时 SP 不可信，全部靠寄存器传值
 *   - UART 完整重初始化（幂等）：不假设 bootROM 已经配好
 *
 * 寄存器约定（每个函数允许破坏的寄存器都列明，避免互相踩）：
 *   r4  = _start 运行时地址     永久，任何函数都不许写
 *   r6  = UART 基址 0x10038000  永久，任何函数都不许写
 *   putc     : 破坏 r1
 *   puts     : 破坏 r0 r1 r5 r12（r12 存 lr，r5 存字符串指针）
 *   put_hex32: 破坏 r0 r3 r7 r8 （r7 存 lr，r8 存值，r3 存移位）
 *   delay    : 破坏 r0
 *
 * 硬件事实（均取自 NX500 自身，非推测）：
 *   UART     = 0x10038000   ARM PL011, 115200 8N1
 *              +0x00 DR  +0x18 FR(bit5=TXFF bit6=RXFF)  +0x24 IBRD  +0x28 FBRD
 *              +0x2C LCR_H  +0x30 CR  +0x34 IFLS  +0x38 IMSC  +0x48 DMACR
 *   PERI_CON = 0x101FF000   +0x1C = UART_CLK_RESET
 *   分频值取自 boot0.bin 0x2000ba4 / 0x2000bc8 的实际写入：
 *               IBRD=54 FBRD=16 LCR_H=0x60 IMSC=0x12 IFLS=0x1F0 CR=0x300|1
 *
 * 头部布局刻意与 NX500 boot0.bin 一致（可逐字节对照）：
 *   0x00 b 0x24 ; 0x04..0x1C b hang ; 0x20 .word 0x02000000 ; 0x24 cps #0x13
 *   0x20 那个 0x02000000 若被执行恰是 `andeq r0,r0,r0`（无害 NOP）。
 *
 * 构建：sh build.sh
 * 部署：放 SD 卡根目录文件名 dnloader.bin（维修手册 Main PCB Recovery）
 * ----------------------------------------------------------------------------
 */

    .syntax unified
    .arch   armv7-a
    .arm

/*
 * QEMU 回归测试用：vexpress-a9(Cortex-A9/ARMv7) 的 PL011 在 0x10009000，
 * 其 +0x1C 是保留寄存器，写 UART_CLK_RESET 无副作用，可原样跑同一份代码。
 */
#ifdef QEMU_TEST
    .equ UART_BASE,    0x10009000
    .equ PERI_CON,     0x10009000
#else
    .equ UART_BASE,    0x10038000
    .equ PERI_CON,     0x101FF000
#endif
    .equ U_DR,         0x00
    .equ U_FR,         0x18
    .equ U_IBRD,       0x24
    .equ U_FBRD,       0x28
    .equ U_LCRH,       0x2C
    .equ U_CR,         0x30
    .equ U_IFLS,       0x34
    .equ U_IMSC,       0x38
    .equ U_DMACR,      0x48
    .equ PERI_URST,    0x1C
    .equ FR_TXFF,      (1 << 5)

/*
 * ADR_PI —— 位置无关地取符号地址
 *   ARM 的 adr 只吃 8 位可旋转立即数，字符串偏移大多落不进去；
 *   movw 也不接受符号差值。所以用字面量池存"相对 _start 的偏移"
 *   （ABS32 重定位，链接期求值），运行时再加 r4。
 *   宏内标签用 \@ 保证唯一，不与外部数字标签冲突。
 */
    .macro  ADR_PI reg, sym
    ldr     \reg, .Lpiv\@
    add     \reg, r4, \reg
    b       .Lpia\@
.Lpiv\@:
    .word   (\sym - _start)
.Lpia\@:
    .endm

/* 直接读寄存器的地址常量（非符号），movw/movt 即可 */
    .macro  LDCONST reg, val
    movw    \reg, #(\val & 0xFFFF)
    movt    \reg, #(((\val) >> 16) & 0xFFFF)
    .endm

    .section .text.start, "ax"
    .global _start

/* ============================ 向量表 + 头 ============================ */
_start:
    b       reset                   /* 0x00  reset         */
    b       hang                    /* 0x04  undef         */
    b       hang                    /* 0x08  svc           */
    b       hang                    /* 0x0c  prefetch abt  */
    b       hang                    /* 0x10  data abt      */
    b       hang                    /* 0x14                */
    b       hang                    /* 0x18  irq           */
    b       hang                    /* 0x1c  fiq           */
    .word   0x02000000              /* 0x20  boot0 同款填充值 */

/* ================================ 入口 =============================== */
reset:
    cps     #0x13                   /* SVC，同时关 A/I/F */
    cpsid   if

    adr     r4, _start              /* r4 = 运行时 _start 地址（汇编器算 pc-8） */
    LDCONST r6, UART_BASE           /* r6 = UART 基址，全程常驻 */

/* ========================== UART 初始化（PL011） ====================== */
    mov     r1, #0
    str     r1, [r6, #U_CR]         /* 先整体关掉 */

    LDCONST r2, PERI_CON
    mov     r1, #2
    str     r1, [r2, #PERI_URST]    /* 释放 UART 复位 */

    mov     r1, #54
    str     r1, [r6, #U_IBRD]
    mov     r1, #16
    str     r1, [r6, #U_FBRD]
    mov     r1, #0x60
    str     r1, [r6, #U_LCRH]       /* 8N1 */
    mov     r1, #0x12
    str     r1, [r6, #U_IMSC]
    mov     r1, #0x1F0
    str     r1, [r6, #U_IFLS]
    mov     r1, #0
    str     r1, [r6, #U_DMACR]
    mov     r1, #0x300
    str     r1, [r6, #U_CR]         /* TXE | RXE */
    orr     r1, r1, #1
    str     r1, [r6, #U_CR]         /* |= UARTEN */

/* ================================ 输出 =============================== */
    ADR_PI  r0, s_banner
    bl      puts

    ADR_PI  r0, s_addr              /* ★ Q2 的答案 */
    bl      puts
    mov     r0, r4
    bl      put_hex32
    ADR_PI  r0, s_nl
    bl      puts

    ADR_PI  r0, s_cpsr
    bl      puts
    mrs     r0, cpsr
    bl      put_hex32
    ADR_PI  r0, s_nl
    bl      puts

    ADR_PI  r0, s_sp
    bl      puts
    mov     r0, sp
    bl      put_hex32
    ADR_PI  r0, s_nl
    bl      puts

    ADR_PI  r0, s_hdr               /* UART 自检 */
    bl      puts

    ADR_PI  r0, s_ucr
    bl      puts
    ldr     r0, [r6, #U_CR]
    bl      put_hex32
    ADR_PI  r0, s_nl
    bl      puts

    ADR_PI  r0, s_ufr
    bl      puts
    ldr     r0, [r6, #U_FR]
    bl      put_hex32
    ADR_PI  r0, s_nl
    bl      puts

    ADR_PI  r0, s_uib
    bl      puts
    ldr     r0, [r6, #U_IBRD]
    bl      put_hex32
    ADR_PI  r0, s_nl
    bl      puts

    ADR_PI  r0, s_ok
    bl      puts

/* ============================== 心跳 ================================ */
    mov     r9, #0                  /* 心跳计数（puts/put_hex32 都不碰 r9） */
heartbeat:
    ADR_PI  r0, s_dot
    bl      puts
    add     r9, r9, #1
    and     r0, r9, #0x3F           /* 每 64 拍换行，避免刷屏 */
    cmp     r0, #0
    bne     hb_tick
    ADR_PI  r0, s_nl
    bl      puts
hb_tick:
    LDCONST r0, 0x10000000          /* 2.68e8 次循环 ≈ 0.9 s @600MHz */
    bl      delay
    b       heartbeat

hang:
    b       hang

/* ============================== 工具函数 ============================= */

/* putc: r0 = 字符；破坏 r1；叶子函数，不碰 lr */
putc:
1:  ldr     r1, [r6, #U_FR]
    tst     r1, #FR_TXFF
    bne     1b
    str     r0, [r6, #U_DR]
    bx      lr

/* puts: r0 = NUL 结尾字符串；破坏 r0 r1 r5 r12 */
puts:
    mov     r12, lr
    mov     r5, r0
1:  ldrb    r0, [r5], #1
    cmp     r0, #0
    beq     2f
    bl      putc
    b       1b
2:  mov     pc, r12

/* put_hex32: r0 = 值；输出 "0x"+8 位小写 hex；破坏 r0 r3 r7 r8 */
put_hex32:
    mov     r7, lr
    mov     r8, r0
    ADR_PI  r0, s_hexpre
    bl      puts
    mov     r3, #28
1:  mov     r0, r8, lsr r3
    and     r0, r0, #0xF
    cmp     r0, #10
    addlo   r0, r0, #0x30           /* '0'..'9' */
    addhs   r0, r0, #0x57           /* 'a'..'f' */
    bl      putc
    subs    r3, r3, #4
    bpl     1b
    mov     pc, r7

/* delay: r0 = 循环次数；破坏 r0 */
delay:
    subs    r0, r0, #1
    bne     delay
    bx      lr

/* ============================== 字符串 ============================== */
    .balign 4
s_banner:
    .asciz "\r\n\r\n=== NX500 dnloader skeleton v0.2 ===\r\n"
s_addr:
    .asciz "[dn] load addr : "
s_cpsr:
    .asciz "[dn] cpsr      : "
s_sp:
    .asciz "[dn] sp        : "
s_hdr:
    .asciz "[dn] --- uart self-check ---\r\n"
s_ucr:
    .asciz "[dn] CR        : "
s_ufr:
    .asciz "[dn] FR        : "
s_uib:
    .asciz "[dn] IBRD      : "
s_ok:
    .asciz "[dn] heartbeat:\r\n"
s_nl:
    .asciz "\r\n"
s_dot:
    .asciz "."
s_hexpre:
    .asciz "0x"
