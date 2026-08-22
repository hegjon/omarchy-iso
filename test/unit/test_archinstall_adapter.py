"""Unit tests for the archinstall-bash adapter and the arch_install_system
phase ordering built on it.

archinstall-step only exists on the live ISO, so subprocess.run is recorded
and answered by fakes here; the point is the command lines the adapter emits,
the JSON it parses, and the order in which the phase drives the steps.
"""

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import archinstall_adapter as arch  # noqa: E402
from orchestrator import phases_impl  # noqa: E402

QUERY = {
    "target": "/mnt", "disk_config_type": "default_layout", "pre_mount": False, "encrypted": True,
    "has_uefi": True, "bootloader": "limine", "bootloader_uki": False, "bootloader_removable": False,
    "hostname": "omarchy", "timezone": "UTC", "ntp": True, "swap": True, "zram_enabled": True,
    "mirror_config": True, "app_config": True, "kb_layout": "us", "kernels": ["linux"], "users": ["jonny"],
    "root_password": True,
    "root": {"dev_path": "/dev/vda2", "mountpoint": None, "partn": 2, "partuuid": "bbbb-2", "uuid": "cccc-3",
             "fs_type": "btrfs", "mapper_name": "root", "btrfs_subvols": [{"name": "@", "mountpoint": "/"}]},
    "boot": {"dev_path": "/dev/vda1", "mountpoint": "/boot", "partn": 1, "partuuid": "aaaa-1", "uuid": "AAAA-1111",
             "fs_type": "fat32", "mapper_name": None, "btrfs_subvols": []},
    "efi": {"dev_path": "/dev/vda1", "mountpoint": "/boot", "partn": 1, "partuuid": "aaaa-1", "uuid": "AAAA-1111",
            "fs_type": "fat32", "mapper_name": None, "btrfs_subvols": []},
    "kernel_params": "cryptdevice=PARTUUID=bbbb-2:root root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs",
}


class AdapterTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        run_patch = mock.patch.object(arch.subprocess, "run", side_effect=self.fake_run)
        run_patch.start()
        self.addCleanup(run_patch.stop)
        self.ai = arch.ArchInstall(Path("/run/omarchy-install/archinstall.state"), Path("/mnt"))

    def fake_run(self, cmd, **kwargs):
        self.calls.append(cmd)
        step = cmd[cmd.index("--target") + 2] if "--target" in cmd else cmd[1]
        if step == "query":
            return CompletedProcess(cmd, 0, stdout=json.dumps(QUERY), stderr="")
        if step == "parent-device":
            return CompletedProcess(cmd, 0, stdout="/dev/vda\n", stderr="")
        if step == "unique-device-path":
            return CompletedProcess(cmd, 1, stdout="", stderr="")
        if step == "fail":
            return CompletedProcess(cmd, 3, stdout=None, stderr="")
        return CompletedProcess(cmd, 0, stdout=None, stderr="")

    def prefix(self):
        return ["archinstall-step", "--state", "/run/omarchy-install/archinstall.state", "--target", "/mnt"]

    def test_load_config_passes_creds_only_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "c.json"
            config.write_text("{}")
            creds = Path(tmp) / "creds.json"
            self.ai.load_config(config, creds)
            self.assertEqual(self.calls[-1], self.prefix() + ["load-config", "--config", str(config)])
            creds.write_text("{}")
            self.ai.load_config(config, creds)
            self.assertEqual(self.calls[-1], self.prefix() + ["load-config", "--config", str(config), "--creds", str(creds)])

    def test_query_parses_partitions_and_flags(self):
        info = self.ai.query()
        self.assertTrue(info.encrypted and info.has_uefi and info.is_limine and info.bootloader_enabled)
        self.assertFalse(info.pre_mount)
        self.assertEqual(info.efi.mountpoint, Path("/boot"))
        self.assertEqual(info.efi.partn, 1)
        self.assertEqual(info.root.safe_dev_path, Path("/dev/vda2"))
        self.assertEqual(info.root.mapper_name, "root")
        self.assertIn("root=/dev/mapper/root", info.kernel_params)
        self.assertEqual(info.users, ["jonny"])
        self.assertTrue(info.swap and info.ntp and info.root_password)

    def test_query_without_partitions(self):
        bare = dict(QUERY, root=None, boot=None, efi=None, kernel_params=None, users=[])
        with mock.patch.object(arch.subprocess, "run", return_value=CompletedProcess([], 0, stdout=json.dumps(bare), stderr="")):
            info = self.ai.query()
        self.assertIsNone(info.root)
        self.assertIsNone(info.kernel_params)
        self.assertEqual(info.users, [])

    def test_step_commands(self):
        self.ai.minimal_installation(mkinitcpio=False)
        self.assertEqual(self.calls[-1], self.prefix() + ["minimal-installation", "--no-mkinitcpio"])
        self.ai.minimal_installation(only_missing=True)
        self.assertEqual(self.calls[-1], self.prefix() + ["--only-missing", "minimal-installation"])
        self.ai.set_mirrors(on_target=True)
        self.assertEqual(self.calls[-1], self.prefix() + ["set-mirrors", "on_target"])
        self.ai.add_packages(["a", "b"])
        self.assertEqual(self.calls[-1], self.prefix() + ["add-packages", "a", "b"])
        before = len(self.calls)
        self.ai.add_packages([])
        self.assertEqual(len(self.calls), before, "no process for an empty package list")
        self.ai.finish()
        self.assertEqual(self.calls[-1], self.prefix() + ["finish"])

    def test_failure_raises(self):
        with self.assertRaises(arch.ArchInstallError) as raised:
            self.ai._run("fail")
        self.assertIn("fail failed (exit 3)", str(raised.exception))

    def test_stateless_helpers(self):
        self.assertEqual(arch.parent_device_path(Path("/dev/vda1")), Path("/dev/vda"))
        self.assertEqual(self.calls[-1], ["archinstall-step", "parent-device", "/dev/vda1"])
        self.assertIsNone(arch.unique_device_path(Path("/dev/vda")))


