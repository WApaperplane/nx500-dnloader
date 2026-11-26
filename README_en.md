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

## 0. Closed-Case Recovery Discovery: Unbrick NX500 Without Disassembly

By correlating this repository's `boot0` recovery-branch disassembly (GPIOs `19`, `27`, `30`, `31`) with Samsung's official NX500 GPL kernel definitions (`include/gpio_map_nx500.h`), a previously undocumented **built-in firmware recovery mode** has been independently identified and verified on real **Samsung NX500** hardware (recovering a camera soft-bricked after `nx-on-wake`—also applicable to `systemctl rescue` and similar soft bricks).

**Recovery button combination (no disassembly, no motherboard shorting, no UART, no `downloader.bin`):**

1. Place an official, unmodified `nx500.bin` firmware file (for example v1.12) in the root of a clean **FAT32** SD card.
2. Remove the battery, insert the SD card, flip the display **fully upward into the selfie position**, and reinsert the battery (power switch OFF).
3. Hold **MOBILE (Wi-Fi)** + **AEL** + **full Shutter** simultaneously, then switch the camera **ON**.
4. Release the buttons when the **Recovery Mode** menu appears (`F/W Check` / `Update` / `Update Finish`), then **hold the shutter button** as prompted to flash `nx500.bin`.

> **Warnings and distinction from `downloader.bin`:**
> - **Use official, unmodified firmware only**, use a charged battery, and **never interrupt power** during `Updating / Do not power off.` until `Update Finish` completes.
> - **Verified scope:** Confirmed end-to-end on a soft-bricked **NX500** through `Update Finish` and normal reboot. **Not verified on the NX1** or other Samsung NX cameras (different GPIO map, no flip-up screen).
> - **Closed-case `boot0`/`rImage` recovery vs. Boot ROM `downloader.bin` recovery:** This button combination invokes `boot0`'s built-in `rImage` recovery path and resolves soft bricks where `boot0` and `rImage` remain intact. Boot ROM / Main PCB Recovery using `downloader.bin` (or the UART bootloader shell) is still needed only if `boot0` itself is damaged or cannot boot.

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
| Whether GPIO 19/27/30/31 are the TP short points | ✅ | **Verified as external controls** (`WIFI` + `AEL` + `Shutter2` + `Flip-up selfie screen`); triggers closed-case `rImage` recovery with official `nx500.bin` (NX500 verified, NX1 unverified) |

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
│   ├── UART_ACCESS.md         ← ★ UART access status: micro-USB route disproven, pad route open
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
