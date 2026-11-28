#!/bin/bash
#
# Installing on a disk whose start holds an Amlogic bootloader, as the eMMC
# of an Amlogic TV box does (a Minix NEO U1, S905): its SoC loads the signed
# bootloader from byte 0 on, and the image leaves only bytes 440-511 free, for
# an MBR. A GPT, or archinstall's wipe of the disk's first KiB, overwrites it
# and the box no longer starts from its eMMC. The installer has to see the
# bootloader, partition with an MBR, and write nothing below the first
# partition but the MBR's own bytes.
#
# The disk is seeded with a synthetic stand-in laid out like that eMMC (no
# vendor bytes): the "@AML" header magic 16 bytes into sectors 0 and 1,
# recognisable filler in bytes 0-439 and sectors 1-2047, and the box's MBR
# (ESP at sector 2048, type ef, bootable; Linux behind it). The VM is an
# x86_64 UEFI one: what is checked is the installer's handling of the disk,
# and that the system it leaves boots (and unlocks) from an MBR ESP.
#
# Installs on its own disk, so it needs no base image.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
if [[ ! -f $CIDATA_IMG ]]; then
  detect_packages
  build_cidata
fi

SEED="$RUN_DIR/amlogic-seed.bin"
DISK="$RUN_DIR/amlogic.qcow2"
SIGNATURE=0x5eed1e55

python3 - "$SEED" "$DISK_GB" <<'PY'
import struct, sys

path, disk_gb = sys.argv[1], int(sys.argv[2])
sectors = disk_gb * 1024 * 1024 * 1024 // 512
seed = bytearray()
# Sector 0: filler where the image's first 440 bytes go, the header magic
# 16 bytes in (GXBB), then the MBR the box's eMMC has.
seed += bytes((i * 7 + 13) % 251 + 1 for i in range(440))
seed[16:20] = b"@AML"
def entry(boot, ptype, start, count):
    return struct.pack("<B3sB3sII", 0x80 if boot else 0, b"\0\0\0", ptype, b"\0\0\0", start, count)
seed += struct.pack("<I", 0x5EED1E55) + b"\0\0"
seed += entry(True, 0xEF, 2048, 4194304) + entry(False, 0x83, 4196352, sectors - 4196352 - 2048)
seed += bytes(32) + b"\x55\xaa"
# Sectors 1-2047: the rest of the image, the header magic 16 bytes into
# sector 1 (every generation), and each sector saying which it is.
for number in range(1, 2048):
    sector = f"AMLOGIC-SEED sector {number:04d} ".encode() * 32
    seed += sector[:512]
seed[528:532] = b"@AML"
assert len(seed) == 1024 * 1024
open(path, "wb").write(seed)
PY

seed_head=$(head -c 440 "$SEED" | sha256sum | cut -d' ' -f1)
seed_tail=$(tail -c +513 "$SEED" | sha256sum | cut -d' ' -f1)

# The seed at the start of an otherwise empty disk.
truncate -s "${DISK_GB}G" "$RUN_DIR/amlogic.raw"
dd if="$SEED" of="$RUN_DIR/amlogic.raw" conv=notrunc status=none
qemu-img convert -f raw -O qcow2 "$RUN_DIR/amlogic.raw" "$DISK"
rm -f "$RUN_DIR/amlogic.raw"

cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"

log "Installing unattended on a disk with an Amlogic bootloader at its start"
if ! install_unattended "$DISK" "$RUN_DIR/install-serial.log"; then
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/install-serial.log" >&2 2>/dev/null || true
  exit 1
fi

ssh_sudo "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
ssh_sudo "sfdisk -d /dev/vda" >"$RUN_DIR/sfdisk.txt" 2>/dev/null || true
ssh_sudo "efibootmgr -v" >"$RUN_DIR/efibootmgr.txt" 2>/dev/null || true
ssh_guest "cat /proc/cmdline" >"$RUN_DIR/cmdline.txt" 2>/dev/null || true
ssh_guest "lsblk -o NAME,TYPE,PTTYPE,PARTTYPE,FSTYPE,MOUNTPOINTS" >"$RUN_DIR/lsblk.txt" 2>/dev/null || true
pttype=$(ssh_guest "lsblk -dno PTTYPE /dev/vda" 2>/dev/null | tr -d '\r' || true)
head_hash=$(ssh_sudo "head -c 440 /dev/vda | sha256sum" 2>/dev/null | cut -d' ' -f1 || true)
tail_hash=$(ssh_sudo "head -c 1048576 /dev/vda | tail -c +513 | sha256sum" 2>/dev/null | cut -d' ' -f1 || true)
esp_source=$(ssh_guest "findmnt -no SOURCE /boot" 2>/dev/null | tr -d '\r' || true)

