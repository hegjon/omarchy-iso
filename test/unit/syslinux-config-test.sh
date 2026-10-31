#!/bin/bash
# shellcheck disable=SC2015 # ok/fail lines
#
# The BIOS boot menu's install medium entry boots from omarchy-logo.cfg, which
# puts the boot logo up first (configs/syslinux/). Its kernel command line is
# the menu's other entry's, Try Omarchy's, but for omarchy.try=1 and
# systemd.gpt_auto=0 there and vga=0x0f04 (keep the mode, and the logo's font
# with it) and vt.global_cursor_default=0 (no cursor under it) here: a change
# to one that misses the other shows up here.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SYSLINUX="$ROOT/configs/syslinux"
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# label_lines FILE LABEL: the lines of LABEL's block in FILE.
label_lines() { awk -v label="$2" '/^LABEL /{on = ($2 == label)} on' "$1"; }
words() { tr ' ' '\n' | grep -v '^$' | sort; }

menu=$(label_lines "$SYSLINUX/archiso_sys-linux.cfg" arch64)
logo=$(label_lines "$SYSLINUX/omarchy-logo.cfg" arch64)
try=$(label_lines "$SYSLINUX/archiso_sys-linux.cfg" arch64try)

grep -qx 'CONFIG /boot/syslinux/omarchy-logo.cfg /boot/syslinux/' <<<"$menu" && ok "the menu entry boots from omarchy-logo.cfg" || fail "the menu entry: $menu"
for key in LINUX INITRD; do
  if [[ $(grep "^$key " <<<"$logo") == "$(grep "^$key " <<<"$try")" ]]; then ok "$key as the Try entry's"; else fail "$key differs from the Try entry's"; fi
done
diff <(sed -n 's/^APPEND //p' <<<"$logo" | words | grep -vx -e 'vga=0x0f04' -e 'vt.global_cursor_default=0') \
  <(sed -n 's/^APPEND //p' <<<"$try" | words | grep -vx -e 'omarchy.try=1' -e 'systemd.gpt_auto=0') >/dev/null &&
  ok "the kernel command line is the Try entry's, but for vga=, the cursor and Try's own" ||
  fail "the kernel command lines differ beyond vga=, the cursor, omarchy.try= and systemd.gpt_auto="
grep -q '^APPEND .*\bvga=0x0f04\b' <<<"$logo" && ok "vga=0x0f04 keeps the mode and the logo's font" || fail "no vga=0x0f04"
for key in "FONT omarchy-logo.psf" "DISPLAY omarchy-logo.txt" "PROMPT 0" "TIMEOUT 0"; do
  grep -qx "$key" "$SYSLINUX/omarchy-logo.cfg" && ok "omarchy-logo.cfg: $key" || fail "omarchy-logo.cfg lacks $key"
done
for file in omarchy-logo.psf omarchy-logo.txt; do
  [[ -s $SYSLINUX/$file ]] && ok "$file is there" || fail "$file missing"
done

exit "$((failures > 0))"
