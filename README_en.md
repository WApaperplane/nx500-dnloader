# NX500 bootloader anatomy + dnloader skeleton

> Samsung NX500 (DRIMe5s) `dnloader.bin` has never been released. It is the only
> gate to **Main PCB Recovery** (service manual §7-6), and the reason a bricked
> NX500 is normally unrecoverable.
>
> This repo does **not** port another model. It reverse-engineers the camera's
> **own `boot0.bin`** and provides: ① a complete hardware constant table
> ② boot0's boot dispatch logic ③ a 912-byte position-independent dnloader
> skeleton, verified by actually running it in QEMU.

中文: [README.md](README.md)

---

## 1. Bottom line

| Question | Answer |
|---|---|
| Do we need to port NX300's bootloader source? | **No.** boot0 already has everything except an SD driver |
| Do we need to reverse DRAM parameters? | **No.** bootROM already initialized DRAM (boot0's stub does `mov pc,#0x80000000`) |
| UART base? | **0x10038000**, ARM PL011, 115200 8N1 |
| SD controller? | **0x08800000** (DesignWare MMC) |
| SD card power pin? | **GPIO 179** (boot0 raises it right before entering recovery) |
| Can boot0 load a kernel by itself? | **Yes.** The recovery branch *is* `load_image(0x86007FC0, …) + jump to A9` |
| Is there an existing recovery tool? | **Yes.** boot0 has a built-in shell — send a CR on UART during boot, commands include `test flash read/erase` |

---

## 2. What the skeleton is

A 912-byte bare-metal binary whose **only job is to answer three unknowns**:

| Output line | Question answered |
|---|---|
| `[dn] load addr : 0x........` | Where bootROM actually loaded it (previously completely unknown) |
| `[dn] CR / FR / IBRD` | Is the UART clocked and initialized? |
| Any output at all | Does bootROM accept this file format? |

One power cycle settles all three at once: format accepted, load address, UART alive.
That is worth far more than a hello-world.

### Three hard constraints

1. **Position independent** — load address unknown, so there is **no absolute
   address anywhere** in the code. Every address = `r4` (runtime `_start`) +
   link-time offset.
2. **No stack** — `SP` is not trustworthy when bootROM jumps in. QEMU showed
   `SP = 0x00000000`; a single `push` would fault. Everything is passed in registers.
3. **Full UART re-initialization** — never assume bootROM configured it;
   re-initializing is idempotent and harmless.

### Header is byte-identical to boot0

```
000000  07 00 00 ea   ← b 0x24        (same as NX500 boot0.bin)
000020  00 00 00 02   ← 0x02000000
000024  13 00 02 f1   ← cps #0x13     (same as boot0)
```

Deliberately mimics boot0's stub layout to maximize the chance of being accepted.

---

## 3. Verified in QEMU (passed)

```sh
cd src && sh run_qemu_test.sh
```

Actual output:

```
=== NX500 dnloader skeleton v0.2 ===
[dn] load addr : 0x60100000      ← linked at 0, ran at 0x60100000: PIC works
[dn] cpsr      : 0x600001d3      ← SVC mode, IRQ/FIQ masked
[dn] sp        : 0x00000000      ← SP is 0, proving the no-stack design is required
[dn] --- uart self-check ---
[dn] CR        : 0x00000301      ← TXE|RXE|UARTEN
[dn] FR        : 0x00000090      ← TXFE|RXFE
[dn] IBRD      : 0x00000036      ← 54, written value reads back
[dn] heartbeat: ..........
```

Tested on `vexpress-a9` (Cortex-A9 / ARMv7 — same architecture as the camera),
with only the UART base swapped to `0x10009000`. Raw output in
`evidence/qemu_test_output.txt`.

---

## 4. Not yet verified (honest list)

| Item | Status | Why |
|---|---|---|
| Real hardware load/execute | ❌ | Needs UART (micro-USB or test point); author has no such setup |
| What filename bootROM looks for on SD | ❌ | Undocumented; service manual says `dnloader.bin` |
| Whether load address is 0x02000000 | ❌ | The skeleton is designed to *print* this |
| SD card init | ❌ | Skeleton has UART only, no SD driver yet |
| Whether GPIO 19/27/30/31 are the TP short points | ❌ | Not verified against hardware |

**The value here is turning "completely blank" into "one power-cycle experiment away".**

---

## 5. Layout

```
├── src/
│   ├── dnloader_skeleton.S    ← assembly source (912 B output)
│   ├── build.sh               ← cross-compile → dnloader.bin
│   ├── run_qemu_test.sh       ← QEMU regression test
│   └── dnloader.bin           ← drop this in the SD card root
├── docs/
│   ├── HW_CONSTANTS.md        ← ★ full hardware constant table (dual-source verified)
│   └── BOOT0_ANATOMY.md       ← full boot0 dissection (Chinese)
└── evidence/
    └── qemu_test_output.txt
```

---

## 6. Reproduce

```sh
# requires arm-linux-gnueabi-gcc
cd src
sh build.sh          # → dnloader.bin, 912 B
sh run_qemu_test.sh  # → live QEMU output
```

Disassemble your own boot0 (4 MiB dump):

```sh
dd if=boot0.bin of=/tmp/b0.bin bs=1 count=56289
arm-linux-gnueabi-objdump -D -b binary -m arm \
    --adjust-vma=0x02000000 /tmp/b0.bin > /tmp/b0.dis
```

★ The base `0x02000000` is not a guess: every string literal in the image is of
the form `0x0200xxxx`.
★ The main body starts at **partition offset 0x200** (56,289 B), i.e. SLP `img1 boot0@512`.

---

## 7. Credits & warning

- Hardware constants come from the official NX500 GPL source
  (`arch/arm/mach-drime5/`) and from independently disassembling this camera's
  own `boot0.bin`; points where both agree are marked `[both]`.
- **Writing the eMMC boot partition can permanently brick the camera.** This repo
  contains static analysis and a read-only probe only — no write path.
  Back up `boot0` / `boot1` / `p1` first.
- Specifically: **p1 (adj calibration: IQ/VFPN/shading/bad-pixel) is the one
  partition that neither the firmware package nor anything else can regenerate.**
  Back it up first, and keep three copies.
