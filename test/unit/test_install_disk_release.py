#!/usr/bin/python

"""Releasing the install disk before archinstall partitions it.

omarchy-iso-cleanup-disk refuses when something still holds the disk, and its
last line says what. prepare_live has to put that line on the failure screen
rather than the "returned non-zero exit status 1" a bare check=True gives, and
has to stop before archinstall is ever loaded. These tests put stand-in
cleanup scripts on PATH, so the real command capture runs.
"""

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402

FULL_DISK = {"disk_config": {"device_modifications": [{"device": "/dev/vda", "wipe": True}]}}


class ReleaseCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin_dir = Path(self.tmp.name)
        path = mock.patch.dict(os.environ, {"PATH": f"{self.bin_dir}:{os.environ['PATH']}"})
        path.start()
        self.addCleanup(path.stop)
        self.arch = mock.Mock()
        patches = [
            mock.patch.object(phases_impl, "arch", self.arch, create=True),
            mock.patch.object(phases_impl, "_stage_qualcomm_firmware"),
            mock.patch.object(phases_impl, "_start_target_keyring_init"),
            # No disk here carries an Amlogic bootloader (test_amlogic_boot).
            mock.patch.object(phases_impl.amlogic_boot, "detect", return_value=None),
            # It asks the host's systemd to stop a unit: seconds, and not ours.
            mock.patch("orchestrator.luks_calibration.cancel_calibration"),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def cleanup_script(self, body: str) -> None:
        script = self.bin_dir / "omarchy-iso-cleanup-disk"
        script.write_text(f"#!/bin/sh\n{body}\n")
        script.chmod(0o755)

    def ctx(self):
        return types.SimpleNamespace(
            is_protected=False,
            user_configuration=FULL_DISK,
            arch_config_path=Path("/root/user_configuration.json"),
            creds_path=Path("/root/user_credentials.json"),
            state={},
        )


class InstallDiskReleaseTest(ReleaseCase):
    def test_a_held_disk_stops_with_what_holds_it(self):
        self.cleanup_script(
            'echo "Cleaning up existing holders on install disk: $1"\n'
            'echo "/dev/vda is still in use and cannot be partitioned (vda2 is held by md127)."\n'
            "exit 1"
        )

        with self.assertRaises(RuntimeError) as raised:
            phases_impl.prepare_live(self.ctx())

        self.assertEqual(
            str(raised.exception),
            "/dev/vda is still in use and cannot be partitioned (vda2 is held by md127).",
        )
        self.arch.load_arch_config.assert_not_called()

    def test_a_silent_failure_still_names_the_disk(self):
        self.cleanup_script("exit 1")

        with self.assertRaises(RuntimeError) as raised:
            phases_impl.prepare_live(self.ctx())

        self.assertEqual(str(raised.exception), "Could not release /dev/vda")

    def test_a_released_disk_goes_on_to_archinstall(self):
        self.cleanup_script('[ "$1" = /dev/vda ] || exit 1\necho "Released $1"')

        phases_impl.prepare_live(self.ctx())

        self.arch.load_arch_config.assert_called_once()


class AmlogicBootloaderTest(ReleaseCase):
    """A disk whose start holds an Amlogic bootloader is found before the
    cleanup writes anything, the cleanup is told to keep its bytes, and a
    layout that starts too early moves behind it."""

    def area(self, reserve=1024 * 1024):
        return phases_impl.amlogic_boot.BootArea("/dev/vda", reserve, b"", "sector 1")

    def ctx_with_layout(self, start):
        config_dir = Path(self.tmp.name)
        def size(value):
            return {"unit": "B", "value": value, "sector_size": {"unit": "B", "value": 512}}
        disk_config = {"device_modifications": [{
            "device": "/dev/vda", "wipe": True,
            "partitions": [
                {"status": "create", "start": size(start), "size": size(2 << 30)},
                {"status": "create", "start": size(start + (2 << 30)), "size": size(10 << 30)},
            ],
        }]}
        arch_config_path = config_dir / "archinstall-user_configuration.json"
        arch_config_path.write_text(json.dumps({"disk_config": disk_config}))
        return types.SimpleNamespace(
            is_protected=False,
            user_configuration={"disk_config": json.loads(json.dumps(disk_config))},
            arch_config_path=arch_config_path,
            creds_path=config_dir / "user_credentials.json",
            state={},
        )

    def test_the_cleanup_keeps_the_bootloaders_bytes(self):
        self.cleanup_script('echo "args: $*"\n[ "$1 $2 $3" = "--keep-head 1048576 /dev/vda" ] || exit 1')
        area = self.area()
        ctx = self.ctx()
        with mock.patch.object(phases_impl.amlogic_boot, "detect", return_value=area):
            phases_impl.prepare_live(ctx)
        self.assertIs(ctx.state["amlogic_boot_area"], area)
        self.arch.load_arch_config.assert_called_once()

    def test_the_layout_moves_behind_a_4_mib_bootloader(self):
        self.cleanup_script("exit 0")
        ctx = self.ctx_with_layout(1024 * 1024)
        with mock.patch.object(phases_impl.amlogic_boot, "detect", return_value=self.area(4 << 20)):
            phases_impl.prepare_live(ctx)
        for config in (ctx.user_configuration, json.loads(ctx.arch_config_path.read_text())):
            starts = [p["start"]["value"] for p in config["disk_config"]["device_modifications"][0]["partitions"]]
            self.assertEqual(starts, [4 << 20, (4 << 20) + (2 << 30)])

    def test_a_bios_install_would_overwrite_it(self):
        self.cleanup_script("echo ran >\"$0.ran\"")
        self.arch.has_uefi.return_value = False
        with mock.patch.object(phases_impl.amlogic_boot, "detect", return_value=self.area()), \
                self.assertRaisesRegex(RuntimeError, "BIOS install would overwrite"):
            phases_impl.prepare_live(self.ctx())
        self.assertFalse((self.bin_dir / "omarchy-iso-cleanup-disk.ran").exists(), "nothing was cleaned up")


if __name__ == "__main__":
    unittest.main()
