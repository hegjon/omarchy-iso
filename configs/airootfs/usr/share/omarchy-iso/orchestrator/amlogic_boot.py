"""Keep the Amlogic bootloader at the start of the install disk.

Amlogic SoCs (the S905 and every generation after it) boot from the start of
the eMMC's user area: the BootROM reads the signed bootloader, BL2 and the
FIP behind it, from the first sectors of the disk, and on a TV box that is
the only bootloader there is. The image leaves bytes 440-511 of sector 0 free
so that an MBR fits around it: a disk signature, four partition entries and
55AA. A GPT does not fit: its header goes to sector 1 and its entries to
sectors 2-33. archinstall also zeroes the disk's first KiB before it
partitions, and parted zeroes sectors 0-18 of a disk it gives a new label.
After a stock install such a box no longer starts from its eMMC.

A disk carrying the bootloader is recognised by the header magic of the
signed image, "@AML", 16 bytes into sector 1: GXL, GXM, G12 and SM1 load the
image from sector 1 on. GXBB (S905, ODROID-C2) reads sector 0 as well, so its
image has the header 16 bytes into sector 0 too, around the MBR. Either one
counts, unless sector 1 is a GPT header: then the image is gone already.

On such a disk the install gets an MBR and writes only that MBR's own bytes
(440-511) below its first partition. The first partition starts where the
disk's existing MBR starts its first one, the room the bootloader is known to
fit in, but at least at 1 MiB (archinstall's alignment, and where the
configurator puts it anyway) and at most at 4 MiB: Amlogic's own eMMC layout
reserves 0-4 MiB for the bootloader, so no image is larger. A disk without an
MBR keeps all 4 MiB.

Everything here reads the disk O_RDONLY, except write_mbr and clear_tail,
which write the descriptor they are given.
"""

from __future__ import annotations

import os
import struct
from dataclasses import dataclass
from pathlib import Path

MAGIC = b"@AML"
# (offset, what keeps an image there)
MAGIC_OFFSETS = ((512 + 16, "sector 1"), (16, "sector 0 (GXBB)"))
GPT_HEADER = b"EFI PART"

MIB = 1024 * 1024
MIN_RESERVE = MIB
MAX_RESERVE = 4 * MIB

BOOT_CODE_END = 440
MBR_SIGNATURE_OFFSET = 440
ENTRIES_OFFSET = 446
MBR_MAGIC = b"\x55\xaa"
PROTECTIVE_GPT = 0xEE
TYPE_ESP = 0xEF
TYPE_LINUX = 0x83
TYPE_SWAP = 0x82
# parted zeroes this much at the end of a disk it gives a new label, which
# takes a stale GPT backup header with it (ped_disk_clobber). The MBR written
# here does the same at the end, and nothing at the start.
TAIL_CLEAR_BYTES = 9 * 1024


@dataclass(frozen=True)
class MbrEntry:
    slot: int  # 1-4
    boot: bool
    type: int
    start: int  # in logical sectors
    sectors: int


@dataclass(frozen=True)
class BootArea:
    """The bootloader's part of a disk: bytes 0-439 and 512 up to `reserve`,
    as they were when the install found them (`head`)."""

    disk: str
    reserve: int
    head: bytes
    found_at: str

    def ranges(self) -> tuple[tuple[int, int], ...]:
        return ((0, BOOT_CODE_END), (512, self.reserve))

    def changed_ranges(self, current: bytes) -> list[tuple[int, int]]:
        """The ranges of the bootloader's bytes that `current`, the disk's
        first bytes read again, no longer has as they were."""
        return [(lo, hi) for lo, hi in self.ranges() if current[lo:hi] != self.head[lo:hi]]

    def describe(self) -> str:
        return (
            f"{self.disk} carries an Amlogic bootloader (\"@AML\" in {self.found_at}): "
            f"partitioning it with an MBR from {self.reserve // MIB} MiB on, and keeping "
            f"bytes 0-439 and 512-{self.reserve - 1} as they are"
        )


def read_head(disk: str | Path, length: int) -> bytes:
    """The first `length` bytes of `disk`, or fewer if it is shorter. O_RDONLY,
    so closing it sets off no udev re-read."""
    fd = os.open(disk, os.O_RDONLY | os.O_CLOEXEC)
    try:
        chunks: list[bytes] = []
        offset = 0
        while offset < length:
            chunk = os.pread(fd, length - offset, offset)
            if not chunk:
                break
            chunks.append(chunk)
            offset += len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def _entry(sector0: bytes, slot: int) -> MbrEntry:
    raw = sector0[ENTRIES_OFFSET + 16 * (slot - 1):ENTRIES_OFFSET + 16 * slot]
    boot, ptype, start, sectors = raw[0], raw[4], *struct.unpack_from("<II", raw, 8)
    return MbrEntry(slot, boot == 0x80, ptype, start, sectors)


