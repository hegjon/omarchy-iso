#!/bin/bash
#
# omarchy-iso-cleanup-disk skips flock -x and O_RDWR wipefs on a clean disk so
# systemd-udevd never hits EAGAIN and delays udevadm settle, while keeping
# flock -x on a read-only descriptor across teardown, signature wiping, and
# blockdev --rereadpt on a used disk so closing the lock never fires
# IN_CLOSE_WRITE / forks (udev-synth), and triggering a change uevent wakes any
# postponed udev events immediately.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk"
DISK_PARTITIONING="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [[ -z ${2:-} ]] || echo "$2" >&2
  exit 1
}

# Call the script's own release_disk function against stubbed tools and a
# synthetic disk state.
run_case() {
  local mode=$1
  local log="$work/$mode.log"
  : >"$log"

  bash -euo pipefail -c '
    log=$1
    mode=$2
    script=$3
    work=$4
    disk_partitioning=$5
    disk="$work/fake-disk"
    rm -f "$disk"
    : >"$disk"
    disk_name="fake-disk"

    # shellcheck disable=SC1090
    source "$disk_partitioning"
    eval "$(awk "/^[a-z_]+\(\) \{$/ { p=1 } p { print } /^\}$/ { p=0 }" "$script")"

    partitions() {
      [[ $mode == "used" || $mode == "read-only" || $mode == "kernel-ro" || $mode == "keep-head" ]] && echo "fake-disk1" || true
      [[ $mode != "keep-head" ]] || echo "fake-disk2"
    }
    # keep-head: an Amlogic bootloader in the first MiB; fake-disk1 starts
    # inside it (sector 8), fake-disk2 behind it.
    if [[ $mode == "keep-head" ]]; then
      keep_head=1048576
      partition_start() { [[ $1 == fake-disk1 ]] && echo 4096 || echo 2097152; }
    fi
    [[ $mode != "read-only" ]] || chmod 444 "$disk"
    udevadm() { echo "udevadm $*" >>"$log"; }
    findmnt() { return 1; }
    swapoff() { echo "swapoff $*" >>"$log"; }
    # The lock descriptor'"'"'s access mode, from fdinfo: 0 is O_RDONLY, 2 is O_RDWR.
    flock() {
      echo "flock $*" >>"$log"
      local fd="${!#}"
      echo "lock-mode $(( $(awk "/^flags:/ { print \$2 }" "/proc/$$/fdinfo/$fd") & 3 ))" >>"$log"
    }
    blockdev() {
      echo "blockdev $*" >>"$log"
      if [[ ${1:-} == --getro ]]; then
        [[ $mode == "kernel-ro" ]] && echo 1 || echo 0
      fi
    }
    wipefs() {
      echo "wipefs $*" >>"$log"
      if [[ " $* " == *" --no-act "* ]]; then
        if [[ $mode == "keep-head" ]]; then
          # The disk: a signature inside the bootloader and one behind it.
          [[ " $* " == *" --output OFFSET "* ]] && printf "0x200\n0x40000000\n" || echo "0x438  ext4"
          return 0
        fi
        [[ $mode == "used" || $mode == "sig-only" ]] && echo "0x438  ext4" || true
      fi
    }

    release_disk
    $released
  ' _ "$log" "$mode" "$SCRIPT" "$work" "$DISK_PARTITIONING"
}

run_case clean
! grep -q '^flock ' "$work/clean.log" || fail "a clean disk must not take flock -x" "$(cat "$work/clean.log")"
! grep -q '^wipefs --all ' "$work/clean.log" || fail "a clean disk must not run O_RDWR wipefs --all" "$(cat "$work/clean.log")"
! grep -q '^udevadm trigger ' "$work/clean.log" || fail "a clean disk must not trigger a change uevent" "$(cat "$work/clean.log")"
grep -q '^blockdev --rereadpt ' "$work/clean.log" || fail "a clean disk still checks blockdev --rereadpt" "$(cat "$work/clean.log")"
echo "ok - clean disk skips flock -x, O_RDWR wipefs, and udevadm trigger"

run_case used
flock_line=$(grep -n '^flock -x ' "$work/used.log" | head -n1 | cut -d: -f1)
wipe_line=$(grep -n '^wipefs --all --force /dev/fake-disk1$' "$work/used.log" | head -n1 | cut -d: -f1)
reread_line=$(grep -n '^blockdev --rereadpt ' "$work/used.log" | head -n1 | cut -d: -f1)
trigger_line=$(grep -n '^udevadm trigger --action=change ' "$work/used.log" | head -n1 | cut -d: -f1)
final_settle_line=$(grep -n '^udevadm settle$' "$work/used.log" | tail -n1 | cut -d: -f1)
[[ -n $flock_line && -n $wipe_line && -n $reread_line && -n $trigger_line && -n $final_settle_line ]] ||
  fail "a used disk locks, wipes, re-reads, triggers change, and settles" "$(cat "$work/used.log")"
(( flock_line < wipe_line && wipe_line < reread_line && reread_line < trigger_line && trigger_line < final_settle_line )) ||
  fail "used disk ordering must be flock -> wipefs -> rereadpt -> trigger -> settle" "$(cat "$work/used.log")"
echo "ok - used disk locks, wipes signatures, re-reads, triggers change, and settles"
grep -qx 'lock-mode 0' "$work/used.log" ||
  fail "a used disk holds its lock on a read-only descriptor so close does not fork (udev-synth)" "$(cat "$work/used.log")"
echo "ok - used disk holds its lock on a read-only descriptor"

