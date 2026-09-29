#!/usr/bin/env python3
"""Generate the 1024x1024 app icon for 看见Calendar.

Pure numpy + zlib PNG writer: no third-party image libraries required.
Run:  python scripts/make_app_icon.py
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

import numpy as np

SS = 2                      # supersampling factor
SIZE = 1024                 # final icon size in px


def hex_rgb(value: str) -> np.ndarray:
    value = value.lstrip("#")
    return np.array([int(value[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64) / 255.0


class Canvas:
    """Minimal anti-aliased raster painter working on a linear-light-ish RGB buffer."""

    def __init__(self, size: int, background: str):
        self.size = size
        self.rgb = np.zeros((size, size, 3), dtype=np.float64)
        self.rgb[:, :] = hex_rgb(background)
        self._yy, self._xx = np.mgrid[0:size, 0:size]

    def _blend(self, mask: np.ndarray, color: str, alpha: float = 1.0) -> None:
        rgb = hex_rgb(color)
        a = np.clip(mask, 0.0, 1.0) * alpha
        a = a[..., None]
        self.rgb = self.rgb * (1.0 - a) + rgb * a

    def round_rect(self, x0, y0, x1, y1, radius, color, alpha=1.0):
        cy = min(max((y0 + y1) / 2, 0), self.size)
        cx = min(max((x0 + x1) / 2, 0), self.size)
        half_w, half_h = (x1 - x0) / 2, (y1 - y0) / 2
        # signed distance to a rounded rectangle
        dx = np.abs(self._xx - cx) - (half_w - radius)
        dy = np.abs(self._yy - cy) - (half_h - radius)
        dist = np.hypot(np.maximum(dx, 0), np.maximum(dy, 0)) + np.minimum(np.maximum(dx, dy), 0) - radius
        self._blend(0.5 - dist, color, alpha)

    def circle(self, cx, cy, r, color, alpha=1.0):
        dist = np.hypot(self._xx - cx, self._yy - cy) - r
        self._blend(0.5 - dist, color, alpha)

    def disc_soft(self, cx, cy, r, color, alpha=1.0):
        """Feathered dot, used for brush strokes and soft shadows."""
        dist = np.hypot(self._xx - cx, self._yy - cy)
        mask = np.clip((r - dist) + 0.5, 0.0, 1.0)
        self._blend(mask, color, alpha)

    def save_png(self, path: Path) -> None:
        img = (np.clip(self.rgb, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
        height, width, _ = img.shape
        raw = b"".join(b"\x00" + img[y].tobytes() for y in range(height))
        def chunk(tag: bytes, data: bytes) -> bytes:
            return (struct.pack(">I", len(data)) + tag + data
                    + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(raw, 9))
               + chunk(b"IEND", b""))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(png)

    def downsample(self, factor: int) -> "Canvas":
        size = self.size // factor
        block = self.rgb.reshape(size, factor, size, factor, 3).mean(axis=(1, 3))
        out = Canvas.__new__(Canvas)
        out.size = size
        out.rgb = block
        out._yy, out._xx = np.mgrid[0:size, 0:size]
        return out


def build_icon() -> Canvas:
    n = SIZE * SS
    c = Canvas(n, "#F7F2E8")
    u = n / 1024.0  # 1 design unit == 1 pt at 1024

    # warm paper wash
    for i in range(40):
        t = i / 39.0
        c.disc_soft(n * 0.30, n * 0.22, n * (0.55 - 0.35 * t), "#FFFDF7", alpha=0.035)
    c.disc_soft(n * 0.88, n * 0.92, n * 0.55, "#E9DFCC", alpha=0.22)

    # calendar card
    card = (96 * u, 112 * u, 928 * u, 928 * u)
    c.round_rect(card[0] + 10 * u, card[1] + 22 * u, card[2] + 10 * u, card[3] + 26 * u,
                 92 * u, "#C9BCA4", alpha=0.30)                    # soft drop shadow
    c.round_rect(*card, 88 * u, "#FFFFFF", alpha=1.0)
    c.round_rect(*card, 88 * u, "#F3EADA", alpha=0.0)

    # binding bar
    c.round_rect(96 * u, 112 * u, 928 * u, 300 * u, 88 * u, "#2F4858")
    c.round_rect(96 * u, 240 * u, 928 * u, 312 * u, 40 * u, "#2F4858")
    for i in range(7):
        x = 96 * u + (150 + i * 120) * u
        c.round_rect(x - 9 * u, 176 * u, x + 9 * u, 268 * u, 9 * u, "#F7F2E8", alpha=0.92)

    # month grid: 4 rows x 7 columns of 1:1 cells
    left, top = 152 * u, 372 * u
    cell, gap = 96 * u, 19 * u
    accents = {
        (0, 1): "#F0A93B",   # amber
        (0, 4): "#3AA6A0",   # teal
        (1, 2): "#E8615A",   # coral
        (2, 6): "#7C89C9",   # periwinkle
        (3, 0): "#F0A93B",
        (3, 5): "#3AA6A0",
    }
    for row in range(4):
        for col in range(7):
            x0 = left + col * (cell + gap)
            y0 = top + row * (cell + gap)
            x1, y1 = x0 + cell, y0 + cell
            if (row, col) in accents:
                c.round_rect(x0, y0, x1, y1, 26 * u, accents[(row, col)])
                c.round_rect(x0, y0, x1, y0 + cell * 0.42, 26 * u, "#FFFFFF", alpha=0.16)
            else:
                c.round_rect(x0, y0, x1, y1, 26 * u, "#EFE7D8")
                c.round_rect(x0 + 3 * u, y0 + 3 * u, x1 - 3 * u, y1 - 3 * u, 24 * u, "#FFFFFF", alpha=0.75)

    # pencil brush stroke sweeping across the lower-left corner
    pts = []
    for i in range(240):
        t = i / 239.0
        px = (-40 + 620 * t) * u
        py = (1085 - 210 * t - 300 * np.sin(np.pi * t * 0.92)) * u
        pts.append((px, py))
    for i, (px, py) in enumerate(pts):
        t = i / (len(pts) - 1)
        r = (17 * np.sin(np.pi * min(max(t, 0.02), 0.98)) ** 0.45 + 5) * u
        c.disc_soft(px, py, r, "#1F6FB2", alpha=0.94)
    for i, (px, py) in enumerate(pts):
        t = i / (len(pts) - 1)
        r = (7 * np.sin(np.pi * min(max(t, 0.05), 0.95)) ** 0.6 + 2) * u
        c.disc_soft(px - 6 * u, py - 8 * u, r, "#5FA8DC", alpha=0.55)

    return c.downsample(SS)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    target = root / "SeeingCalendar/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
    build_icon().save_png(target)
    print(f"wrote {target} ({target.stat().st_size / 1024:.1f} KiB)")


if __name__ == "__main__":
    main()
