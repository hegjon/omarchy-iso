#!/bin/bash
#
# A corrupt install medium is refused before the disk is touched. The root
# image ships on the ISO with its sha256 beside it; omarchy-root-image-verify
# checks it at boot and the installer's pre-flight phase takes that verdict.
# Flip one digit of the recorded checksum on a copy of the ISO (so the hash
# of the image no longer matches what the medium claims — the same verdict a
# badly flashed stick's damaged image produces), autoinstall from it, and
# assert: the unit fails, the install halts in "Preparing install target"
# telling the user to re-flash, nothing after that phase ran, and the target
# disk still has no partition table. (That the verify truly reads the whole
# multi-GB image is the slow-medium scenario's business, where the read is
# what is being timed.)
#
# Boots the ISO itself, not the installed base image, so it needs no base.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

CORRUPT_ISO="$BASE_DIR/corrupt.iso"
STREAM=arch/x86_64/omarchy-root.btrfs.zst
VERIFY_UNIT=omarchy-root-image-verify.service
GATE_UNIT=omarchy-install-prepare-target.service
PHASE_ERROR=/run/omarchy-install/phase-error.omarchy-install-prepare-target.service

# ------------------------------------------------------------------ fixture

# A copy of the ISO with one hex digit of the recorded sha256 flipped.
# ISO9660 carries no per-file integrity data, so patching in place leaves
# everything else on the medium intact (cp --reflink makes the copy free on
# btrfs). The 64-char digest is plain ASCII and unique on the ISO, so plain
# grep -F finds the checksum file's bytes; the flip stays within the hex
# alphabet so sha256sum reports a clean FAILED, not a format complaint.
corrupt_iso() {
  local digest flip start

  digest=$(bsdtar -xOf "$ISO" "$STREAM.sha256" | awk '{print $1}')
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || { echo "no recorded sha256 for $STREAM on the ISO" >&2; return 1; }
  [[ ${digest:0:1} == 0 ]] && flip=1 || flip=0

  log "Copying the ISO and mis-recording the root image's checksum"
  rm -f "$CORRUPT_ISO"
  cp --reflink=auto "$ISO" "$CORRUPT_ISO"
  # The digest is plain ASCII, so this works identically under GNU grep and
  # the ugrep Omarchy ships as grep (whose -P \xNN byte escapes do not).
  start=$(LC_ALL=C grep -Fboa -m1 -- "$digest" "$CORRUPT_ISO" | cut -d: -f1 || true)
  [[ -n $start ]] || { echo "recorded checksum not found in the ISO image" >&2; return 1; }

  printf '%s' "$flip" | dd of="$CORRUPT_ISO" bs=1 seek="$start" conv=notrunc status=none
  log "Recorded sha256 flipped: ${digest:0:8}... now reads ${flip}${digest:1:7}..."
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
  ssh_live_root "systemctl list-units --all --no-legend 'omarchy-install-*'; echo; cat /run/omarchy-install/phase-error.* 2>/dev/null" >"$RUN_DIR/phase-state" 2>/dev/null || true
  ssh_live_root "journalctl -b -u $VERIFY_UNIT -o short-precise --no-pager" >"$RUN_DIR/verify-unit.journal" 2>/dev/null || true
}

screen_shows() {
  ocr_screen | grep -qi "$1"
}

assert_refused() {
  check "verify unit failed on the corrupt image" \
    ssh_live_root "systemctl show -p Result --value $VERIFY_UNIT | grep -qx exit-code"
  check "install halted in the pre-flight phase" \
    ssh_live_root "[ \"\$(systemctl list-units --failed --plain --no-legend 'omarchy-install-*' | awk '{print \$1}')\" = $GATE_UNIT ]"
  check "the error tells the user to re-flash the medium" \
    ssh_live_root "grep -q 'install medium is corrupt: re-flash it' $PHASE_ERROR"
  check "the error carries sha256sum's verdict" \
    ssh_live_root "grep -q 'did NOT match' $PHASE_ERROR"
  check "nothing ran after the pre-flight phase" \
    ssh_live_root "journalctl -b -u omarchy-install-prepare-live.service --no-pager | grep -q Finished && [ \"\$(systemctl show -p ExecMainStartTimestampMonotonic --value omarchy-install-disk.service)\" = 0 ]"
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
