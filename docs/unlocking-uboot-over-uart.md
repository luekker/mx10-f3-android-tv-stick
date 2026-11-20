# Unlocking U-Boot over UART

*MX10 F3 (Allwinner H313), 14 Nov 2026. Bootloader: U-Boot 2018.05 (Allwinner BSP).
Serial adapter: Bus Pirate 5.*

How we got from a sealed Android TV stick to a live bootloader prompt using a Bus Pirate 5,
three wires, and a five-byte edit, and why each step worked.

## Why a bootloader prompt matters

U-Boot runs before Linux or Android exists. If you can stop it and type commands, you control
what the board boots: you can load a kernel from an SD card, read and write memory, inspect
storage, and recover a board whose operating system no longer starts. On most cheap TV boxes
the prompt is hidden. The vendor sets the autoboot countdown to zero so U-Boot goes straight
to Android.

## The boot chain on this stick

Every stage loads the next. We read all of them on the serial console, and **U-Boot** is
where we wanted to stop.

| Stage | What it does |
|---|---|
| BROM | Mask ROM inside the chip. Picks SD, then eMMC, else USB FEL. Silent on serial. |
| BOOT0 | "HELLO! BOOT0 is starting!" Sets clocks, trains 1536 MB of LPDDR3. |
| BL3-1 | ARM Trusted Firmware (built 2021-03-18). Secure monitor, then exits to normal world. |
| **U-Boot** | Loads its env from the eMMC, counts down `bootdelay`, runs `bootcmd`. |
| Kernel | Linux 4.9.170, quiet because `loglevel=0`. |
| Android | Drops the console to `console:/ $` with no login. |

## 1. Get a serial console

The SoC prints every boot stage on UART0 at 115200 baud, 8 data bits, no parity, 1 stop bit
(8N1). Those are 3.3 V logic signals on pads near the chip. A USB-to-UART bridge turns them
into a terminal on the Mac, and the Bus Pirate 5 can be that bridge.

| Bus Pirate 5 | Stick | Why |
|---|---|---|
| `10 GND` | GND | A shared reference. Without it the voltages mean nothing. |
| `7 IO5 (RX)` | TX | Transmit crosses to receive: the stick talks, the BP listens. |
| `6 IO4 (TX)` | RX | The BP talks, the stick listens. Needed to send keys. |
| `1 Vout` | not connected | The BP's own 3.3 V supply powers its IO buffers instead. |

> **The Vout detail.** The BP5's IO pins pass through level-shifting buffers, and those
> buffers take their voltage from the Vout pin. The stick had no 3.3 V pin to borrow, so we
> turned on the BP5's supply at 3.3 V with a 50 mA current limit and left Vout unconnected.
> The buffers got their reference, and no power could flow into the stick.

```
HiZ>  m            # mode menu → 3. UART, 115200 8N1, no flow control
UART> W 3.3 50     # 3.3 V reference, 50 mA limit
UART> bridge       # transparent pass-through; exit with the BP button
```

From then on the Mac's serial port was effectively the stick's console. A short Python script
with pyserial sent keystrokes and saved everything to log files, so nothing scrolled away.

## 2. Read the boot log

The first capture already told us what we were up against:

```
[00.709]Loading Environment from SUNXI_FLASH... OK
[00.736]usb burn from boot
[01.557]do_burn_from_boot usb : no usb exist
Hit any key to stop autoboot:  0
[02.253]Starting kernel ...
...
console:/ $
```

Two findings: the countdown is zero, and Android leaves an unauthenticated shell on the console.

The countdown line comes from the `bootdelay` variable. "Loading Environment from
SUNXI_FLASH" tells us where that variable lives: in a settings area on the eMMC that U-Boot
reads at every boot.

## 3. The attempts that failed

Before editing anything we tried every way of getting in that wrote nothing. Each failure
narrowed the options.

- **Failed: spamming keys during power-on.** A script sent spaces non-stop from before
  power-on until the kernel started. With `bootdelay=0` this vendor U-Boot never caught the
  input and booted straight through.
- **Failed: holding the reset button.** Boot was identical. The env shows U-Boot checks a key
  line for recovery (values 0x10–0x13) and fastboot (0x2–0x8), but the button evidently isn't
  wired to it. No key was ever logged.
- **Failed: USB to the Mac.** U-Boot waits about 0.8 s for a USB host to enter its flashing
  mode, but always reported `no usb exist`, and no device ever appeared on the Mac. The port
  behaves as power-only.
- **Misread: the "silent" boots.** Two reset-held boots printed nothing at all, which looked
  like the chip's FEL mode. They were really the stick not running: its adapter was feeding
  power into the Mac, which played its charging chime. A boot powered only from the Mac proved
  it. When a result looks exciting, check that the device was powered.

## 4. Find the setting, offline

Earlier in the project we had taken a full eMMC image. That meant we could study the
bootloader's settings on the Mac without touching the stick.

### Locate the partition

The image starts with a GUID Partition Table. Reading its entries gave us the layout, and
partition 2 (index 1) is named `env`:

