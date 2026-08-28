#!/bin/bash
#
# The offline mirror ships as ordinary files in the ISO9660 tree beside the root
# image, outside the squashfs, and is bind-mounted read-only back onto the path
# it always had. Nothing here boots an ISO: these are the wiring facts that
# decide whether an install can find a package at all, and each one is cheap to
# check and expensive to discover from a failed install.
#
# The staging runs for real against a throwaway mirror, so the builder is
# exercised rather than grepped.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
MOUNT_UNIT="$ROOT/configs/airootfs/etc/systemd/system/var-cache-omarchy-mirror-offline.mount"
WANTS="$ROOT/configs/airootfs/etc/systemd/system/local-fs.target.wants/var-cache-omarchy-mirror-offline.mount"
PROFILEDEF="$ROOT/configs/profiledef.sh"
CUSTOMIZE="$ROOT/configs/airootfs/root/customize_airootfs.sh"
STAGE_MIRROR="$ROOT/builder/stage-mirror-files.sh"
BUILD_ISO="$ROOT/builder/build-iso.sh"
INSTALL_SH="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/install.sh"
MIRROR_PATH="/var/cache/omarchy/mirror/offline"
MIRROR_ON_MEDIUM="/run/archiso/bootmnt/arch/x86_64/mirror"

failures=0

check() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description"
    failures=$((failures + 1))
  fi
}

# ------------------------------------------------------------- the mount unit

check "the mount unit exists" test -f "$MOUNT_UNIT"
check "it is wanted by local-fs.target" test -L "$WANTS"
check "the mount takes the mirror directory off the boot medium" \
  grep -qxF "What=$MIRROR_ON_MEDIUM" "$MOUNT_UNIT"
check "it mounts where the mirror has always been" \
  grep -qxF "Where=$MIRROR_PATH" "$MOUNT_UNIT"
check "it is a bind mount, not a second filesystem" grep -qxF "Type=none" "$MOUNT_UNIT"
check "it binds the medium's own directory" grep -qxF "Options=bind" "$MOUNT_UNIT"
# A medium that never carried the image (an older ISO, a netboot that lost it)
# must skip the unit rather than fail the boot into emergency mode.
check "a medium without the mirror skips the unit instead of failing the boot" \
  grep -qxF "ConditionPathExists=$MIRROR_ON_MEDIUM/offline.db.tar.gz" "$MOUNT_UNIT"
check "it waits for the boot medium to be mounted" \
  grep -qxF "RequiresMountsFor=/run/archiso/bootmnt" "$MOUNT_UNIT"

# --------------------------------------------------- what is left in the ISO

# The whole point of the move: the archives must not also be squashfs content.
check "the squashfs no longer carries an uncompressed mirror subtree" \
  bash -c "! grep -q 'uncompressed@subpathname' '$PROFILEDEF'"
check "the mount point is still declared for mkarchiso" \
  grep -qF '["/var/cache/omarchy/mirror/offline/"]' "$PROFILEDEF"
check "the live root's build fails if packages leak into the mount point" \
  grep -qF "mount point is not empty" "$CUSTOMIZE"
check "the build keeps the mirror out of the profile's airootfs" \
  grep -qxF "offline_mirror_dir=/var/cache/omarchy/mirror/offline" "$BUILD_ISO"
check "the mirror directory ships beside the root image" \
  grep -qF 'mirror_files_dir="$iso_payload_dir/mirror"' "$BUILD_ISO"
# The manifest lists what is checked and nothing else: the stream and the two
# databases. The packages carry their checksums in the repo database, which is
# what pacman and the pre-flight check both read, so listing them here too
# would be a second copy of the same fact -- most of it never read.
check "the checksum file is the root image stream's own" \
  grep -qF '(cd "$iso_payload_dir" && sha256sum "${root_image_stream##*/}" >"$root_image_stream.sha256")' "$BUILD_ISO"
check "it does not sweep the whole mirror in" \
  bash -c "! grep -qF 'find \"\${mirror_files_dir##*/}\" -maxdepth 1 -type f -print | sort' '$BUILD_ISO'"
# The mirror gets no checksum file of its own: its packages are covered by
# %SHA256SUM% in the repo database, and the databases by their own gzip CRC.
check "the mirror ships no checksum file of its own" \
  bash -c "! grep -qF 'omarchy-mirror.sha256' '$BUILD_ISO'"
