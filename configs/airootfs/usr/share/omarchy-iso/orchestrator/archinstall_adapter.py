"""Thin compatibility wall around archinstall-bash, the bash port of
archinstall this ISO ships at /usr/share/archinstall-bash.

ONLY this module talks to it. Everything else uses these helpers, so if the
library's interface churns the blast radius is contained here.

Each step is one `archinstall-step` process. The parsed configuration and the
installer state (partition nodes, PARTUUIDs, zram flag, pacman sync) live in a
state file under the run directory between steps, and `query` hands back what
the Omarchy-owned Limine setup needs: partitions, flags and the kernel cmdline.

The call sequence (archinstall's scripts/guided.py, reordered in
phases_impl.arch_install_system) is:

    load-config                    # ArchConfigHandler + Installer()
    perform-filesystem-operations  # FilesystemHandler
    mount-ordered-layout           # Installer.mount_ordered_layout
    set-mirrors live
    minimal-installation --no-mkinitcpio
    set-mirrors on_target
    setup-swap
    create-users
    install-applications
    add-packages ...
    set-timezone / activate-time-sync / set-root-password
    genfstab
    finish                         # Installer.__exit__ post-install check

Omarchy installs its own Limine files instead of a bootloader step, from the
partition nodes and cmdline `query` reports.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

STEP = os.environ.get("OMARCHY_ARCHINSTALL_STEP", "archinstall-step")


class ArchInstallError(RuntimeError):
    """An archinstall-step process exited non-zero."""


@dataclass(frozen=True)
class Partition:
    """One partition of the layout, as `query` reports it."""

    dev_path: Path | None
    mountpoint: Path | None
    partn: int | None
    partuuid: str | None
    uuid: str | None
    fs_type: str | None
    mapper_name: str | None

    @property
    def safe_dev_path(self) -> Path:
        if self.dev_path is None:
            raise ArchInstallError("partition has no device path yet")
        return self.dev_path

    @classmethod
    def from_json(cls, data: dict | None) -> Partition | None:
        if not data:
            return None
        return cls(
            dev_path=Path(data["dev_path"]) if data.get("dev_path") else None,
            mountpoint=Path(data["mountpoint"]) if data.get("mountpoint") else None,
            partn=int(data["partn"]) if data.get("partn") is not None else None,
            partuuid=data.get("partuuid"),
            uuid=data.get("uuid"),
            fs_type=data.get("fs_type"),
            mapper_name=data.get("mapper_name"),
        )


@dataclass(frozen=True)
class InstallInfo:
    """The `query` output: what the configuration asked for and what the disk
    steps produced so far."""

    target: Path
    pre_mount: bool
    encrypted: bool
    has_uefi: bool
    bootloader: str | None
    bootloader_uki: bool
    bootloader_removable: bool
    hostname: str
    timezone: str
    ntp: bool
    swap: bool
    zram_enabled: bool
    mirror_config: bool
    app_config: bool
    kb_layout: str
    kernels: list[str]
    users: list[str]
    root_password: bool
    root: Partition | None
    boot: Partition | None
    efi: Partition | None
    kernel_params: str | None

    @classmethod
    def from_json(cls, data: dict) -> InstallInfo:
        return cls(
            target=Path(data["target"]),
            pre_mount=bool(data["pre_mount"]),
            encrypted=bool(data["encrypted"]),
            has_uefi=bool(data["has_uefi"]),
            bootloader=data.get("bootloader"),
            bootloader_uki=bool(data.get("bootloader_uki")),
            bootloader_removable=bool(data.get("bootloader_removable")),
            hostname=data.get("hostname") or "",
            timezone=data.get("timezone") or "",
            ntp=bool(data.get("ntp")),
            swap=bool(data.get("swap")),
            zram_enabled=bool(data.get("zram_enabled")),
            mirror_config=bool(data.get("mirror_config")),
            app_config=bool(data.get("app_config")),
            kb_layout=data.get("kb_layout") or "",
            kernels=list(data.get("kernels") or []),
            users=list(data.get("users") or []),
            root_password=bool(data.get("root_password")),
            root=Partition.from_json(data.get("root")),
            boot=Partition.from_json(data.get("boot")),
            efi=Partition.from_json(data.get("efi")),
            kernel_params=data.get("kernel_params") or None,
        )

    @property
    def bootloader_enabled(self) -> bool:
        return bool(self.bootloader) and self.bootloader != "no_bootloader"

    @property
    def is_limine(self) -> bool:
        return self.bootloader == "limine"


class ArchInstall:
    """The archinstall library, one `archinstall-step` process per call."""

    def __init__(self, state_path: Path, target: Path) -> None:
        self.state_path = state_path
        self.target = target

    def _run(self, *args: str, only_missing: bool = False, capture: bool = False) -> str:
        cmd = [STEP, "--state", str(self.state_path), "--target", str(self.target)]
        if only_missing:
            cmd.append("--only-missing")
        cmd.extend(args)
        res = subprocess.run(
            cmd,
            check=False,
            text=True,
            stdout=subprocess.PIPE if capture else None,
        )
        if res.returncode != 0:
            raise ArchInstallError(f"{' '.join(args)} failed (exit {res.returncode})")
        return res.stdout if capture else ""

    # ── configuration ────────────────────────────────────────────────────────

    def load_config(self, config_path: Path, creds_path: Path) -> None:
        args = ["load-config", "--config", str(config_path)]
        if creds_path.exists():
            args += ["--creds", str(creds_path)]
        self._run(*args)

    def query(self) -> InstallInfo:
        return InstallInfo.from_json(json.loads(self._run("query", capture=True)))

    def kernel_params(self) -> str:
        return self._run("kernel-params", capture=True).strip()

    # ── the Installer steps, in guided.py order ──────────────────────────────

    def perform_filesystem_operations(self) -> None:
        self._run("perform-filesystem-operations")

    def mount_ordered_layout(self) -> None:
        self._run("mount-ordered-layout")

    def set_mirrors(self, on_target: bool = False) -> None:
        self._run("set-mirrors", "on_target" if on_target else "live")

    def minimal_installation(self, mkinitcpio: bool = True, only_missing: bool = False) -> None:
        args = ["minimal-installation"]
        if not mkinitcpio:
            args.append("--no-mkinitcpio")
        self._run(*args, only_missing=only_missing)

    def setup_swap(self) -> None:
        self._run("setup-swap")

    def create_users(self) -> None:
        self._run("create-users")

    def install_applications(self) -> None:
        self._run("install-applications")

    def add_packages(self, packages: list[str]) -> None:
        if packages:
            self._run("add-packages", *packages)

    def enable_service(self, *units: str) -> None:
        if units:
            self._run("enable-service", *units)

    def set_timezone(self) -> None:
        self._run("set-timezone")

    def activate_time_synchronization(self) -> None:
        self._run("activate-time-sync")

    def set_root_password(self) -> None:
        self._run("set-root-password")

    def genfstab(self) -> None:
        self._run("genfstab")

    def finish(self) -> None:
        self._run("finish")


# ── stateless helpers (lib/disk.sh, lib/hardware.sh) ──────────────────────────

def has_uefi() -> bool:
    return os.path.isdir("/sys/firmware/efi")


def _stateless(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([STEP, *args], check=False, text=True, capture_output=True)


def parent_device_path(dev_path: Path) -> Path:
    res = _stateless("parent-device", str(dev_path))
    if res.returncode != 0 or not res.stdout.strip():
        raise ArchInstallError(f"could not determine the parent device of {dev_path}: {res.stderr.strip()}")
    return Path(res.stdout.strip())


def unique_device_path(dev_path: Path) -> Path | None:
    res = _stateless("unique-device-path", str(dev_path))
    if res.returncode != 0 or not res.stdout.strip():
        return None
    return Path(res.stdout.strip())


def target_has_package(target: Path, name: str) -> bool:
    return _stateless("target-has-package", str(target), name).returncode == 0
