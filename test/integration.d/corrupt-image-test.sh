#!/bin/bash
#
# A corrupt install medium is refused before the disk is touched. The root
# image ships on the ISO with its sha256 beside it; omarchy-root-image-verify
# checks it at boot and the installer's pre-flight phase takes that verdict.
# Damage the image data on a copy of the ISO (the checksum stays right, the
# bytes under it don't: a badly flashed stick), autoinstall from it, and
# assert: the unit fails, the install halts in "Preparing install target"
# telling the user to re-flash, nothing after that phase ran, and the target
# disk still has no partition table.
#
# Boots the ISO itself, not the installed base image, so it needs no base.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

CORRUPT_ISO="$BASE_DIR/corrupt.iso"
STREAM=arch/x86_64/omarchy-root.btrfs
VERIFY_UNIT=omarchy-root-image-verify.service
STATE=/run/omarchy-install/state.json

# ------------------------------------------------------------------ fixture

# A copy of the ISO with 16 bytes of the root image overwritten (0xFF) a
# third of the way in, deep in extent data. ISO9660 carries no per-file integrity
# data, so patching in place leaves everything else on the medium intact
# (cp --reflink makes the copy free on btrfs). The stream is found by the
# NUL-terminated magic every btrfs send stream starts with; its length comes
# from the ISO's directory.
corrupt_iso() {
  local start size offset
  local damage='\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff'

  size=$(bsdtar -tvf "$ISO" "$STREAM" | awk '{print $5}')
  [[ $size =~ ^[0-9]+$ ]] || { echo "no root image on the ISO at $STREAM" >&2; return 1; }

  log "Copying the ISO and corrupting its root image"
  rm -f "$CORRUPT_ISO"
  cp --reflink=auto "$ISO" "$CORRUPT_ISO"
  start=$(grep -Pboa -m1 'btrfs-stream\x00' "$CORRUPT_ISO" | cut -d: -f1)
  [[ -n $start ]] || { echo "btrfs send stream magic not found in the ISO image" >&2; return 1; }

  offset=$((start + size / 3))
  echo -ne "$damage" | dd of="$CORRUPT_ISO" bs=1 seek="$offset" conv=notrunc status=none
  log "Image damaged at stream offset $((size / 3))"
}

# -------------------------------------------------------------------- phases

install_from_corrupt_medium() {
  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
  detect_packages
  build_cidata

  qemu-img create -f qcow2 "$RUN_DIR/disk.qcow2" 40G >/dev/null
  if [[ $FIRMWARE == uefi ]]; then
    cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
    ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
  fi

  log "Autoinstalling from the corrupt medium (headless)"
  start_vm "$RUN_DIR/disk.qcow2" "$RUN_DIR/serial.log" \
    -drive "file=$CORRUPT_ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  bootstrap_live_root_ssh

  log "Waiting for the installer to stop"
  local waited=0
  until ssh_live_root 'grep -q "installer child exited" /var/log/omarchy-install.log' 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited while waiting for the installer" >&2
      return 1
    fi
    if ((waited >= 600)); then
      capture_console "failure-installer-timeout"
      echo "Timed out waiting for the installer to stop" >&2
      return 1
    fi
    sleep 5
    ((waited += 5))
  done
  sleep 2
  capture_console "success-installer-stopped"
  ssh_live_root "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
  ssh_live_root "cat $STATE" >"$RUN_DIR/state.json" 2>/dev/null || true
  ssh_live_root "journalctl -b -u $VERIFY_UNIT -o short-precise --no-pager" >"$RUN_DIR/verify-unit.journal" 2>/dev/null || true
}

screen_shows() {
  ocr_screen | grep -qi "$1"
}

assert_refused() {
  check "verify unit failed on the corrupt image" \
    ssh_live_root "systemctl show -p Result --value $VERIFY_UNIT | grep -qx exit-code"
  check "install halted in the pre-flight phase" \
    ssh_live_root "jq -e '[.phases[] | select(.status == \"failed\") | .name] == [\"Preparing install target\"]' $STATE"
  check "the error tells the user to re-flash the medium" \
    ssh_live_root "jq -r '.phases[] | select(.status == \"failed\") | .error' $STATE | grep -q 'install medium is corrupt: re-flash it'"
  check "the error carries sha256sum's verdict" \
    ssh_live_root "jq -r '.phases[] | select(.status == \"failed\") | .error' $STATE | grep -q 'did NOT match'"
  check "nothing ran after the pre-flight phase" \
    ssh_live_root "jq -e '[.phases[] | select(.status == \"ok\") | .name] == [\"Preparing live environment\"]' $STATE"
  check "target disk has no partition table" \
    ssh_live_root "! lsblk -rno TYPE /dev/vda | grep -qx part && ! blkid /dev/vda"
  check "dashboard shows the installation stopped" \
    screen_shows "installation stopped"
  # The advice renders in the summary block's pink-on-dark, which OCR misses
  # (the same reason slow-medium asserts its advice from the log); the
  # dashboard's own log carries the identical line untruncated.
  check "dashboard shows the re-flash advice" \
    grep -q "failed phase: .*re-flash it" "$RUN_DIR/omarchy-install.log"
}

# ---------------------------------------------------------------------- main

corrupt_iso
install_from_corrupt_medium
assert_refused
rm -f "$CORRUPT_ISO"
finish
