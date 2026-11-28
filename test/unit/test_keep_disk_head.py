"""archinstall's full-disk partitioning on a disk with an Amlogic bootloader.

archinstall_adapter._keep_disk_head steers archinstall's device handler for
that one disk: partition() gets an MBR where archinstall picks GPT on every
UEFI machine, wipe_dev() leaves the disk's first KiB alone, and parted's
commit becomes a write of the MBR entries into bytes 440-511, followed by
parted telling the kernel (commitToOS). Any other disk goes through
archinstall unchanged. The stand-ins below record what they are asked to do;
the disk is an image file.
"""

import os
import sys
import tempfile
import types
import unittest
from enum import Enum
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import adapter  # noqa: E402
from test_amlogic_boot import amlogic_head  # noqa: E402

MIB = 1024 * 1024


class PartitionTable(Enum):
    GPT = "gpt"
    MBR = "msdos"


class Luks2:
    erased: list = []

    def __init__(self, path):
        self.path = str(path)

    def is_luks(self):
        return self.path.endswith("2")

    def erase(self):
        Luks2.erased.append(self.path)

    # luks_tuning wraps these when the adapter loads.
    def encrypt(self, *args, **kwargs): return None
    def unlock(self, *args, **kwargs): return None
    def lock(self): return None


class DeviceHandler:
    """archinstall's DeviceHandler on a UEFI machine: GPT by default."""

    def __init__(self):
        self.calls = []

    def partition(self, modification, partition_table=None):
        self.calls.append(("partition", modification.device.device_info.path,
                           (partition_table or PartitionTable.GPT).value))

    def wipe_dev(self, block_device):
        self.calls.append(("wipe_dev", block_device.device_info.path))

    def _wipe(self, path):
        self.calls.append(("_wipe", str(path)))


PARTED = dict(PARTITION_NORMAL=0, PARTITION_LOGICAL=1, PARTITION_BOOT=1, PARTITION_ESP=18, PARTITION_SWAP=4)


class Partition:
    def __init__(self, number, start, length, flags=(), kind=0):
        self.number, self.type, self.flags = number, kind, set(flags)
        self.geometry = types.SimpleNamespace(start=start, length=length)

    def getFlag(self, flag):
        return flag in self.flags


class Disk:
    commits = []

    def __init__(self, path, partitions, kind="msdos", length=32 * 1024 * 1024):
        self.device = types.SimpleNamespace(path=str(path), sectorSize=512, length=length)
        self.partitions, self.type = partitions, kind
        self.told_kernel = 0

    def commit(self):
        Disk.commits.append(self.device.path)
        return True

    def commitToOS(self):
        self.told_kernel += 1
        return True


def modification(path):
    return types.SimpleNamespace(device=types.SimpleNamespace(device_info=types.SimpleNamespace(path=Path(path))))


