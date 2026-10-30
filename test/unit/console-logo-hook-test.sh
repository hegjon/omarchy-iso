#!/bin/bash
#
# The live initramfs hook that prints the Omarchy logo on tty1 lays it out
# for the console it finds: centred, a blank line above and below, the
# cursor left under it for the login line, and the 32 px font loaded first
# on a framebuffer console large enough to keep 80 columns at twice the
# glyph width. The hook is ash; its function is POSIX enough to source here,
# with the console, its size header, the logo and the font pointed at files.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/configs/airootfs/etc/initcpio/hooks/omarchy-logo"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
# expect <description> <string> <piece>...: the pieces occur in the string, in that order
expect() {
  local desc=$1 s=$2 piece; shift 2
  for piece in "$@"; do
    [[ $s == *"$piece"* ]] || { fail "$desc: got $2"; return; }
    s=${s#*"$piece"}
  done
  ok "$desc"
}
# ends <description> <string> <suffix>
ends() { if [[ $2 == *"$3" ]]; then ok "$1"; else fail "$1: got $2"; fi; }

# A 3-line, 10-column logo; the vcsa header is rows, columns as single bytes.
printf '%s\n' '▄▄▄▄▄▄▄▄▄▄' '█  LOGO  █' '▀▀▀▀▀▀▀▀▀▀' >"$work/logo.txt"
size() { printf '%b%b\000\000' "\\$(printf %03o "$1")" "\\$(printf %03o "$2")" >"$work/vcsa"; }
# shellcheck source=/dev/null
source "$HOOK"
export OMARCHY_TTY="$work/tty" OMARCHY_VCSA="$work/vcsa" OMARCHY_CONSOLE_LOGO="$work/logo.txt" OMARCHY_CONSOLE_FONT="$work/none.psf"
draw() { : >"$work/tty"; omarchy_console_logo; cat -v "$work/tty"; }

# 80x25 text console: 11 rows above, rows 12-14, 11 below; column 36; cursor on row 16.
size 25 80; out=$(draw)
expect "palette, clear and green before the logo" "$out" '^[]P01a1b26^[]P29ece6a^[[2J^[[32m^[['
expect "centred on 80x25: rows 12-14, column 36" "$out" '^[[32m^[[12;36H' '^[[13;36H' '^[[14;36H'
ends "colour reset and the cursor a blank line below" "$out" '^[[0m^[[16;1H'
expect "the logo text itself" "$out" 'LOGO'

# 1280x800 with the 8x16 font (50x160): large enough for the 32 px font, which
# the fake setfont installs by rewriting the size header to 25x80.
cat >"$work/setfont" <<EOS
#!/bin/bash
echo "setfont \$*" >>"$work/setfont.log"
printf '\\031\\120\\000\\000' >"$work/vcsa"
EOS
chmod 755 "$work/setfont"
: >"$work/font32.psf"; export OMARCHY_CONSOLE_FONT="$work/font32.psf"
size 50 160; out=$(PATH="$work:$PATH" draw)
expect "the 32 px font is loaded on a 160-column, 50-row console" "$(cat "$work/setfont.log" 2>/dev/null)" "setfont -C $work/tty $work/font32.psf"
expect "and the logo is laid out for the console after the font change" "$out" '^[[32m^[[12;36H'

# 1024x768 (48x128): tall enough, but 64 columns at 16 px would not hold 80.
rm -f "$work/setfont.log"; size 48 128; out=$(PATH="$work:$PATH" draw)
if [[ -e $work/setfont.log ]]; then fail "setfont called on a 128-column console"; else ok "the font stays 8x16 where 16 px glyphs would not fit 80 columns"; fi
expect "centred on 48x128: row 23, column 60" "$out" '^[[32m^[[23;60H'

# A console smaller than the logo: never a position below 1.
size 2 8; out=$(draw)
expect "a console smaller than the logo starts at 1,1" "$out" '^[[32m^[[1;1H'

# Nothing to draw with: no output, no error.
: >"$work/tty"; OMARCHY_CONSOLE_LOGO="$work/missing.txt" omarchy_console_logo
if [[ -s $work/tty ]]; then fail "wrote without a logo file"; else ok "no logo file, nothing written"; fi

exit "$((failures > 0))"