class FakeArchInstall:
    """Records the step order arch_install_system drives."""

    def __init__(self, info):
        self.info = info
        self.steps = []

    def query(self):
        self.steps.append("query")
        return self.info

    def __getattr__(self, name):
        def step(*args, **kwargs):
            self.steps.append(name if not args else f"{name}:{args[0]}")
        return step


class ArchInstallSystemOrderTest(unittest.TestCase):
    def run_phase(self, **overrides):
        info = arch.InstallInfo.from_json(dict(QUERY, **overrides))
        fake = FakeArchInstall(info)
        ctx = types.SimpleNamespace(
            state={"archinstall": fake}, target=Path("/mnt"), tailscale_authkey_path=None,
        )
        patches = {
            "_mount_offline_package_cache": mock.DEFAULT,
            "_unmount_offline_package_cache": mock.DEFAULT,
            "_mask_mkinitcpio_pacman_hooks": mock.DEFAULT,
            "_unmask_mkinitcpio_pacman_hooks": mock.DEFAULT,
            "_drop_archinstall_zram_conf": mock.DEFAULT,
            "_configure_limine_boot": mock.DEFAULT,
            "_install_early_packages": mock.DEFAULT,
            "_write_pre_mounted_fstab": mock.DEFAULT,
            "info": mock.DEFAULT,
        }
        with mock.patch.multiple(phases_impl, **patches) as mocks, \
                mock.patch.object(phases_impl, "_runtime_package_list", return_value=["omarchy"]):
            mocks["_configure_limine_boot"].side_effect = lambda c, ai: ai.steps.append("limine")
            mocks["_install_early_packages"].side_effect = lambda ai: ai.steps.append("early-packages")
            phases_impl.arch_install_system(ctx)
        return fake.steps, mocks

    def test_full_disk_order(self):
        steps, _ = self.run_phase()
        self.assertEqual(steps, [
            "query",
            "perform_filesystem_operations", "mount_ordered_layout",
            "set_mirrors", "minimal_installation", "set_mirrors", "setup_swap",
            "early-packages", "limine",
            "create_users", "install_applications", "add_packages:['omarchy']",
            "set_timezone", "activate_time_synchronization", "set_root_password",
            "genfstab", "finish",
        ])

    def test_minimal_installation_defers_mkinitcpio(self):
        info = arch.InstallInfo.from_json(QUERY)
        fake = mock.MagicMock()
        fake.query.return_value = info
        ctx = types.SimpleNamespace(state={"archinstall": fake}, target=Path("/mnt"), tailscale_authkey_path=None)
        with mock.patch.multiple(
            phases_impl, _mount_offline_package_cache=mock.DEFAULT, _unmount_offline_package_cache=mock.DEFAULT,
            _mask_mkinitcpio_pacman_hooks=mock.DEFAULT, _unmask_mkinitcpio_pacman_hooks=mock.DEFAULT,
            _drop_archinstall_zram_conf=mock.DEFAULT, _configure_limine_boot=mock.DEFAULT,
            _install_early_packages=mock.DEFAULT, info=mock.DEFAULT,
        ), mock.patch.object(phases_impl, "_runtime_package_list", return_value=["omarchy"]):
            phases_impl.arch_install_system(ctx)
        fake.minimal_installation.assert_called_once_with(mkinitcpio=False)

    def test_pre_mounted_skips_disk_steps_and_writes_own_fstab(self):
        steps, mocks = self.run_phase(pre_mount=True)
        self.assertNotIn("perform_filesystem_operations", steps)
        self.assertNotIn("mount_ordered_layout", steps)
        self.assertNotIn("genfstab", steps)
        mocks["_write_pre_mounted_fstab"].assert_called_once()
        self.assertEqual(steps[-1], "finish")

    def test_optional_steps_follow_the_config(self):
        steps, mocks = self.run_phase(mirror_config=False, swap=False, users=[], app_config=False,
                                      timezone="", ntp=False, root_password=False)
        for absent in ("set_mirrors", "setup_swap", "create_users", "install_applications",
                       "set_timezone", "activate_time_synchronization", "set_root_password"):
            self.assertNotIn(absent, steps)
        mocks["_drop_archinstall_zram_conf"].assert_not_called()

    def test_tailscale_package_when_key_staged(self):
        info = arch.InstallInfo.from_json(QUERY)
        fake = FakeArchInstall(info)
        ctx = types.SimpleNamespace(state={"archinstall": fake}, target=Path("/mnt"), tailscale_authkey_path=Path("/root/tailscale_authkey"))
        with mock.patch.multiple(
            phases_impl, _mount_offline_package_cache=mock.DEFAULT, _unmount_offline_package_cache=mock.DEFAULT,
            _mask_mkinitcpio_pacman_hooks=mock.DEFAULT, _unmask_mkinitcpio_pacman_hooks=mock.DEFAULT,
            _drop_archinstall_zram_conf=mock.DEFAULT, _configure_limine_boot=mock.DEFAULT,
            _install_early_packages=mock.DEFAULT, info=mock.DEFAULT,
        ), mock.patch.object(phases_impl, "_runtime_package_list", return_value=["omarchy"]):
            phases_impl.arch_install_system(ctx)
        self.assertIn("add_packages:['tailscale']", fake.steps)
        self.assertLess(fake.steps.index("add_packages:['tailscale']"), fake.steps.index("set_timezone"))