def mbr_entries(sector0: bytes) -> list[MbrEntry] | None:
    """The used primary entries of the MBR in `sector0`; None if it holds
    no MBR (no 55AA)."""
    if len(sector0) < 512 or sector0[510:512] != MBR_MAGIC:
        return None
    entries = (_entry(sector0, slot) for slot in range(1, 5))
    return [entry for entry in entries if entry.type and entry.sectors]


def found_at(head: bytes) -> str | None:
    """Where `head`, a disk's first KiB, has the bootloader's header; None
    if it has none. Header magic 16 bytes into sector 0 alone does not count
    with a GPT header in sector 1: that overwrote the rest of the image, and
    the disk is a GPT disk like any other."""
    found = []
    for offset, where in MAGIC_OFFSETS:
        if head[offset:offset + len(MAGIC)] == MAGIC:
            if offset < 512 and head[512:512 + len(GPT_HEADER)] == GPT_HEADER:
                continue
            found.append(where)
    return " and ".join(found) or None


def _round_up(value: int, unit: int) -> int:
    return -(-value // unit) * unit


def reserve_bytes(sector0: bytes, sector_size: int = 512) -> int:
    """Where the first partition may start on a disk with the bootloader:
    where its MBR starts its first one, rounded up to MiB, between 1 MiB and
    4 MiB; 4 MiB without an MBR (or with only a protective one)."""
    entries = [entry for entry in mbr_entries(sector0) or () if entry.type != PROTECTIVE_GPT]
    if not entries:
        return MAX_RESERVE
    first = min(entry.start for entry in entries) * sector_size
    return min(MAX_RESERVE, max(MIN_RESERVE, _round_up(first, MIB)))


def logical_sector_size(disk: str | Path) -> int:
    name = Path(os.path.realpath(disk)).name
    try:
        return int(Path(f"/sys/class/block/{name}/queue/logical_block_size").read_text())
    except (OSError, ValueError):
        return 512


def detect(disk: str | Path) -> BootArea | None:
    """The bootloader's area on `disk`, or None when it has no Amlogic
    bootloader, or cannot be opened (it does not exist: the cleanup that
    comes next says so)."""
    try:
        head = read_head(disk, 1024)
    except FileNotFoundError:
        return None
    where = found_at(head)
    if where is None:
        return None
    reserve = reserve_bytes(head[:512], logical_sector_size(disk))
    return BootArea(str(disk), reserve, read_head(disk, reserve), where)


def verify_kept(boot_area: BootArea) -> str:
    """Raise if the bootloader's bytes on the disk changed since the install
    found them: the machine would no longer start from it. Returns a line
    for the log saying they did not."""
    changed = boot_area.changed_ranges(read_head(boot_area.disk, boot_area.reserve))
    if changed:
        raise RuntimeError(
            f"the Amlogic bootloader on {boot_area.disk} was overwritten (bytes "
            + ", ".join(f"{lo}-{hi - 1}" for lo, hi in changed)
            + "); this machine would not start from it"
        )
    return f"the Amlogic bootloader on {boot_area.disk} is intact (bytes 0-439 and 512-{boot_area.reserve - 1})"


# ── the partition layout ────────────────────────────────────────────────────

_UNITS = {"B": 1, "KiB": 1024, "MiB": MIB, "GiB": 1024 * MIB, "TiB": 1024 * 1024 * MIB}


def _size_bytes(size: dict) -> int:
    unit = size.get("unit")
    value = size.get("value")
    if type(value) is not int:
        raise RuntimeError(f"partition size {size!r} is not a whole number")
    if unit == "sectors":
        return value * (size.get("sector_size") or {}).get("value", 512)
    if unit not in _UNITS:
        raise RuntimeError(f"partition size unit {unit!r} is not one this installer moves")
    return value * _UNITS[unit]


def _set_bytes(size: dict, value: int) -> None:
    size["unit"] = "B"
    size["value"] = value


def _same_disk(a: str | None, b: str) -> bool:
    return bool(a) and os.path.realpath(a) == os.path.realpath(b)


def fit_layout(disk_config: dict, disk: str, reserve: int) -> int:
    """Move the partitions archinstall is to create on `disk` (in an
    archinstall disk_config, as the configurator writes it) so the first
    starts at `reserve`, taking the room from the last one. Returns how many
    bytes they moved: 0 when the first one starts there or later already."""
    for modification in disk_config.get("device_modifications") or ():
        if not _same_disk(modification.get("device"), disk):
            continue
        partitions = sorted(
            (part for part in modification.get("partitions") or () if part.get("status") == "create"),
            key=lambda part: _size_bytes(part["start"]),
        )
        if not partitions:
            return 0
        shift = reserve - _size_bytes(partitions[0]["start"])
        if shift <= 0:
            return 0
        last = partitions[-1]
        last_size = _size_bytes(last["size"]) - shift
        if last_size < MIB:
            raise RuntimeError(
                f"{disk} has no room for its partitions behind the Amlogic bootloader's {reserve} bytes"
            )
        for part in partitions:
            _set_bytes(part["start"], _size_bytes(part["start"]) + shift)
        _set_bytes(last["size"], last_size)
        return shift
    return 0


# ── the MBR ─────────────────────────────────────────────────────────────────

def _chs(lba: int) -> bytes:
    """An LBA as the CHS triple of a 255-head, 63-sector geometry, as fdisk
    writes it; 1023/254/63 beyond what CHS can address. Linux and U-Boot read
    the LBA fields."""
    cylinder = lba // (255 * 63)
    if cylinder > 1023:
        return b"\xfe\xff\xff"
    head = lba // 63 % 255
    sector = lba % 63 + 1
    return bytes((head, sector | ((cylinder >> 2) & 0xC0), cylinder & 0xFF))


def pack_entry(entry: MbrEntry) -> bytes:
    if not 1 <= entry.slot <= 4:
        raise RuntimeError(f"an MBR has primary partitions 1-4, not {entry.slot}")
    if entry.start < 1 or entry.sectors < 1 or entry.start + entry.sectors > 1 << 32:
        raise RuntimeError(
            f"partition {entry.slot} (start {entry.start}, {entry.sectors} sectors) "
            "is beyond what an MBR addresses"
        )
    return struct.pack(
        "<B3sB3sII",
        0x80 if entry.boot else 0,
        _chs(entry.start),
        entry.type,
        _chs(entry.start + entry.sectors - 1),
        entry.start,
        entry.sectors,
    )


def mbr_tail(sector0: bytes, entries: list[MbrEntry], new_signature: bytes | None = None) -> bytes:
    """Bytes 440-511 of a sector 0 holding `entries`: the disk signature
    `sector0` has (a new one if it has none, as parted and fdisk give a disk,
    since a PARTUUID is made of it), its bytes 444-445, the four entries and
    55AA."""
    signature = sector0[MBR_SIGNATURE_OFFSET:MBR_SIGNATURE_OFFSET + 4]
    if signature == b"\0\0\0\0":
        signature = new_signature or _random_signature()
    table = bytearray(64)
    for entry in entries:
        table[16 * (entry.slot - 1):16 * entry.slot] = pack_entry(entry)
    return signature + sector0[444:446] + bytes(table) + MBR_MAGIC


def _random_signature() -> bytes:
    while (signature := os.urandom(4)) == b"\0\0\0\0":
        pass
    return signature


def write_mbr(fd: int, entries: list[MbrEntry]) -> bytes:
    """Write an MBR holding `entries` to the disk open on `fd`: bytes
    440-511 of sector 0 and nothing else. Returns the bytes written."""
    sector0 = os.pread(fd, 512, 0)
    if len(sector0) < 512:
        raise RuntimeError("the disk is shorter than one sector")
    tail = mbr_tail(sector0, entries)
    if os.pwrite(fd, tail, MBR_SIGNATURE_OFFSET) != len(tail):
        raise RuntimeError("short write of the MBR")
    return tail


def clear_tail(fd: int, disk_bytes: int, sector_size: int, used_end: int) -> bool:
    """Zero the disk's last sectors, as parted does when it labels a disk,
    so no stale GPT backup header outlives the new MBR; only when no
    partition reaches them (`used_end`, in bytes). True if it did."""
    length = (TAIL_CLEAR_BYTES // sector_size + 1) * sector_size
    start = disk_bytes - length
    if start < used_end or start < MAX_RESERVE:
        return False
    if os.pwrite(fd, bytes(length), start) != length:
        raise RuntimeError("short write clearing the end of the disk")
    return True
