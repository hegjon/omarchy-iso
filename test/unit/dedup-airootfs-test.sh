#!/bin/bash
# shellcheck disable=SC2015 # ok/fail lines
#
# builder/dedup-airootfs.sh deletes from the live tree every file the root
# image holds byte for byte, except in the directories it keeps whole and the
# files the live boot reads (boot-files.sort), which mksquashfs lays out first
# in the live tree's squashfs. This runs its Python part on two plain
# directories in place of the mounted image.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

sed -n "/^python3 - .* <<'PY'$/,/^PY$/p" "$ROOT/builder/dedup-airootfs.sh" | sed '1d;$d' >"$work/dedup.py"
[[ -s $work/dedup.py ]] || { echo "FAIL: no Python part in dedup-airootfs.sh"; exit 1; }

live=$work/live image=$work/image
for tree in "$live" "$image"; do
  mkdir -p "$tree/usr/bin" "$tree/usr/lib/with space" "$tree/etc" "$tree/usr/share/omarchy-iso"
  echo same >"$tree/usr/bin/boot-read"
  echo same >"$tree/usr/bin/not-read"
  echo same >"$tree/usr/lib/with space/boot read"
  echo same >"$tree/etc/kept-whole"
done
echo live-only >"$live/usr/bin/differs"; echo image-only >"$image/usr/bin/differs"
printf '%s\n' "# a comment" "usr/bin/boot-read 32767" 'usr/lib/with\ space/boot\ read 32766' \
  >"$live/usr/share/omarchy-iso/boot-files.sort"
cp "$live/usr/share/omarchy-iso/boot-files.sort" "$image/usr/share/omarchy-iso/boot-files.sort"

out=$(python3 "$work/dedup.py" "$live" "$image" "$work/pseudo")
[[ -e $live/usr/bin/boot-read ]] && ok "a file the boot reads stays in the live tree" || fail "usr/bin/boot-read was removed"
[[ -e "$live/usr/lib/with space/boot read" ]] && ok "a sort file name with escaped spaces" || fail "the escaped name was removed"
[[ ! -e $live/usr/bin/not-read ]] && ok "the image's file the boot does not read goes" || fail "usr/bin/not-read stayed"
[[ -e $live/usr/bin/differs ]] && ok "a file that differs from the image's stays" || fail "usr/bin/differs was removed"
[[ -e $live/etc/kept-whole ]] && grep -qx '/etc x trusted.overlay.opaque=y' "$work/pseudo" && ok "/etc kept whole and opaque" || fail "/etc: $(cat "$work/pseudo")"
grep -q '2 files (0.0 MiB) of them for the boot' <<<"$out" && ok "the boot's files counted: $out" || fail "count: $out"

exit "$((failures > 0))"
