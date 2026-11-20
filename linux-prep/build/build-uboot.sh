#!/bin/sh
# Build the vendor sun50iw9 U-Boot inside the mx10-uboot-build container.
# Usage (from linux-prep/): docker run --rm -v "$PWD/u-boot-sun50iw9:/work/src:ro" -v "$PWD/build:/work/build" \
#        mx10-uboot-build sh /work/build/build-uboot.sh <defconfig>
set -e
DEFCONFIG=${1:-orangepi_zero2_defconfig}
rm -rf /tmp/src && cp -a /work/src /tmp/src && cd /tmp/src
# Vendor tree bug: host mkimage references fit_region_make_list() (image-sig.c), which is only
# linked with FIT_SIGNATURE. Stub it for the host tools; we never sign FIT images.
printf '#include <stddef.h>\nvoid *fit_region_make_list(const void *f, void *r, int c, void *o) { return NULL; }\nvoid *image_get_checksum_algo(const char *n) { return NULL; }\nvoid *image_get_crypto_algo(const char *n) { return NULL; }\n' > tools/fit_sig_stub.c
sed -i 's/^\t\t\tatmelimage.o \\$/\t\t\tatmelimage.o fit_sig_stub.o \\/' tools/Makefile
for p in /work/build/patches/*.patch; do [ -f "$p" ] && patch -p1 --no-backup-if-mismatch < "$p"; done
rm -rf /work/build/out
make CROSS_COMPILE=arm-linux-gnueabi- O=/work/build/out "$DEFCONFIG" >/dev/null
[ -f /work/build/config.fragment ] && cat /work/build/config.fragment >> /work/build/out/.config && \
  make CROSS_COMPILE=arm-linux-gnueabi- O=/work/build/out olddefconfig >/dev/null
make CROSS_COMPILE=arm-linux-gnueabi- O=/work/build/out HOSTCFLAGS=-fcommon KCFLAGS="-Wno-error -fcommon" -j"$(nproc)" > /work/build/build.log 2>&1 || { tail -30 /work/build/build.log; exit 1; }
ls -l /work/build/out/u-boot.bin