class LimineFromQueryTest(unittest.TestCase):
    def test_limine_uses_query_partitions_and_cmdline(self):
        info = arch.InstallInfo.from_json(QUERY)
        fake = mock.MagicMock()
        fake.query.return_value = info
        ctx = types.SimpleNamespace(target=Path("/mnt"))
        with mock.patch.object(phases_impl, "_install_limine_efi") as efi, \
                mock.patch.object(phases_impl, "_write_limine_defaults") as defaults, \
                mock.patch.object(phases_impl.arch, "parent_device_path", return_value=Path("/dev/vda")), \
                mock.patch.object(phases_impl, "info"):
            phases_impl._configure_limine_boot(ctx, fake)
        efi.assert_called_once_with(ctx, esp_mount="/boot", disk=Path("/dev/vda"), part=1, removable=False)
        defaults.assert_called_once_with(ctx, QUERY["kernel_params"], esp_mount="/boot")

    def test_no_bootloader_is_a_no_op(self):
        fake = mock.MagicMock()
        fake.query.return_value = arch.InstallInfo.from_json(dict(QUERY, bootloader="no_bootloader"))
        with mock.patch.object(phases_impl, "_install_limine_efi") as efi:
            phases_impl._configure_limine_boot(types.SimpleNamespace(target=Path("/mnt")), fake)
        efi.assert_not_called()

    def test_other_bootloaders_are_refused(self):
        fake = mock.MagicMock()
        fake.query.return_value = arch.InstallInfo.from_json(dict(QUERY, bootloader="grub"))
        with self.assertRaises(RuntimeError):
            phases_impl._configure_limine_boot(types.SimpleNamespace(target=Path("/mnt")), fake)


if __name__ == "__main__":
    unittest.main()