# With nothing in the manifest that is not checked, the unit needs no filter.
check "the verify unit checks it whole, with nothing to filter" \
  grep -qxF 'ExecStart=/usr/bin/sha256sum --check --strict omarchy-root.btrfs.sha256' \
    "$ROOT/configs/airootfs/etc/systemd/system/omarchy-root-image-verify.service"
check "the root image verify waits for the boot medium to be mounted" \
  grep -qxF 'RequiresMountsFor=/run/archiso/bootmnt' \
    "$ROOT/configs/airootfs/etc/systemd/system/omarchy-root-image-verify.service"
check "its timeout is sized on the stream" \
  grep -qF 'payload_bytes=$(stat -c %s "$root_image_stream")' "$BUILD_ISO"
# The mirror is verified whole, before anything formats the disk.
MIRROR_UNIT="$ROOT/configs/airootfs/etc/systemd/system/omarchy-mirror-verify.service"
ORCH="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/root_image.sh"
check "a unit verifies the mirror" test -f "$MIRROR_UNIT"
check "it is enabled" test -L "$ROOT/configs/airootfs/etc/systemd/system/multi-user.target.wants/omarchy-mirror-verify.service"
check "it runs the whole-mirror verifier" \
  grep -qxF 'ExecStart=/usr/local/bin/omarchy-verify-mirror' "$MIRROR_UNIT"
# The verifier resolves the database's bare filenames against the working
# directory, so the unit has to put it in the mirror.
check "it runs the verifier in the mirror directory" \
  grep -qxF 'WorkingDirectory=/var/cache/omarchy/mirror/offline' "$MIRROR_UNIT"
check "the verifier takes the mirror from the working directory" \
  bash -c "grep -qxF 'DB=offline.db.tar.gz' '$ROOT/configs/airootfs/usr/local/bin/omarchy-verify-mirror' &&
    ! grep -qE '^[A-Z_]+=.?/var/cache/omarchy' '$ROOT/configs/airootfs/usr/local/bin/omarchy-verify-mirror'"
# Two readers on one USB stick seek against each other, which is why the
# wizard's prefetch already waits for the same unit.
check "it waits for the root image hash to finish" \
  grep -qxF "After=omarchy-root-image-verify.service" "$MIRROR_UNIT"
check "it runs at idle in both CPU and I/O" \
  bash -c "grep -qxF 'CPUSchedulingPolicy=idle' '$MIRROR_UNIT' && grep -qxF 'IOSchedulingClass=idle' '$MIRROR_UNIT'"
check "its timeout is sized on the packages it hashes" \
  grep -qF 'omarchy-mirror-verify.service.d' "$BUILD_ISO"
check "no per-package template unit is left behind" \
  bash -c "! test -e '$ROOT/configs/airootfs/etc/systemd/system/omarchy-verify-package@.service'"
# The point of the whole arrangement: nothing is formatted until the medium is
# proven, so the gate waits rather than collecting an opportunistic verdict.
check "the pre-flight gate waits for it" \
  grep -qF 'verify_offline_mirror' "$INSTALL_SH"
check "it waits before anything formats the disk" \
  bash -c "(( \$(grep -n 'verify_offline_mirror' '$INSTALL_SH' | head -1 | cut -d: -f1) < \$(grep -n 'fs_perform_filesystem_operations' '$INSTALL_SH' | head -1 | cut -d: -f1) ))"
# Both waits go through one helper, so the mirror inherits the state handling
# the root image path needed: the deactivating window a start timeout opens,
# a unit that is not loaded, and one that never ran.
check "the mirror wait goes through the shared helper" \
  grep -qF 'run_verify_helper "$MIRROR_VERIFY_UNIT" "the offline mirror"' "$ORCH"
check "so does the root image wait" \
  grep -qF 'run_verify_helper "$ROOT_IMAGE_VERIFY_UNIT" "the root image"' "$ORCH"
check "neither hand-rolls its own systemctl wait" \
  bash -c "! grep -qE 'systemctl start \"\\$(MIRROR|ROOT_IMAGE)_VERIFY_UNIT' '$ORCH'"