check "the installer found the Amlogic bootloader" grep -q "carries an Amlogic bootloader" "$RUN_DIR/omarchy-install.log"
check "the installer found it intact after partitioning" grep -q "Amlogic bootloader on .* is intact" "$RUN_DIR/omarchy-install.log"
check "the partition table is an MBR (got: ${pttype:-nothing})" test "$pttype" = dos
check "the MBR keeps the disk's signature" grep -qx "label-id: $SIGNATURE" "$RUN_DIR/sfdisk.txt"
check "the ESP is partition 1 at sector 2048, type ef, bootable" \
  grep -qE '^/dev/vda1 : start= +2048, size= +4194304, type=ef, bootable$' "$RUN_DIR/sfdisk.txt"
check "the root is partition 2, type 83" grep -qE '^/dev/vda2 : start= +4196352, .*type=83$' "$RUN_DIR/sfdisk.txt"
check "the MBR holds nothing else" test "$(grep -c '^/dev/vda' "$RUN_DIR/sfdisk.txt")" = 2
check "/boot is the MBR ESP (got: ${esp_source:-nothing})" test "$esp_source" = /dev/vda1
check "bytes 0-439 are the bootloader's, as seeded" test "$head_hash" = "$seed_head"
check "sectors 1-2047 are the bootloader's, as seeded" test "$tail_hash" = "$seed_tail"
check "the kernel finds the root by UUID, not by the MBR's PARTUUID" \
  bash -c 'grep -q "UUID=" "$1" && ! grep -q "PARTUUID=" "$1"' _ "$RUN_DIR/cmdline.txt"
check "the Limine boot entry starts the MBR ESP" grep -qi "Limine.*HD(1,MBR,$SIGNATURE," "$RUN_DIR/efibootmgr.txt"
check "the install did not lose track of its boot entry" \
  bash -c '! grep -q "discarded the .Limine. UEFI boot entry" "$1"' _ "$RUN_DIR/omarchy-install.log"
if [[ $ENCRYPT == true ]]; then
  root_type=$(ssh_guest 'lsblk -dno TYPE "$(findmnt -no SOURCE / | sed "s/\[.*//")"' 2>/dev/null | tr -d '\r' || true)
  check "the root is on LUKS (got: ${root_type:-nothing})" test "$root_type" = crypt
fi
capture_console "success-amlogic-mbr-first-boot"
stop_vm

log "Booting it again"
start_vm "$DISK" "$RUN_DIR/serial.log"
if ! wait_for_ssh 300 failure-amlogic-mbr-boot-ssh-timeout; then
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/serial.log" >&2 2>/dev/null || true
  exit 1
fi
state=$(ssh_guest "timeout 120 systemctl is-system-running --wait" 2>/dev/null | tr -d '\r' || true)
ssh_guest "systemctl --failed --no-legend --plain" >"$RUN_DIR/failed-units.txt" 2>/dev/null ||
  echo "could not query failed units over SSH" >"$RUN_DIR/failed-units.txt"
check "the second boot reaches a running system (got: ${state:-nothing})" test "$state" = running
check "no failed units" test ! -s "$RUN_DIR/failed-units.txt"
capture_console "success-amlogic-mbr-boot"
stop_vm

# And from outside, after two boots of the installed system.
qemu-img dd -f qcow2 -O raw bs=512 count=2048 if="$DISK" of="$RUN_DIR/disk-head.bin"
check "after both boots, bytes 0-439 are still as seeded" \
  test "$(head -c 440 "$RUN_DIR/disk-head.bin" | sha256sum | cut -d' ' -f1)" = "$seed_head"
check "after both boots, sectors 1-2047 are still as seeded" \
  test "$(tail -c +513 "$RUN_DIR/disk-head.bin" | sha256sum | cut -d' ' -f1)" = "$seed_tail"

finish
