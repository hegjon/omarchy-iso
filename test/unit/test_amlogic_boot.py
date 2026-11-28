"""Keeping an Amlogic bootloader at the start of the install disk.

orchestrator.amlogic_boot recognises the bootloader by its "@AML" header
(16 bytes into sector 1, and into sector 0 on GXBB), picks where the first
partition may start, moves the configurator's layout behind it, and writes an
MBR into bytes 440-511 alone. The fixtures are synthetic: the header magic at
the offsets the real Minix NEO U1 (S905, GXBB) eMMC has it, its partition
table, and filler bytes wherever the vendor's signed image would be.
"""

from __future__ import annotations

import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import amlogic_boot as ab  # noqa: E402

MIB = 1024 * 1024
GIB = 1024 * MIB
SIGNATURE = struct.pack("<I", 0x6D696E78)  # the Minix's label-id


def filler(length: int, seed: int = 0) -> bytes:
    """Recognisable non-zero bytes standing in for the signed image."""
    return bytes((index * 7 + seed) % 251 + 1 for index in range(length))


def mbr_entry(boot: bool, ptype: int, start: int, sectors: int) -> bytes:
    return struct.pack("<B3sB3sII", 0x80 if boot else 0, b"\0\0\0", ptype, b"\0\0\0", start, sectors)


def minix_table() -> bytes:
    """Bytes 440-511 of the Minix's sector 0: dos, label-id 0x6d696e78, p1
    start=2048 size=4194304 type=ef bootable, p2 start=4196352 type=83."""
    entries = mbr_entry(True, 0xEF, 2048, 4194304) + mbr_entry(False, 0x83, 4196352, 26578944)
    return SIGNATURE + b"\0\0" + entries + bytes(32) + b"\x55\xaa"


def amlogic_head(length: int = 4 * MIB, *, sector0_magic=True, sector1_magic=True, table: bytes | None = None) -> bytearray:
    head = bytearray(filler(length))
    if sector0_magic:
        head[16:20] = b"@AML"
    if sector1_magic:
        head[528:532] = b"@AML"
    head[440:512] = minix_table() if table is None else table
    return head


class Disk:
    """A disk image in a temporary directory."""

    def __init__(self, test: unittest.TestCase, data: bytes, size: int | None = None):
        tmp = tempfile.TemporaryDirectory()
        test.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "disk.img"
        self.path.write_bytes(data)
        if size is not None:
            os.truncate(self.path, size)

    def read(self, length: int | None = None, offset: int = 0) -> bytes:
        with self.path.open("rb") as image:
            image.seek(offset)
            return image.read(length) if length is not None else image.read()