# ------------------------------------------------- verifying the mirror

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A payload fixture: a mirror with two packages the medium carries, one the
# root image provides, a sibling sharing a name prefix, and a repo database
# shaped the way repo-add writes one.
payload="$work/payload"
mkdir -p "$payload/mirror"
printf 'the kernel\n' >"$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst"
printf 'kernel signature\n' >"$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst.sig"
printf 'firmware\n' >"$payload/mirror/linux-firmware-1.0-1-x86_64.pkg.tar.zst"
db="$work/db"; rm -rf "$db"
desc_record() { # dir, filename, name
  mkdir -p "$db/$1"
  printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%SHA256SUM%%\n%s\n\n' \
    "$2" "$3" "$(sha256sum "$payload/mirror/$2" | cut -d' ' -f1)" >"$db/$1/desc"
}
desc_record linux-1.0-1 linux-1.0-1-x86_64.pkg.tar.zst linux
desc_record linux-firmware-1.0-1 linux-firmware-1.0-1-x86_64.pkg.tar.zst linux-firmware
# In the database because pacman has to resolve every name, but not on this
# medium: the root image provides it.
printf 'image-provided\n' >"$payload/mirror/coreutils-1.0-1-x86_64.pkg.tar.zst"
desc_record coreutils-1.0-1 coreutils-1.0-1-x86_64.pkg.tar.zst coreutils
rm -f "$payload/mirror/coreutils-1.0-1-x86_64.pkg.tar.zst"
tar -czf "$payload/mirror/offline.db.tar.gz" -C "$db" linux-1.0-1 linux-firmware-1.0-1 coreutils-1.0-1
printf 'files\n' | gzip >"$payload/mirror/offline.files.tar.gz"
# What the build recorded this medium as carrying.
printf '%s\n' linux-1.0-1-x86_64.pkg.tar.zst linux-firmware-1.0-1-x86_64.pkg.tar.zst >"$payload/shipped"
( cd "$payload" && printf 'root image\n' >omarchy-root.btrfs && sha256sum omarchy-root.btrfs >omarchy-root.btrfs.sha256 )

VERIFIER="$ROOT/configs/airootfs/usr/local/bin/omarchy-verify-mirror"
# Run from the mirror, the way the unit's WorkingDirectory does.
verify() { ( cd "$payload/mirror" && OMARCHY_SHIPPED_LIST="$payload/shipped" bash "$VERIFIER" ); }
# The unit's own command for the stream, run the way the unit runs it.
boot_scope() { ( cd "$payload" && sha256sum --check --strict --quiet omarchy-root.btrfs.sha256 ); }

check "an intact mirror verifies" verify
check "it says how many packages it checked" \
  bash -c "verify_out=\$(cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER'); [[ \$verify_out == 'verified 2 packages against the repo database' ]]"
check "the stream's own check passes" boot_scope
check "it names only the file it checks" \
  bash -c "(( \$(grep -c . '$payload/omarchy-root.btrfs.sha256') == 1 ))"
# Every way the medium can be wrong has to stop the install before it formats.
check "a damaged package fails it" \
  bash -c "printf 'damaged\n' >'$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' ) >/dev/null 2>&1"
check "and tells the user to re-flash" \
  bash -c "cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' 2>&1 | grep -q 're-flash'"
check "a package missing from the medium fails it" \
  bash -c "printf 'the kernel\n' >'$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst';
    mv '$payload/mirror/linux-firmware-1.0-1-x86_64.pkg.tar.zst' '$work/hidden';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' ) >/dev/null 2>&1;
    rc=\$?; mv '$work/hidden' '$payload/mirror/linux-firmware-1.0-1-x86_64.pkg.tar.zst'; exit \$rc"
check "a shipped package with no database record fails it" \
  bash -c "printf '%s\n' linux-1.0-1-x86_64.pkg.tar.zst nosuch-1.0-1-x86_64.pkg.tar.zst >'$work/badlist';
    printf 'x\n' >'$payload/mirror/nosuch-1.0-1-x86_64.pkg.tar.zst';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$work/badlist' bash '$VERIFIER' ) >/dev/null 2>&1"
check "an unreadable database fails it" \
  bash -c "cp '$payload/mirror/offline.db.tar.gz' '$work/db.good';
    printf 'not a gzip stream\n' >'$payload/mirror/offline.db.tar.gz';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' ) >/dev/null 2>&1;
    rc=\$?; cp '$work/db.good' '$payload/mirror/offline.db.tar.gz'; exit \$rc"
check "a missing shipped list fails it rather than passing" \
  bash -c "! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$work/nope' bash '$VERIFIER' ) >/dev/null 2>&1"
# Signatures are not read ([offline] is SigLevel = Never).
check "a damaged signature does not fail it" \
  bash -c "printf 'damaged\n' >'$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst.sig';
    cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' >/dev/null 2>&1"

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'offline mirror wiring holds\n'
