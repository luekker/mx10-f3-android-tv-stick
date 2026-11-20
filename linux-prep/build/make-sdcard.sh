#!/bin/sh
# Build the Lu3ker + Armbian SD image. Run in a --privileged mx10-uboot-build container
# with linux-prep mounted at /w. Output: /w/images/sdcard-lu3ker-armbian.img
# Optional overrides: L = linux/ tree to use, NS = internal name
# prefix of paths/units/DKMS package, OUT = image, PRESET_USER = first-run username preset.
set -e
L=${L:-/w/linux}
NS=${NS:-lu3ker}
apt-get -qq update >/dev/null && apt-get -qq install -y e2fsprogs rsync fdisk kmod >/dev/null 2>&1
SRC=/w/armbian/Armbian_community_26.11.0-trunk.130_Orangepizero3_trixie_current_6.18.63_minimal.img
OUT=${OUT:-/w/images/sdcard-lu3ker-armbian.img}
UUID=6414b359-3b2a-4b9c-a387-0d31c3e6d4ee
P1=65536                      # root partition at 32 MiB, clear of boot0 (8 KiB) and package (16400 KiB)
SIZE_MB=3072
rm -f "$OUT"; truncate -s ${SIZE_MB}M "$OUT"
printf 'label: dos\nstart=%s, type=83, bootable\n' "$P1" | sfdisk -q "$OUT"
# boot0 + boot package (sdimg layout), written over the image without touching the MBR
dd if=/w/images/boot0-opinew-mx10.bin of="$OUT" bs=1k seek=8 conv=notrunc status=none
dd if=/w/images/package-mx10.bin of="$OUT" bs=1k seek=16400 conv=notrunc status=none
# root filesystem
LOOP=$(losetup -f --show -o $((P1*512)) "$OUT")
mkfs.ext4 -q -U "$UUID" -L armbi_root "$LOOP"
mkdir -p /src /dst
mount -o ro,loop,offset=$((8192*512)) "$SRC" /src
mount "$LOOP" /dst
rsync -aHAX /src/ /dst/
# Lu3ker boot files
mkimage -A arm -O linux -T kernel -C none -a 0x40200000 -e 0x40200000 -n "Armbian 6.18.63 (Lu3ker)" -d /src/boot/Image /dst/boot/uImage >/dev/null
mkdir -p /dst/boot/$NS && cp $L/sun50i-h313-mx10.dtb /dst/boot/$NS/
cp /dst/boot/boot.cmd /dst/boot/boot.cmd.armbian; cp /dst/boot/boot.scr /dst/boot/boot.scr.armbian
cp $L/boot.cmd /dst/boot/boot.cmd
mkimage -A arm -O linux -T script -C none -n "Lu3ker boot" -d /dst/boot/boot.cmd /dst/boot/boot.scr >/dev/null
# Lu3ker identity and safety overlay (linux/overlay): hostname, MOTD header, apt pins, WiFi blacklist
rsync -a --chown=0:0 $L/overlay/ /dst/
sed -i 's/orangepizero3/lu3ker/g' /dst/etc/hosts
sed -i 's/^BOARD_NAME=.*/BOARD_NAME="MX10 F3 (H313) - Lu3ker"/' /dst/etc/armbian-release /dst/etc/armbian-image-release
# AIC8800D80 WiFi/BT: out-of-tree driver as DKMS (build/prepare-aic8800-dkms.sh), so it is
# rebuilt for each new kernel. Headers are the exact build of the image kernel, built in a chroot.
KVER=6.18.63-current-sunxi64
DKMS=$(basename $L/dkms/aic8800-sdio-$NS-*)
DKMS_REF=aic8800-sdio-$NS/${DKMS#aic8800-sdio-$NS-}   # name/version
cp -a $L/dkms/$DKMS /dst/usr/src/ && chown -R root:root /dst/usr/src/$DKMS
cp /w/kernel-headers/linux-headers-current-sunxi64_26.11.0-trunk.133_arm64__*.deb /dst/tmp/hdr.deb
for d in proc sys dev dev/pts; do mount --bind /$d /dst/$d; done
cp /etc/resolv.conf /dst/tmp/resolv.conf
[ -f $L/bench-packages.txt ] && cp $L/bench-packages.txt /dst/tmp/
chroot /dst sh -ec "
  mount --bind /tmp/resolv.conf /etc/resolv.conf 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update
  apt-get -qq install -y --no-install-recommends dkms make gcc libc6-dev bison flex libssl-dev libelf-dev >/dev/null
  dpkg -i /tmp/hdr.deb >/dev/null
  dkms add $DKMS_REF >/dev/null
  dkms install $DKMS_REF -k $KVER | tail -2
  # Bench helper tools (optional linux/bench-packages.txt), plus pipx tools not packaged in Debian
  if [ -f /tmp/bench-packages.txt ]; then
    grep -v '^#' /tmp/bench-packages.txt | xargs apt-get -qq install -y --no-install-recommends >/dev/null
    for p in ubi_reader jefferson pyftdi mpremote; do pipx install --global -q \$p >/dev/null; done
  fi
  # Offline docs store (optional): upstream docs, datasheets, man text, tldr (guides come from the overlay)
  if [ -x /usr/local/sbin/$NS-docs-update ]; then
    /usr/local/sbin/$NS-docs-update | grep -E 'FAIL|^[0-9.]+[MG]' || true
    pdftotext -layout /opt/$NS-docs/device/uboot-lesson.pdf /opt/$NS-docs/device/uboot-lesson.txt
  fi
  apt-get clean
  umount /etc/resolv.conf 2>/dev/null || true
  rm -f /tmp/hdr.deb /tmp/resolv.conf /tmp/bench-packages.txt"
for d in dev/pts dev sys proc; do umount /dst/$d; done
modinfo -b /dst -k $KVER -F vermagic aic8800_fdrv
# Radxa's SDIO firmware, versioned with the driver, at the path it loads from (as their
# aic8800-firmware package installs it). Armbian's set lacks the D80 "_h_" variant this chip needs.
mkdir -p /dst/lib/firmware/aic8800_fw/SDIO
rsync -a --exclude '*.7z' /w/vendor-src/aic8800-radxa/src/SDIO/driver_fw/fw/ /dst/lib/firmware/aic8800_fw/SDIO/
sed -i '/^sprdbt_tty$/d' /dst/etc/modules   # Zero3 BSP autoload of the UWE5622 BT stack
# Armbian first-run wizard: preset the username (passwords and WiFi are still asked)
if [ -n "${PRESET_USER:-}" ]; then
  echo "PRESET_USER_NAME=$PRESET_USER" >> /dst/root/.not_logged_in_yet
  echo "first-run preset: $(grep PRESET_ /dst/root/.not_logged_in_yet | tr '\n' ' ')"
fi
echo "identity: $(cat /dst/etc/hostname) / $(grep ^BOARD_NAME /dst/etc/armbian-release)"
sync; grep -q "$UUID" /dst/etc/fstab && echo "fstab uses root UUID: ok"
ls -l /dst/boot/uImage /dst/boot/boot.scr /dst/boot/$NS/sun50i-h313-mx10.dtb
df -h /dst | tail -1
umount /dst /src; losetup -d "$LOOP"
sfdisk -l "$OUT" | tail -2