```
 0 bootloader   first=73728   size=32768KiB
 1 env          first=139264  size=16384KiB
 2 boot         first=172032  size=32768KiB
 3 super        first=237568  size=3389440KiB
...
```

### Decode the format

A U-Boot environment is a simple structure: a 4-byte CRC32 checksum, then `name=value`
strings, each ending in a zero byte, with a double zero after the last one. The rest of the
block is padding. The partition is 16 MB, but the env block inside it is much smaller. We
found its exact size by computing the CRC over several candidate sizes until one matched the
stored checksum: 0x20000 bytes (128 KiB).

```
┌──────────┬──────────────────────────────────────┬──────────────────┐
│ CRC32    │ name=value\0name=value\0…\0\0        │ zero padding     │
│ 4 bytes  │ bootdelay=0 at offset 1214           │ up to 0x20000    │
│ offset 0 │                                      │                  │
└──────────┴──────────────────────────────────────┴──────────────────┘
```

The checksum covers everything after it, so changing any variable means recomputing it.

```
console=ttyS0,115200
loglevel=0
selinux=0
boot_normal=sunxi_flash read 45000000 boot;bootm 45000000
recovery_key_value_max=0x13
fastboot_key_value_max=0x8
bootdelay=0
bootcmd=run setargs_nand boot_normal
```

## 5. Build the patch

We changed `bootdelay=0` to `bootdelay=3`. That's one character, so the string length doesn't
change and nothing else in the block moves. Then we recomputed the CRC32 over the block.
Comparing old and new images byte by byte:

```
offset   old  new
     0    32   4f   ┐
     1    cd   3f   │ new CRC32
     2    32   25   │
     3    ba   7c   ┘
  1224    30   33   '0' → '3'
```

Five bytes in total. The full original and patched 128 KiB images were saved with SHA-256
hashes (as `backup/partitions/env_orig_128k.img` and `env_bootdelay3_128k.img`; device
backups are not part of this repo).

## 6. Apply it safely

The serial shell runs as the `shell` user, but this is a userdebug build with SELinux set to
permissive, so `su` gave root immediately. Root can write the raw eMMC partition. Each step
had a guard:

1. **Check before writing.** We hashed the first 128 KiB of `/dev/block/mmcblk0p2` on the
   stick. It matched the backup (`6fbb95aa…`), so our offsets were correct for this device. A
   mismatch would have stopped everything.
2. **Stage the bytes and inspect them.** We wrote the five bytes to temp files and dumped them
   with `od` (`4f 3f 25 7c 33`). We also read offset 1214 back to confirm it said
   `bootdelay=0`.
3. **Write in place.** We used `dd … conv=notrunc` at exact offsets, so it overwrote those
   bytes and nothing else.
4. **Check the result on disk.** We ran `sync`, dropped the page cache so the read came from
   the eMMC rather than memory, and hashed again: `ecd0c2c0…`, identical to the patched image.

```
console:/ # dd if=/data/local/tmp/d.bin   of=/dev/block/mmcblk0p2 bs=1 seek=1224 count=1 conv=notrunc
console:/ # dd if=/data/local/tmp/crc.bin of=/dev/block/mmcblk0p2 bs=1 seek=0    count=4 conv=notrunc
console:/ # sync; echo 3 > /proc/sys/vm/drop_caches
console:/ # dd if=/dev/block/mmcblk0p2 bs=131072 count=1 | sha256sum
ecd0c2c077f09a4832327eaf451845a783d02b83533612a13242c786d83f549f
```

## 7. Reboot and catch it

The script sent `reboot`, then sent spaces until it saw the prompt:

```
Hit any key to stop autoboot:  3 ^H^H^H 0
=> version
U-Boot 2018.05 (Sep 02 2026 - 15:52:47 +0800) Allwinner Technology
=> printenv bootdelay
bootdelay=3
```

The help listing shows what's now in reach: `fatload` and `sunxi_card0_probe` for SD cards,
`loady` to upload files over the serial line itself, `md`/`mw` to read and write memory, and
`fdt` to edit device trees. There's no `booti`, so a raw arm64 kernel needs wrapping for
`bootm`, or booting through the SD card's own U-Boot.

## Why it worked

- **The bootloader trusts its env.** U-Boot reads `bootdelay` from the eMMC on every boot and
  checks only the CRC, not a signature. A valid CRC is all it takes for the setting to be
  accepted.
- **A CRC isn't protection.** A CRC detects accidental corruption. Anyone can recompute it,
  so it doesn't stop deliberate changes. Only a cryptographic signature would.
- **Root in the OS means control of the boot.** The running system can write the partition
  the bootloader reads. Root on Android became control over U-Boot on the next boot.
- **The console was the way in.** An unauthenticated shell on UART, a userdebug build and
  permissive SELinux turned three wires into root. Production devices usually close all three.

> **To undo it:** write the original 128 KiB env image back to `mmcblk0p2`, or just the same
> five bytes, with the same hash check before and after. Leaving `bootdelay=3` in place only
> adds a three-second pause to each boot.

---

The boot logs from before and after the change are
[`serial/boot_20261114.log`](../serial/boot_20261114.log) and
[`serial/bootdelay3_boot.log`](../serial/bootdelay3_boot.log).
