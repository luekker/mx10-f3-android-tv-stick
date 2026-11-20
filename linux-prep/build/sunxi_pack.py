#!/usr/bin/env python3
"""Pack an Allwinner (sun50iw9 BSP) boot package and SD-card boot image.

Formats, as reverse-engineered from the stock MX10 F3 eMMC and checked by
re-packing the stock parts byte-for-byte (`selftest`):

  Checksum: sum of all little-endian u32 words, with the checksum field
  temporarily set to the stamp 0x5F0A6C39. Used by boot0, u-boot and the package.

  u-boot.bin header: 0x0c checksum, 0x10 align (0x4000), 0x14 length,
  0x18 uboot_length; the image is zero-padded to a multiple of align.

  boot package ("sunxi-package"): 0x10 magic 0x89119800, 0x14 checksum,
  0x20 item count, 0x24 valid length; item table at 0x40, 0x170 bytes per item
  (name[64], data_offset, data_len, ...). Item data is 0x400-aligned, and the
  total is padded to 0x4000.

  SD/eMMC layout: boot0 at 8 KiB, boot package at 16400 KiB (sector 32800).

Usage:
  sunxi_pack.py selftest <stock_dir> <stock_package.bin>
  sunxi_pack.py pack <u-boot.bin> <stock_dir> <out_package.bin>
  sunxi_pack.py boot0hdr <blank_boot0> <filled_boot0> <out_boot0>
  sunxi_pack.py sdimg <boot0.bin> <package.bin> <out.img>
"""
import struct
import sys

STAMP = 0x5F0A6C39
PKG_ITEMS = ("u-boot", "monitor", "dtbo", "dtb")


def checksum(buf, field):
    b = bytearray(buf)
    struct.pack_into("<I", b, field, STAMP)
    return sum(struct.unpack(f"<{len(b) // 4}I", b)) & 0xFFFFFFFF


def align(n, a):
    return (n + a - 1) // a * a


def fix_uboot(raw):
    """Pad u-boot.bin and fill its length and checksum fields."""
    if raw[4:9] != b"uboot":
        raise SystemExit("u-boot.bin has no 'uboot' header magic")
    a = struct.unpack_from("<I", raw, 0x10)[0] or 0x4000
    b = bytearray(raw) + bytes(align(len(raw), a) - len(raw))
    struct.pack_into("<II", b, 0x14, len(b), len(b))
    struct.pack_into("<I", b, 0x0C, checksum(b, 0x0C))
    return bytes(b)


def pack(template, parts):
    """Build a package reusing the stock header/item table as a template."""
    hdr = bytearray(template[:0x40 + 0x170 * len(PKG_ITEMS)])
    first = struct.unpack_from("<I", hdr, 0x40 + 64)[0]
    off, body = first, bytearray()
    for i, name in enumerate(PKG_ITEMS):
        e = 0x40 + i * 0x170
        if hdr[e:e + 64].split(b"\0")[0].decode() != name:
            raise SystemExit(f"template item {i} is not {name}")
        data = parts[name]
        struct.pack_into("<II", hdr, e + 64, off, len(data))
        body += bytes(off - first - len(body)) + data
        off = align(off + len(data), 0x400)
    total = align(first + len(body), 0x4000)
    pkg = hdr + bytes(first - len(hdr)) + body
    pkg += bytes(total - len(pkg))
    struct.pack_into("<I", pkg, 0x24, total)
    struct.pack_into("<I", pkg, 0x14, checksum(pkg, 0x14))
    return bytes(pkg)


def read(p):
    with open(p, "rb") as f:
        return f.read()


def load_parts(stock_dir, uboot):
    parts = {n: read(f"{stock_dir}/{n}.bin") for n in PKG_ITEMS}
    parts["u-boot"] = uboot
    return parts


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "selftest":
        stock_dir, stock_pkg = argv[2], read(argv[3])
        ub = read(f"{stock_dir}/u-boot.bin")
        assert fix_uboot(ub) == ub, "u-boot header recompute differs from stock"
        valid = struct.unpack_from("<I", stock_pkg, 0x24)[0]
        out = pack(stock_pkg, load_parts(stock_dir, ub))
        assert out == stock_pkg[:valid], "repacked package differs from stock"
        print(f"selftest OK: u-boot header and {valid:#x}-byte package reproduce stock exactly")
    elif cmd == "pack":
        ub = fix_uboot(read(argv[2]))
        stock_dir = argv[3]
        template = read(f"{stock_dir}/package_stock.bin")
        out = pack(template, load_parts(stock_dir, ub))
        with open(argv[4], "wb") as f:
            f.write(out)
        print(f"wrote {argv[4]}: {len(out):#x} bytes, u-boot {len(ub):#x}, "
              f"checksum {struct.unpack_from('<I', out, 0x14)[0]:#010x}")
    elif cmd == "boot0hdr":
        # Copy a filled boot0 private header (debug/power mode, DRAM params, UART,
        # JTAG, storage GPIOs and storage data: 0x34-0x2f8) into a blank boot0.
        tmpl, donor = bytearray(read(argv[2])), read(argv[3])
        for b in (tmpl, donor):
            if b[4:12] != b"eGON.BT0" or struct.unpack_from("<I", b, 0x30)[0] != 0:
                raise SystemExit("unexpected boot0 header layout")
        tmpl[0x34:0x2F8] = donor[0x34:0x2F8]
        struct.pack_into("<I", tmpl, 0x0C, checksum(tmpl[:struct.unpack_from("<I", tmpl, 0x10)[0]], 0x0C))
        with open(argv[4], "wb") as f:
            f.write(tmpl)
        print(f"wrote {argv[4]}: {len(tmpl):#x} bytes, checksum {struct.unpack_from('<I', tmpl, 0x0C)[0]:#010x}")
    elif cmd == "sdimg":
        boot0, pkg = read(argv[2]), read(argv[3])
        if boot0[4:12] != b"eGON.BT0" or pkg[:13] != b"sunxi-package":
            raise SystemExit("bad boot0 or package magic")
        img = bytearray(16400 * 1024 + len(pkg))
        img[8192:8192 + len(boot0)] = boot0
        img[16400 * 1024:] = pkg
        with open(argv[4], "wb") as f:
            f.write(img)
        print(f"wrote {argv[4]}: {len(img)} bytes (boot0 @ 8 KiB, package @ 16400 KiB)")
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
