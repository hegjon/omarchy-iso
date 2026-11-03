#!/usr/bin/env python3
"""Draw the Omarchy logo's text (/usr/share/omarchy/logo.txt) as a PNG, the
way the live console draws it in the boot logo's font: every character a
cell SCALE pixels wide and twice that high, █ the whole cell, ▀ its upper
half and ▄ its lower half (console-font.py's half blocks and Terminus's full
block, ter-v20b: whole and exact halves of its 10x20 cells), in COLOUR on a
transparent background. GRUB's menu shows it where the boot's logo comes
after it (builder/boot-menu-theme.sh), so the two are the same pixels.

Usage: logo-png.py LOGO.TXT SCALE COLOUR OUTPUT.PNG    (COLOUR as #rrggbb)
"""

import struct
import sys
import zlib
from pathlib import Path

HALVES = {" ": (False, False), "▀": (True, False), "▄": (False, True), "█": (True, True)}


def pixels(lines: list[str]) -> list[list[bool]]:
    """The logo's half cells, two rows of them a line, as wide as its widest line."""
    width = max(len(line) for line in lines)
    rows: list[list[bool]] = []
    for number, line in enumerate(lines, 1):
        unknown = sorted(set(line) - set(HALVES))
        if unknown:
            raise SystemExit(f"line {number} has {''.join(unknown)!r}, which the console draws in its font, not as blocks")
        cells = [HALVES[c] for c in line.ljust(width)]
        rows += [[upper for upper, _ in cells], [lower for _, lower in cells]]
    return rows


def png(rows: list[list[bool]], scale: int, colour: tuple[int, int, int]) -> bytes:
    width, height = len(rows[0]) * scale, len(rows) * scale
    ink, clear = bytes(colour) + b"\xff", b"\0\0\0\0"
    raw = b"".join(b"\0" + b"".join((ink if lit else clear) * scale for lit in row)
                   for row in rows for _ in range(scale))

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    # 8-bit RGBA: GRUB's PNG reader takes it (not a colormap, which it rejects).
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(__doc__.rsplit("\n\n", 1)[1])
    source, scale, colour, output = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    if len(colour) != 7 or colour[0] != "#":
        raise SystemExit(f"colour {colour!r} is not #rrggbb")
    lines = Path(source).read_text(encoding="utf-8").splitlines()
    if not lines:
        raise SystemExit(f"{source} is empty")
    Path(output).write_bytes(png(pixels(lines), scale, tuple(bytes.fromhex(colour[1:]))))


if __name__ == "__main__":
    main()
