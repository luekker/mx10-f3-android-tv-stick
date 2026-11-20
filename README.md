# MX10 F3 Android TV stick

Notes, serial logs and build files for a cheap Android TV stick from AliExpress, sold as
the "MX10 F3". It came with malware in the system image, so I replaced Android with Armbian
(Debian with a mainline Linux 6.18 kernel), running from the internal eMMC. It's been
repurposed as a micro Linux machine.

If you have one of these sticks, assume the stock firmware is compromised (see [Malware](#malware)).

## Hardware

| Part | Details |
|---|---|
| SoC | Allwinner H313 (sun50iw9p1, H616 family), 4× Cortex-A53 |
| RAM | 1.5 GB LPDDR3 |
| Storage | 7.8 GB eMMC (QN16BB), microSD slot |
| PMIC | X-Powers AXP1530 on I2C at 0x36. It reports chip ID 0x4b, the same as the AXP313A |
| WiFi / Bluetooth | AICSemi AIC8800D80: WiFi 6 over SDIO, Bluetooth 5.4 on UART1 |
| Video | HDMI out |
| Other | Reset button. The stock kernel log also shows an IR receiver and an FD650 LED driver |
| USB | Never showed up as a device on a computer, so there's no ADB, fastboot or FEL over USB |
| Serial | UART0 pads on the board: 115200 8N1, 3.3 V |

What the stock firmware claimed, and what it really was:

| | Claimed | Actually |
|---|---|---|
| Model | Google Pixel 3 ("blueline") | Allwinner H313 TV stick |
| Android | 13 | 10 (SDK 29), userdebug build, kernel 4.9.170 |
| RAM | 8.6 GB | 1.5 GB |

Other findings: SELinux is permissive, ADB over WiFi is open and `adb root` works, and the serial
console gives a shell with no login, where `su` gives root. The bootloader is U-Boot 2018.05
with `bootdelay=0`.

## Malware

- Four preinstalled apps are signed with the platform key and run as the system user:
  `com.soya.store`, `com.android.xinyifa.fota`, `com.oranth.accessibility` (named to look like
  a Netflix component) and `com.xyf313.setup`.
- The "Play Store" (`com.android.vending`) is actually `Tubesky.apk`, signed with a non-Google key
  and allowed to install packages.
- While I was looking at it, `com.soya.store` downloaded and silently installed
  `com.ambientlight.tv`. That app contains ad SDKs and strings for a "hidden mode" and invisible
  clicks.
- The apps use DNS-over-HTTPS, so DNS blocking doesn't stop them.
- Disabling them with `pm disable-user` survived a reboot, and their traffic stopped.

APK hashes are in [`apks/SHA256SUMS`](apks/SHA256SUMS); the APKs themselves aren't included.

## Getting into U-Boot

U-Boot's `bootdelay` was 0 and USB gave nothing, so I used the root shell on the serial console
to change 5 bytes in the U-Boot environment on the eMMC: `bootdelay=3` plus a new CRC32. After a
reboot, U-Boot stops at a prompt. Step by step:
[docs/unlocking-uboot-over-uart.md](docs/unlocking-uboot-over-uart.md).

## Running Linux

Boot chain:

```
boot ROM → stock boot0 → stock BL31 + patched vendor U-Boot 2018.05 → boot.scr
         → Armbian kernel (as a uImage) + initrd + custom device tree
```

The stock boot0 stays, because mainline U-Boot's SPL can't set up this board's RAM. The vendor
U-Boot (Orange Pi's BSP source) is rebuilt with these patches (`linux-prep/build/patches/`):

- `0001`: boot banner
- `0002`: accept the PMIC's chip ID (0x4b)
- `0003`: allow kernels up to 64 MB with `bootm`
- `0004`: use the device tree passed to `bootm` instead of the vendor one
- `0005`: accept an arm64 initrd and leave it where it was loaded
- `0006`: distro boot checks the SD card first, then the eMMC

`config.fragment` sets `bootdelay=3` and removes the USB flashing modes (burn, efex, fastboot).
The vendor U-Boot has no `booti`, so the kernel is wrapped as a legacy uImage and started with
`bootm`.

Changes on the Linux side (`linux-prep/linux/`):

- The device tree is based on mainline's X96Q (H313, LPDDR3) tree, with reserved memory for the
  vendor BL31.
- CPU voltages come from the stock firmware, because mainline's were 100–120 mV low and crashed
  under cpufreq. It runs at 480–1200 MHz; 1512 MHz is removed.
- WiFi uses Radxa's aic8800 driver and firmware, with the SDIO clock capped at 25 MHz. A small
  driver patch makes the driver respect that cap; it forced 150 MHz, which caused data errors.
- The WiFi MAC is fixed (derived from the chip ID), and Bluetooth is attached with `hciattach`
  at 1.5 Mbaud.
- Kernel updates work through apt: the WiFi driver is built with DKMS, and a hook re-wraps each
  new kernel as a uImage.

**Working:** booting from the eMMC, WiFi (tested on 5 GHz), Bluetooth, CPU frequency scaling and kernel
updates. An SD card with a bootable image takes priority over the eMMC, which makes it a handy
rescue card.
**Not done:** IR receiver, LED driver, a fixed Bluetooth address.

## Files

```
apks/SHA256SUMS            hashes of the pulled APKs (APKs not included)
serial/                    serial console logs (see below)
docs/                      how U-Boot was unlocked
linux-prep/
  build/                   Dockerfiles, build scripts, patches, boot package tool, SD image script
  linux/                   device tree, boot script, and files added to the Armbian image
```

Serial logs:

- `boot_20261114.log`: stock boot, from boot0 through U-Boot to the Android console
- `boot_loglevel8.clean.log`: stock kernel boot with verbose logging (hardware detection)
- `bootdelay3_boot.log`: U-Boot stopping at its prompt after the `bootdelay` change
- `emmc_boot3.log`: first boot of U-Boot and Armbian from the eMMC, through to the login prompt

## Building

I built everything on an Apple Silicon Mac with Docker. `make-sdcard.sh` chroots into an arm64
filesystem, so on x86 you also need `qemu-user-static`. These inputs aren't in the repo:

| Input | Source | Goes in `linux-prep/` |
|---|---|---|
| Vendor U-Boot | [orangepi-xunlong/u-boot-orangepi](https://github.com/orangepi-xunlong/u-boot-orangepi), branch `v2018.05-sun50iw9`, commit `2730962` | `u-boot-sun50iw9/` |
| AIC8800 driver and firmware | [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800), commit `5562c25` | `vendor-src/aic8800-radxa/` |
| SD card boot0 | [orangepi-build](https://github.com/orangepi-xunlong/orangepi-build) `external/packages/pack-uboot/sun50iw9/bin/boot0_sdcard_new.fex` | used to make `images/boot0-opinew-mx10.bin` |
| Stock boot files | your own stick's eMMC: boot0 at 8 KiB and the boot package at 16400 KiB, split into `u-boot.bin`, `monitor.bin`, `dtb.bin` and `dtbo.bin` (the format is described in `build/sunxi_pack.py`) | `bootchain/` (plus `package_stock.bin`) |
| Armbian | Armbian community build for the Orange Pi Zero3, trixie minimal, `26.11.0-trunk.130` (kernel 6.18.63) | `armbian/` (decompressed `.img`) |
| Kernel headers | `linux-headers-current-sunxi64` `26.11.0-trunk.133` from Armbian's apt repo | `kernel-headers/` |

```sh
cd linux-prep && mkdir -p images
docker build -t mx10-uboot-build -f build/Dockerfile build
docker build -t mx10-kmod-build  -f build/Dockerfile.kmod build

# U-Boot: vendor source + build/patches + build/config.fragment -> build/out/u-boot.bin
docker run --rm -v "$PWD/u-boot-sun50iw9:/work/src:ro" -v "$PWD/build:/work/build" \
  mx10-uboot-build sh /work/build/build-uboot.sh
# Boot package: new U-Boot plus the stock BL31, dtb and dtbo
python3 build/sunxi_pack.py pack build/out/u-boot.bin bootchain images/package-mx10.bin
# SD card boot0: Orange Pi's boot0 with this stick's RAM settings copied in
python3 build/sunxi_pack.py boot0hdr boot0_sdcard_new.fex bootchain/boot0_emmc.bin images/boot0-opinew-mx10.bin

# Device tree
dtc -I dts -O dtb -o linux/sun50i-h313-mx10.dtb linux/sun50i-h313-mx10.dts
# WiFi driver source for DKMS, then the SD card image (images/sdcard-lu3ker-armbian.img)
docker run --rm -v "$PWD:/w" mx10-kmod-build sh /w/build/prepare-aic8800-dkms.sh 5562c25-lu3ker1
docker run --rm --privileged -v "$PWD:/w" mx10-uboot-build sh /w/build/make-sdcard.sh
```

Write the image to an SD card and boot with the serial console connected. The stick tries the
SD card before the eMMC, so this doesn't change anything on the stick.

To move to the eMMC, starting from the system running on the SD card:

1. Back up the whole eMMC. FEL over USB doesn't work on this stick, so an SD card and the
   serial console are the only ways to recover it.
2. Leave the stock boot0 at 8 KiB as it is, and write `images/package-mx10.bin` at 16400 KiB.
3. Create an MBR partition table with one Linux partition starting at sector 65536 (32 MiB),
   and format it as ext4.
4. Copy the running system onto it with rsync, then set the new partition's UUID in
   `/etc/fstab` and as `rootdev` in `/boot/armbianEnv.txt`.
5. Power off, remove the SD card and boot.

## Not included

- eMMC backups (they contain the original Android data)
- The malware APKs (hashes only)
- Vendor and third-party binaries: stock boot files, Orange Pi boot0, WiFi firmware and modules,
  the Armbian image and kernel headers. Get them from the sources above
- Personal details: LAN addresses are changed to `192.168.1.x`, and WiFi names, MAC addresses,
  serial numbers and UUIDs are replaced with placeholders. The serial logs are plain text (line
  endings and terminal colour codes removed), and WiFi scans and passwords are taken out

## Credits

[Armbian](https://www.armbian.com/), [linux-sunxi](https://linux-sunxi.org/), Orange Pi
(BSP U-Boot and boot0), Radxa (AIC8800 driver packaging), and the authors of the mainline
H313 / X96Q device tree this one is based on.

## License

MIT (see [LICENSE](LICENSE)), except for the patches, which keep the license of the code they
modify:

- `linux-prep/build/patches/` (U-Boot): GPL-2.0+
- `linux-prep/build/aic8800-patches/` (AIC8800 driver): GPL

The device tree is based on the mainline X96Q tree (GPL-2.0+ or MIT). Use this on hardware you
own, at your own risk.