class Detection(unittest.TestCase):
    def test_the_gxbb_layout_has_the_header_in_sectors_0_and_1(self):
        disk = Disk(self, bytes(amlogic_head()), size=64 * MIB)
        area = ab.detect(disk.path)
        self.assertIsNotNone(area)
        self.assertEqual(area.found_at, "sector 1 and sector 0 (GXBB)")
        self.assertEqual(area.reserve, MIB, "the existing MBR's first partition starts at 1 MiB")
        self.assertEqual(area.head, disk.read(MIB))

    def test_later_generations_have_it_in_sector_1(self):
        disk = Disk(self, bytes(amlogic_head(sector0_magic=False)), size=64 * MIB)
        area = ab.detect(disk.path)
        self.assertIsNotNone(area)
        self.assertEqual(area.found_at, "sector 1")

    def test_sector_0_alone_counts(self):
        disk = Disk(self, bytes(amlogic_head(sector1_magic=False)), size=64 * MIB)
        self.assertEqual(ab.detect(disk.path).found_at, "sector 0 (GXBB)")

    def test_sector_0_alone_under_a_gpt_header_is_a_gpt_disk(self):
        head = amlogic_head(sector1_magic=False)
        head[512:520] = b"EFI PART"
        disk = Disk(self, bytes(head), size=64 * MIB)
        self.assertIsNone(ab.detect(disk.path))

    def test_sector_1_holding_the_image_under_a_protective_mbr_still_counts(self):
        # A GPT install's protective MBR left, the image put back over sector 1.
        table = bytes(4) + b"\0\0" + mbr_entry(False, 0xEE, 1, 0xFFFFFFFF) + bytes(48) + b"\x55\xaa"
        disk = Disk(self, bytes(amlogic_head(sector0_magic=False, table=table)), size=64 * MIB)
        area = ab.detect(disk.path)
        self.assertIsNotNone(area)
        self.assertEqual(area.reserve, 4 * MIB, "a protective MBR says nothing about the image's size")

    def test_a_disk_without_the_header_is_not_amlogic(self):
        for data in (bytes(MIB), filler(MIB), bytes(amlogic_head(sector0_magic=False, sector1_magic=False))):
            with self.subTest(first_bytes=data[:4]):
                self.assertIsNone(ab.detect(Disk(self, data).path))

    def test_the_header_elsewhere_does_not_count(self):
        head = bytearray(filler(MIB))
        head[0x10000:0x10004] = b"@AML"  # the FIP's copies sit further in
        head[520:524] = b"@AML"
        self.assertIsNone(ab.detect(Disk(self, bytes(head)).path))

    def test_a_short_device(self):
        sector1 = bytes(amlogic_head(MIB, sector0_magic=False))
        for length in (0, 100, 511, 512, 531):
            with self.subTest(length=length):
                self.assertIsNone(ab.detect(Disk(self, sector1[:length]).path))
        self.assertIsNone(ab.detect(Disk(self, bytes(amlogic_head(MIB))[:19]).path))
        # Long enough for the header: detected, with what there is of the head.
        for data, length in ((sector1, 532), (bytes(amlogic_head(MIB)), 20)):
            with self.subTest(length=length):
                area = ab.detect(Disk(self, data[:length]).path)
                self.assertIsNotNone(area)
                self.assertEqual(len(area.head), length)

    def test_a_missing_disk_is_left_to_the_cleanup(self):
        self.assertIsNone(ab.detect("/nonexistent/omarchy-test-disk"))

    def test_the_read_is_read_only(self):
        disk = Disk(self, bytes(amlogic_head()), size=8 * MIB)
        disk.path.chmod(0o444)
        if os.access(disk.path, os.W_OK):
            self.skipTest("root opens a read-only file for writing anyway")
        self.assertIsNotNone(ab.detect(disk.path))


class Reserve(unittest.TestCase):
    def sector0(self, *entries: bytes) -> bytes:
        table = b"".join(entries).ljust(64, b"\0")
        return bytes(440) + SIGNATURE + b"\0\0" + table + b"\x55\xaa"

    def test_where_the_existing_first_partition_starts(self):
        cases = {
            2048: MIB,             # the Minix: 1 MiB, as Jonny's layout has it
            63: MIB,               # never below 1 MiB
            4096: 2 * MIB,
            5000: 3 * MIB,         # rounded up to MiB
            8192: 4 * MIB,
            32768: 4 * MIB,        # never beyond Amlogic's 4 MiB bootloader area
            204800: 4 * MIB,
        }
        for start, reserve in cases.items():
            with self.subTest(start=start):
                sector0 = self.sector0(mbr_entry(False, 0x83, start + 4096, 100), mbr_entry(True, 0xEF, start, 4096))
                self.assertEqual(ab.reserve_bytes(sector0), reserve)

    def test_without_an_mbr_all_4_mib(self):
        self.assertEqual(ab.reserve_bytes(bytes(512)), 4 * MIB)
        self.assertEqual(ab.reserve_bytes(self.sector0()), 4 * MIB, "an MBR with no partitions")
        self.assertEqual(ab.reserve_bytes(self.sector0(mbr_entry(False, 0xEE, 1, 1000))), 4 * MIB)

    def test_4k_sectors(self):
        self.assertEqual(ab.reserve_bytes(self.sector0(mbr_entry(False, 0x83, 256, 100)), 4096), MIB)
        self.assertEqual(ab.reserve_bytes(self.sector0(mbr_entry(False, 0x83, 512, 100)), 4096), 2 * MIB)