class KeepDiskHead(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.disk = Path(tmp.name) / "mmcblk2"
        self.head = bytes(amlogic_head(MIB))
        self.disk.write_bytes(self.head)
        os.truncate(self.disk, 16 * 1024 * MIB)
        Disk.commits, Luks2.erased = [], []

        self.handler = DeviceHandler()
        self.enterContext(mock.patch.dict(os.environ, {"OMARCHY_LUKS_TUNING": "0"}))
        self.arch = self.enterContext(adapter({
            "archinstall.lib.disk.device_handler": {"device_handler": self.handler},
            "archinstall.lib.disk.luks": {"Luks2": Luks2},
            "archinstall.lib.models.device": {"PartitionTable": PartitionTable},
        }))
        self.parted = types.SimpleNamespace(Disk=Disk, **PARTED)
        self.enterContext(mock.patch.dict(sys.modules, {"parted": self.parted}))
        self.log = []
        self.enterContext(mock.patch.object(self.arch, "info", self.log.append))
        from orchestrator import amlogic_boot
        self.area = amlogic_boot.detect(self.disk)
        self.assertIsNotNone(self.area)

    def read_head(self) -> bytes:
        with self.disk.open("rb") as image:
            return image.read(MIB)

    def layout(self, path=None):
        path = path or self.disk
        return Disk(path, [
            Partition(1, 2048, 4194304, {PARTED["PARTITION_BOOT"], PARTED["PARTITION_ESP"]}),
            Partition(2, 4196352, 20971520),
        ])

    def test_the_amlogic_disk_gets_an_mbr_and_others_keep_gpt(self):
        with self.arch._keep_disk_head(self.area):
            self.handler.partition(modification(self.disk))
            self.handler.partition(modification("/dev/nvme0n1"))
        self.assertEqual(self.handler.calls, [
            ("partition", Path(self.disk), "msdos"),
            ("partition", Path("/dev/nvme0n1"), "gpt"),
        ])

    def test_wipe_dev_leaves_the_disks_first_kib_alone(self):
        starts = {"/dev/mmcblk2p1": 2048 * 512, "/dev/mmcblk2p2": 2 * 1024 * MIB, "/dev/mmcblk2p3": 8 * 512}
        device = types.SimpleNamespace(
            device_info=types.SimpleNamespace(path=self.disk),
            partition_infos=[types.SimpleNamespace(path=Path(p)) for p in starts],
        )
        other = types.SimpleNamespace(device_info=types.SimpleNamespace(path=Path("/dev/sda")), partition_infos=[])
        with mock.patch.object(self.arch, "_partition_start_bytes", lambda path: starts[str(path)]), \
                self.arch._keep_disk_head(self.area):
            self.handler.wipe_dev(device)
            self.handler.wipe_dev(other)
        self.assertEqual(self.handler.calls, [
            ("_wipe", "/dev/mmcblk2p1"),
            ("_wipe", "/dev/mmcblk2p2"),
            ("wipe_dev", Path("/dev/sda")),
        ], "no _wipe of the disk itself, nor of a partition inside the bootloader")
        self.assertEqual(Luks2.erased, ["/dev/mmcblk2p2"])

    def test_the_commit_writes_the_mbr_entries_alone(self):
        disk = self.layout()
        other = self.layout("/dev/nvme0n1")
        with self.arch._keep_disk_head(self.area):
            self.assertTrue(self.parted.Disk.commit(disk))
            self.parted.Disk.commit(other)
        self.assertEqual(Disk.commits, ["/dev/nvme0n1"], "parted committed only the other disk")
        self.assertEqual(disk.told_kernel, 1)
        after = self.read_head()
        self.assertEqual(after[:440], self.head[:440])
        self.assertEqual(after[512:], self.head[512:])
        from orchestrator import amlogic_boot
        self.assertEqual(amlogic_boot.mbr_entries(after[:512]), [
            amlogic_boot.MbrEntry(1, True, 0xEF, 2048, 4194304),
            amlogic_boot.MbrEntry(2, False, 0x83, 4196352, 20971520),
        ])
        self.assertEqual(after[440:444], self.head[440:444], "the disk signature stays")

    def test_the_patches_come_off(self):
        commit = Disk.__dict__["commit"]
        with self.arch._keep_disk_head(self.area):
            self.assertIn("partition", vars(self.handler))
        self.assertIs(Disk.__dict__["commit"], commit)
        self.assertNotIn("partition", vars(self.handler))
        self.assertNotIn("wipe_dev", vars(self.handler))
        with self.assertRaises(ZeroDivisionError), self.arch._keep_disk_head(self.area):
            1 / 0
        self.assertIs(Disk.__dict__["commit"], commit)

    def test_nothing_is_patched_without_a_bootloader(self):
        commit = Disk.__dict__["commit"]
        with self.arch._keep_disk_head(None):
            self.assertIs(Disk.__dict__["commit"], commit)
            self.assertNotIn("partition", vars(self.handler))

    def test_what_the_mbr_cannot_take_stops_before_a_write(self):
        cases = {
            "gpt": Disk(self.disk, self.layout().partitions, kind="gpt"),
            "inside": Disk(self.disk, [Partition(1, 64, 4096)]),
            "logical": Disk(self.disk, [Partition(5, 4096, 4096, kind=PARTED["PARTITION_LOGICAL"])]),
        }
        for name, disk in cases.items():
            with self.subTest(name), self.arch._keep_disk_head(self.area), self.assertRaises(RuntimeError):
                self.parted.Disk.commit(disk)
            self.assertEqual(self.read_head(), self.head)

    def test_the_kernel_params_name_the_root_by_uuid(self):
        installer = mock.Mock()
        installer._get_kernel_params = lambda root, id_root=True, partuuid=True: [f"partuuid={partuuid}"]
        self.assertEqual(self.arch.kernel_params(installer, "root", partuuid=False), ["partuuid=False"])
        self.assertEqual(self.arch.kernel_params(installer, "root"), ["partuuid=True"])


if __name__ == "__main__":
    unittest.main()
