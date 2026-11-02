#!/bin/bash
# shellcheck disable=SC2015 # ok/fail lines
#
# The BIOS boot menu (configs/syslinux/) is menu.c32 on the VGA text console
# in the logo's font, with the logo's rows (omarchy-logo-menu.cfg, from
# bin/omarchy-isolinux-menu) where ISOLINUX's loading screen puts them. Its
# two entries boot through omarchy-logo.cfg and omarchy-logo-try.cfg, which
# put the logo up again and load the kernel under it: the two kernel command
# lines differ only by Try's own options, and both keep the mode, and the
# logo's font with it (vga=0x0f04), and hide the kernel's cursor under it.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SYSLINUX="$ROOT/configs/syslinux"
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# label_lines FILE LABEL: the lines of LABEL's block in FILE.
label_lines() { awk -v label="$2" '/^LABEL /{on = ($2 == label)} on' "$1"; }
words() { tr ' ' '\n' | grep -v '^$' | sort; }

install=$(label_lines "$SYSLINUX/archiso_sys-linux.cfg" arch64)
try=$(label_lines "$SYSLINUX/archiso_sys-linux.cfg" arch64try)
grep -qx 'CONFIG /boot/syslinux/omarchy-logo.cfg /boot/syslinux/' <<<"$install" && ok "Install boots from omarchy-logo.cfg" || fail "Install: $install"
grep -qx 'CONFIG /boot/syslinux/omarchy-logo-try.cfg /boot/syslinux/' <<<"$try" && ok "Try boots from omarchy-logo-try.cfg" || fail "Try: $try"

logo=$(label_lines "$SYSLINUX/omarchy-logo.cfg" arch64)
logo_try=$(label_lines "$SYSLINUX/omarchy-logo-try.cfg" arch64)
for key in LINUX INITRD; do
  if [[ $(grep "^$key " <<<"$logo") == "$(grep "^$key " <<<"$logo_try")" ]]; then ok "$key the same for Install and Try"; else fail "$key differs between Install and Try"; fi
done
diff <(sed -n 's/^APPEND //p' <<<"$logo" | words) \
  <(sed -n 's/^APPEND //p' <<<"$logo_try" | words | grep -vx -e 'omarchy.try=1' -e 'systemd.gpt_auto=0') >/dev/null &&
  ok "Try's kernel command line is Install's with omarchy.try=1 and systemd.gpt_auto=0" ||
  fail "the kernel command lines differ beyond Try's own options"
for cfg in omarchy-logo.cfg omarchy-logo-try.cfg; do
  grep -q '^APPEND .*\bvga=0x0f04\b.*\bvt.global_cursor_default=0\b' "$SYSLINUX/$cfg" && ok "$cfg keeps the mode and hides the cursor" || fail "$cfg: no vga=0x0f04 or cursor option"
  for key in "FONT omarchy-logo.psf" "DISPLAY omarchy-logo.txt" "PROMPT 0" "TIMEOUT 0"; do
    grep -qx "$key" "$SYSLINUX/$cfg" && ok "$cfg: $key" || fail "$cfg lacks $key"
  done
done
for file in omarchy-logo.psf omarchy-logo.txt; do
  [[ -s $SYSLINUX/$file ]] && ok "$file is there" || fail "$file missing"
done

# The menu: text mode in the logo's font, and the logo's rows as the
# generator writes them from the loading screen's logo.
grep -qx 'UI menu.c32' "$SYSLINUX/archiso_head.cfg" && grep -qx 'FONT omarchy-logo.psf' "$SYSLINUX/archiso_head.cfg" &&
  ok "the menu is menu.c32 in the logo's font" || fail "archiso_head.cfg: not menu.c32 in the logo's font"
grep -qx 'INCLUDE omarchy-logo-menu.cfg' "$SYSLINUX/archiso_sys-linux.cfg" && ok "the install medium's menu includes the logo's rows" || fail "no INCLUDE omarchy-logo-menu.cfg"
cmp -s <("$ROOT/bin/omarchy-isolinux-menu" "$SYSLINUX/omarchy-logo.txt") "$SYSLINUX/omarchy-logo-menu.cfg" &&
  ok "omarchy-logo-menu.cfg is the generator's, from omarchy-logo.txt" || fail "omarchy-logo-menu.cfg is stale: run bin/omarchy-isolinux-logo"

# Both entries centred under the logo: its width is its widest row.
width=$(LC_ALL=C awk '/^MENU LABEL /{ n = length($0) - 11; if (n > w) w = n } END { print w }' "$SYSLINUX/omarchy-logo-menu.cfg")
for label in arch64 arch64try; do
  block=$(label_lines "$SYSLINUX/archiso_sys-linux.cfg" "$label")
  text=$(sed -n 's/^MENU LABEL //p' <<<"$block" | tr -d '^')
  indent=$(sed -n 's/^MENU INDENT //p' <<<"$block")
  if [[ -n $indent ]] && (( indent == (width - ${#text}) / 2 )); then ok "$label centred under the logo ($indent of $width)"; else fail "$label: indent ${indent:-none}, want $(( (width - ${#text}) / 2 ))"; fi
done

exit "$((failures > 0))"