def layout(device: str, disk_bytes: int = 16 * GIB, start: int = MIB) -> dict:
    """The disk_config the configurator writes: 1 MiB gap, 2 GiB ESP, the
    rest btrfs minus 1 MiB."""
    def size(value):
        return {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": value}
    return {
        "config_type": "default_layout",
        "device_modifications": [{
            "device": device,
            "wipe": True,
            "partitions": [
                {"obj_id": "esp", "status": "create", "start": size(start), "size": size(2 * GIB)},
                {"obj_id": "root", "status": "create", "start": size(start + 2 * GIB),
                 "size": size(disk_bytes - start - 2 * GIB - MIB)},
            ],
        }],
    }


class FitLayout(unittest.TestCase):
    def parts(self, config):
        return {p["obj_id"]: (p["start"]["value"], p["size"]["value"])
                for p in config["device_modifications"][0]["partitions"]}

    def test_a_layout_that_starts_behind_the_bootloader_stays(self):
        config = layout("/dev/mmcblk2")
        before = json.dumps(config)
        self.assertEqual(ab.fit_layout(config, "/dev/mmcblk2", MIB), 0)
        self.assertEqual(json.dumps(config), before)

    def test_the_partitions_move_behind_it_and_the_last_gives_up_the_room(self):
        config = layout("/dev/mmcblk2")
        root_end = sum(self.parts(config)["root"])
        self.assertEqual(ab.fit_layout(config, "/dev/mmcblk2", 4 * MIB), 3 * MIB)
        parts = self.parts(config)
        self.assertEqual(parts["esp"], (4 * MIB, 2 * GIB))
        self.assertEqual(parts["root"][0], 4 * MIB + 2 * GIB)
        self.assertEqual(sum(parts["root"]), root_end, "the root still ends where it did")

    def test_the_disk_is_matched_through_its_by_id_link(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        target = Path(tmp.name) / "mmcblk2"
        target.touch()
        link = Path(tmp.name) / "mmc-SC16G_0x12345678"
        link.symlink_to(target)
        config = layout(str(link))
        self.assertEqual(ab.fit_layout(config, str(target), 2 * MIB), MIB)
        self.assertEqual(ab.fit_layout(layout("/dev/sda"), str(target), 2 * MIB), 0, "another disk is left alone")

    def test_no_room_left(self):
        with self.assertRaises(RuntimeError):
            ab.fit_layout(layout("/dev/mmcblk2", disk_bytes=2 * GIB + 3 * MIB), "/dev/mmcblk2", 4 * MIB)

    def test_a_unit_it_does_not_know(self):
        config = layout("/dev/mmcblk2")
        config["device_modifications"][0]["partitions"][0]["start"]["unit"] = "percent"
        with self.assertRaises(RuntimeError):
            ab.fit_layout(config, "/dev/mmcblk2", 4 * MIB)


class WriteMbr(unittest.TestCase):
    ENTRIES = [
        ab.MbrEntry(1, True, ab.TYPE_ESP, 2048, 4 * 1024 * 1024),
        ab.MbrEntry(2, False, ab.TYPE_LINUX, 2048 + 4 * 1024 * 1024, 20 * 1024 * 1024),
    ]

    def write(self, data: bytes, size: int = 16 * GIB, entries=None) -> Disk:
        disk = Disk(self, data, size=size)
        fd = os.open(disk.path, os.O_RDWR)
        try:
            ab.write_mbr(fd, entries or self.ENTRIES)
        finally:
            os.close(fd)
        return disk

    def test_only_bytes_440_to_511_change(self):
        head = amlogic_head(MIB, table=bytes(4) + b"\xa5\x5a" + bytes(66))  # no table yet
        head[440:444] = SIGNATURE
        disk = self.write(bytes(head))
        after = disk.read(MIB)
        self.assertEqual(after[:440], head[:440])
        self.assertEqual(after[440:446], SIGNATURE + b"\xa5\x5a", "the disk signature and bytes 444-445 stay")
        self.assertEqual(after[512:], head[512:])
        self.assertEqual(after[510:512], b"\x55\xaa")
        self.assertEqual(ab.mbr_entries(after[:512]), self.ENTRIES)

    def test_sfdisk_reads_the_table_as_the_minix_has_it(self):
        if not shutil.which("sfdisk"):
            self.skipTest("no sfdisk")
        head = amlogic_head(MIB, table=SIGNATURE + bytes(68))
        disk = self.write(bytes(head))
        dump = subprocess.run(["sfdisk", "-d", str(disk.path)], capture_output=True, text=True, check=True).stdout
        self.assertIn("label: dos", dump)
        self.assertIn("label-id: 0x6d696e78", dump)
        self.assertRegex(dump, r"img1 : start=\s*2048, size=\s*4194304, type=ef, bootable")
        self.assertRegex(dump, r"img2 : start=\s*4196352, size=\s*20971520, type=83\n")

    def test_a_disk_without_a_signature_gets_one(self):
        disk = self.write(bytes(amlogic_head(MIB, table=bytes(72))))
        signature = disk.read(4, 440)
        self.assertNotEqual(signature, bytes(4))

    def test_chs_as_fdisk_writes_it(self):
        self.assertEqual(ab._chs(2048), bytes((32, 33, 0)))
        self.assertEqual(ab._chs(0), bytes((0, 1, 0)))
        self.assertEqual(ab._chs(1023 * 16065 - 1), bytes((254, 63 | 0xC0, 0xFE)))
        self.assertEqual(ab._chs(1024 * 16065), b"\xfe\xff\xff")  # beyond 8 GiB

    def test_what_an_mbr_cannot_hold(self):
        for entry in (ab.MbrEntry(5, False, 0x83, 2048, 10), ab.MbrEntry(1, False, 0x83, 2048, 1 << 32),
                      ab.MbrEntry(1, False, 0x83, 0, 10)):
            with self.subTest(entry=entry), self.assertRaises(RuntimeError):
                ab.pack_entry(entry)

    def test_the_tail_is_cleared_like_parted_does_unless_a_partition_reaches_it(self):
        disk = Disk(self, b"", size=64 * MIB)
        with disk.path.open("r+b") as image:
            image.seek(64 * MIB - 512)
            image.write(b"EFI PART".ljust(512, b"x"))
        fd = os.open(disk.path, os.O_RDWR)
        try:
            self.assertFalse(ab.clear_tail(fd, 64 * MIB, 512, 64 * MIB))
            self.assertEqual(disk.read(8, 64 * MIB - 512), b"EFI PART")
            self.assertTrue(ab.clear_tail(fd, 64 * MIB, 512, 63 * MIB))
        finally:
            os.close(fd)
        self.assertEqual(disk.read(offset=64 * MIB - 19 * 512), bytes(19 * 512))


class VerifyKept(unittest.TestCase):
    def test_changed_bytes_are_named(self):
        disk = Disk(self, bytes(amlogic_head()), size=8 * MIB)
        area = ab.detect(disk.path)
        self.assertIn("is intact", ab.verify_kept(area))
        with disk.path.open("r+b") as image:
            image.seek(440)
            image.write(b"\x01\x02\x03\x04")  # the disk signature may change
            image.seek(446)
            image.write(bytes(64))
        ab.verify_kept(area)
        with disk.path.open("r+b") as image:
            image.seek(512 * 33)
            image.write(b"GPT entries")
        with self.assertRaisesRegex(RuntimeError, r"bytes 512-1048575"):
            ab.verify_kept(area)
        with disk.path.open("r+b") as image:
            image.write(bytes(1024))  # what archinstall's wipe_dev writes
        with self.assertRaisesRegex(RuntimeError, r"bytes 0-439, 512-1048575"):
            ab.verify_kept(area)


if __name__ == "__main__":
    unittest.main()
