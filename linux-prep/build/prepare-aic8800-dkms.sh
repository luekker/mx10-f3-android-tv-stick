#!/bin/sh
# Produce a DKMS source tree for the AIC8800 SDIO driver: Radxa source + their patch
# series (SDIO hunks must apply) + Lu3ker patches. Run in mx10-kmod-build, linux-prep at /w.
# Usage: prepare-aic8800-dkms.sh <version>   → /w/linux/dkms/aic8800-sdio-lu3ker-<version>/
set -e
VER="$1"; OUT=/w/linux/dkms/aic8800-sdio-lu3ker-$VER
rm -rf /tmp/aic && cp -a /w/vendor-src/aic8800-radxa /tmp/aic && cd /tmp/aic
while read -r p; do
  case "$p" in ''|'#'*) continue;; esac
  patch -s -p1 -f --no-backup-if-mismatch < "debian/patches/$p" >/dev/null 2>&1 || true
  if [ -n "$(find src/SDIO -name '*.rej')" ]; then echo "SDIO hunk rejected in $p"; exit 1; fi
  find src -name '*.rej' -delete
done < debian/patches/series
for p in /w/build/aic8800-patches/*.patch; do patch -s -p1 --no-backup-if-mismatch < "$p"; done
rm -rf "$OUT" && mkdir -p "$OUT" && cp -a src/SDIO/driver_fw/driver/aic8800/. "$OUT"/
cat > "$OUT/dkms.conf" <<CONF
PACKAGE_NAME="aic8800-sdio-lu3ker"
PACKAGE_VERSION="$VER"
MAKE[0]="make -C \$kernel_source_dir M=\$dkms_tree/\$PACKAGE_NAME/\$PACKAGE_VERSION/build modules"
CLEAN="make -C \$kernel_source_dir M=\$dkms_tree/\$PACKAGE_NAME/\$PACKAGE_VERSION/build clean"
BUILT_MODULE_NAME[0]="aic8800_bsp"
BUILT_MODULE_LOCATION[0]="aic8800_bsp"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="aic8800_fdrv"
BUILT_MODULE_LOCATION[1]="aic8800_fdrv"
DEST_MODULE_LOCATION[1]="/updates/dkms"
BUILT_MODULE_NAME[2]="aic8800_btlpm"
BUILT_MODULE_LOCATION[2]="aic8800_btlpm"
DEST_MODULE_LOCATION[2]="/updates/dkms"
AUTOINSTALL="yes"
CONF
echo "$OUT: $(du -sh "$OUT" | cut -f1)"