# A disk that cannot be opened for writing stops the cleanup before any
# teardown, with the reason on the last line for the failure screen. Root
# opens a mode 444 file anyway, so only an ordinary user can check this.
if ((EUID != 0)); then
  if out=$(run_case read-only); then
    fail "a disk that cannot be opened for writing must stop the cleanup" "$out"
  fi
  [[ $(tail -n 1 <<<"$out") == *"cannot be opened for writing and locked"* ]] ||
    fail "the last line says why the disk was not released" "$out"
  ! grep -q '^wipefs --all ' "$work/read-only.log" || fail "nothing is wiped without the lock" "$(cat "$work/read-only.log")"
  echo "ok - a disk that cannot be opened for writing stops before any wipe"
else
  echo "skip - the read-only disk case needs an ordinary user"
fi

# A kernel-marked read-only disk (blockdev --getro == 1) stops before any
# teardown or wipe, even when running as root on a writable-mode device node.
if out=$(run_case kernel-ro); then
  fail "a kernel read-only disk must stop the cleanup" "$out"
fi
[[ $(tail -n 1 <<<"$out") == *"cannot be opened for writing and locked"* ]] ||
  fail "the last line says why the kernel read-only disk was not released" "$out"
grep -q '^blockdev --getro ' "$work/kernel-ro.log" || fail "kernel read-only check queried blockdev --getro" "$(cat "$work/kernel-ro.log")"
! grep -qE '^(flock |swapoff |wipefs --all |blockdev --rereadpt )' "$work/kernel-ro.log" ||
  fail "nothing is locked, torn down, or wiped on a kernel read-only disk" "$(cat "$work/kernel-ro.log")"
echo "ok - a kernel read-only disk stops before releasing holders or wiping signatures"

run_case sig-only
grep -q '^flock -x ' "$work/sig-only.log" || fail "a disk with a whole-disk signature takes flock -x" "$(cat "$work/sig-only.log")"
grep -q '^wipefs --all --force --types nogpt,PMBR,dos ' "$work/sig-only.log" || fail "a disk with a whole-disk signature wipes it" "$(cat "$work/sig-only.log")"
grep -q '^udevadm trigger --action=change ' "$work/sig-only.log" || fail "a sig-only disk wakes postponed udev events after unlock" "$(cat "$work/sig-only.log")"
echo "ok - whole-disk signature without partitions is detected, wiped, and nudged"

# --keep-head: an Amlogic bootloader holds the disk's first MiB. Nothing is
# wiped inside it: not the partition that starts there, not the disk's own
# signature at 0x200, while the ones behind it go as on any other disk.
run_case keep-head
log="$work/keep-head.log"
grep -q '^wipefs --all --force /dev/fake-disk2$' "$log" || fail "a partition behind the kept bytes is wiped" "$(cat "$log")"
! grep -q '^wipefs --all --force /dev/fake-disk1$' "$log" || fail "a partition inside the kept bytes is not wiped" "$(cat "$log")"
grep -q "^wipefs --force --offset 0x40000000 $work/fake-disk$" "$log" || fail "a disk signature behind the kept bytes is wiped" "$(cat "$log")"
! grep -q -- '--offset 0x200' "$log" || fail "a disk signature inside the kept bytes is not wiped" "$(cat "$log")"
! grep -q -- "^wipefs --all --force --types nogpt,PMBR,dos $work/fake-disk$" "$log" ||
  fail "the disk is not wiped wholesale" "$(cat "$log")"
echo "ok - --keep-head wipes nothing inside the kept bytes, and the rest as before"

# settle_disk nudges a stranded udevadm settle when no lock is held on the disk,
# and stays quiet while another process actively holds a lock on the disk.
run_settle_case() {
  local held=$1
  local log="$work/settle-$held.log"
  : >"$log"

  bash -euo pipefail -c '
    log=$1
    held=$2
    script=$3
    work=$4
    disk_partitioning=$5
    disk="$work/settle-disk"
    flag="$work/nudged-$held"
    rm -f "$disk" "$flag"
    : >"$disk"

    # shellcheck disable=SC1090
    source "$disk_partitioning"
    _is_block_device() { [[ -f "$1" ]]; }
    eval "$(awk "/^[a-z_]+\(\) \{$/ { p=1 } p { print } /^\}$/ { p=0 }" "$script")"

    udevadm() {
      echo "udevadm $*" >>"$log"
      if [[ $1 == settle ]]; then
        local _
        for _ in $(seq 1 30); do
          [[ -e $flag ]] && return 0
          sleep 0.01
        done
        return 0
      elif [[ $1 == trigger ]]; then
        : >"$flag"
      fi
    }

    if [[ $held == locked ]]; then
      exec {holder}<"$disk"
      flock -s "$holder"
    fi
    settle_disk
    if [[ $held == locked ]]; then
      exec {holder}<&-
    fi
  ' _ "$log" "$held" "$SCRIPT" "$work" "$DISK_PARTITIONING"
}

run_settle_case unlocked
grep -q '^udevadm trigger --action=change ' "$work/settle-unlocked.log" ||
  fail "settle_disk must nudge a stuck settle when no lock is held" "$(cat "$work/settle-unlocked.log")"
echo "ok - settle_disk wakes a stranded settle when disk is unlocked"

run_settle_case locked
! grep -q '^udevadm trigger ' "$work/settle-locked.log" ||
  fail "settle_disk must not nudge while a udev worker holds LOCK_SH" "$(cat "$work/settle-locked.log")"
echo "ok - settle_disk leaves actively locked disks undisturbed"
