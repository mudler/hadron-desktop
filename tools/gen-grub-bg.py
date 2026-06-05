#!/usr/bin/env python3
"""Generate the Tokyo Night GRUB background image.

Emits an uncompressed 24-bit TGA — GRUB's most reliably decoded image format.
(GRUB's png.mod rejects perfectly valid PNGs with "unsupported format", which
cascades to gfxmenu discarding the whole theme; tga.mod decodes cleanly.) Output
is a dark Tokyo Night backdrop (vertical #1a1b26 -> #16161e gradient with a faint
blue glow up top), chosen to sit well behind the light menu text. Stdlib only, so
no Pillow/ImageMagick in the build. Regenerate with:

    python3 tools/gen-grub-bg.py rootfs/etc/kairos/branding/hadron-theme/background.tga
"""
import struct
import sys

W, H = 1280, 800

# Tokyo Night anchors.
TOP = (0x1A, 0x1B, 0x26)      # bg
BOT = (0x16, 0x16, 0x1E)      # bg_dark
GLOW = (0x7A, 0xA2, 0xF7)     # blue accent for the top glow


def lerp(a, b, t):
    return int(a + (b - a) * t + 0.5)


def build_pixels():
    cx, cy = W * 0.5, -H * 0.15          # glow centre, slightly above the frame
    radius = H * 0.95
    px = bytearray()
    for y in range(H):
        ty = y / (H - 1)
        base = (lerp(TOP[0], BOT[0], ty),
                lerp(TOP[1], BOT[1], ty),
                lerp(TOP[2], BOT[2], ty))
        for x in range(W):
            dx, dy = x - cx, y - cy
            d = (dx * dx + dy * dy) ** 0.5
            g = max(0.0, 1.0 - d / radius) ** 2 * 0.18   # subtle, capped
            r = min(255, lerp(base[0], GLOW[0], g))
            gr = min(255, lerp(base[1], GLOW[1], g))
            b = min(255, lerp(base[2], GLOW[2], g))
            px += bytes([b, gr, r])                       # TGA stores BGR
    return bytes(px)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "background.tga"
    # TGA header: uncompressed true-colour (type 2), 24-bit, top-left origin (0x20).
    header = (bytes([0, 0, 2, 0, 0, 0, 0, 0])
              + struct.pack("<HH", 0, 0)
              + struct.pack("<HH", W, H)
              + bytes([24, 0x20]))
    with open(out, "wb") as f:
        f.write(header)
        f.write(build_pixels())
    print(f"wrote {out} ({18 + W * H * 3} bytes, {W}x{H})")


if __name__ == "__main__":
    main()
