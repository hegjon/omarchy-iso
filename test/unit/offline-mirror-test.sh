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
# One manifest over both payloads, checked by one command from one directory.
check "one manifest covers the mirror and the root image" \
  grep -qF "xargs -r -d '\\n' sha256sum >sha256sums" "$BUILD_ISO"
check "the root image is the first entry in it" \
  grep -qF 'printf' <(grep -A2 'cd "$iso_payload_dir" &&' "$BUILD_ISO" | grep root_image_stream)
check "no per-payload checksum files are left behind" \
  bash -c "! grep -qE 'omarchy-mirror\\.sha256|root_image_stream\\.sha256' '$BUILD_ISO'"
check "the verify unit checks that manifest" \
  grep -qxF 'ExecStart=/usr/bin/sha256sum --check --strict sha256sums' \
    "$ROOT/configs/airootfs/etc/systemd/system/omarchy-root-image-verify.service"
check "its timeout is sized on everything the manifest covers" \
  grep -qF 'payload_bytes=$(du -sb --apparent-size "$root_image_stream" "$mirror_files_dir"' "$BUILD_ISO"
check "the installer refuses to pacstrap from an unmounted mirror" \
  grep -qF 'mountpoint -q "$source"' "$INSTALL_SH"

# ------------------------------------------------------------ the staged tree

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mirror="$work/mirror"
mkdir -p "$mirror"
shipped="ship-1.0-1-x86_64.pkg.tar.zst"
dropped="dropped-1.0-1-x86_64.pkg.tar.zst"
printf 'shipped archive\n' >"$mirror/$shipped"
printf 'shipped signature\n' >"$mirror/$shipped.sig"
printf 'the root image already provides this\n' >"$mirror/$dropped"
printf 'db\n' | gzip >"$mirror/offline.db.tar.gz"
ln -s offline.db.tar.gz "$mirror/offline.db"
printf '%s\n' "$shipped" >"$work/shipped.list"

if bash "$STAGE_MIRROR" "$mirror" "$work/shipped.list" "$work/staged" >"$work/stage.log" 2>&1; then
  printf 'ok - the mirror stages from a shipped selection\n'
else
  printf 'not ok - the mirror stages from a shipped selection\n'
  cat "$work/stage.log" >&2
  failures=$((failures + 1))
fi

check "the shipped package is staged, with its signature" \
  bash -c "test -f '$work/staged/$shipped' && test -f '$work/staged/$shipped.sig'"
check "the repo database is staged, symlink and all" \
  bash -c "test -f '$work/staged/offline.db.tar.gz' && test -L '$work/staged/offline.db'"
# What the root image already provides must not ship twice.
check "a package the root image provides stays out of the tree" \
  bash -c "! test -e '$work/staged/$dropped'"

# A selection naming a package the mirror does not have would silently ship a
# mirror an install then cannot resolve against.
printf '%s\nmissing-1.0-1-x86_64.pkg.tar.zst\n' "$shipped" >"$work/bad.list"
check "a selection naming a missing package fails the build" \
  bash -c "! bash '$STAGE_MIRROR' '$mirror' '$work/bad.list' '$work/bad' >/dev/null 2>&1"

: >"$work/empty.list"
check "an empty selection fails the build" \
  bash -c "! bash '$STAGE_MIRROR' '$mirror' '$work/empty.list' '$work/empty' >/dev/null 2>&1"

rm -f "$mirror"/offline.db*
check "a mirror with no repo database fails the build" \
  bash -c "! bash '$STAGE_MIRROR' '$mirror' '$work/shipped.list' '$work/nodb' >/dev/null 2>&1"

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'offline mirror wiring holds\n'
