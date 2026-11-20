# Lu3ker boot script: Armbian (mainline arm64) via the vendor 32-bit U-Boot.
# No booti here: the kernel is a legacy uImage and bootm hands it to the vendor
# BL31, which switches to AArch64. Addresses avoid the vendor BL31 at 0x48000000.
# CPU DVFS works with the vendor speed4 voltages in sun50i-h313-mx10.dtb (480-1200 MHz).
# The DTB lives in /boot/lu3ker, outside Armbian's versioned /boot/dtb-<kver>, so kernel
# updates keep it; etc/kernel/postinst.d/zz-lu3ker-uimage rewraps each new kernel.
# Loads from whichever device distro boot found this script on (SD = mmc 0, eMMC = mmc 2);
# the root filesystem comes from rootdev in that device's /boot/armbianEnv.txt.
echo "Lu3ker: loading Armbian from ${devtype} ${devnum}:${distro_bootpart}"
setenv rootdev "UUID=6414b359-3b2a-4b9c-a387-0d31c3e6d4ee"
if load ${devtype} ${devnum}:${distro_bootpart} 0x4FA00000 /boot/armbianEnv.txt; then
	env import -t 0x4FA00000 ${filesize}
fi
setenv bootargs "console=ttyS0,115200n8 earlycon=uart,mmio32,0x05000000 root=${rootdev} rootfstype=ext4 rootwait loglevel=7"
ext4load ${devtype} ${devnum}:${distro_bootpart} 0x52000000 /boot/uImage
ext4load ${devtype} ${devnum}:${distro_bootpart} 0x4FA00000 /boot/lu3ker/sun50i-h313-mx10.dtb
ext4load ${devtype} ${devnum}:${distro_bootpart} 0x4FF00000 /boot/uInitrd
# Older custom U-Boot builds don't grow the FDT themselves; harmless on newer ones.
fdt addr 0x4FA00000
fdt resize 65536
bootm 0x52000000 0x4FF00000 0x4FA00000
