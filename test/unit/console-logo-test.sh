#!/bin/bash
#
# omarchy-console-logo fits the 81-column Omarchy logo to the 80-column VGA
# text console a BIOS machine boots with, so the live initramfs hook and the
# configurator can show it there. It must take out only columns that are blank
# in every line, the leftmost first, and take them out of every line alike:
# the M's top serif sits on a short line and has to move with the M below it.
# A logo with nothing blank to take out is an error, not a wrapped picture.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOOL="$ROOT/configs/airootfs/usr/local/bin/omarchy-console-logo"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

widest() { LC_ALL=C.UTF-8 awk '{ if (length > max) max = length } END { print max+0 }' "$1"; }

# 82 columns of block glyphs. Columns 2 and 5 are blank in every line (the
# last line ends before column 5), so those two go; column 1 is not, because
# the second line starts with a glyph. The short first line carries a serif
# that has to move with the glyphs below it.
rep() { local s='' i; for ((i = 0; i < $2; i++)); do s+=$1; done; printf '%s' "$s"; }
{
  printf '%s\n' '  ▄▄ ▄'
  printf '%s%s\n' '█ █▀ ' "$(rep █ 77)"
  printf '%s%s\n' '█ ▀▀ ' "$(rep ▀ 75)"
  printf '%s\n' '█ '
} >"$work/logo82.txt"
[[ $(widest "$work/logo82.txt") == 82 ]] || fail "fixture is not 82 columns wide"

"$TOOL" "$work/logo82.txt" "$work/out80.txt" 2>"$work/err.txt"
if [[ $(widest "$work/out80.txt") == 80 ]]; then ok "an 82-column logo comes out 80 wide"; else fail "expected 80 columns, got $(widest "$work/out80.txt")"; fi
expected=$(
  printf '%s\n' ' ▄▄▄'
  printf '%s%s\n' '██▀' "$(rep █ 77)"
  printf '%s%s\n' '█▀▀' "$(rep ▀ 75)"
  printf '%s\n' '█'
)
if [[ $(<"$work/out80.txt") == "$expected" ]]; then ok "the two leftmost all-blank columns went, from every line alike"; else fail "unexpected output:"; cat "$work/out80.txt"; fi
grep -q 'omarchy-console-logo: 80 columns' "$work/err.txt" || fail "no column count reported on stderr"
[[ $(wc -l <"$work/out80.txt") == 4 ]] || fail "line count changed"

# Already fitting: unchanged, byte for byte.
printf '%s\n' '█  █' '  ██' >"$work/logo4.txt"
"$TOOL" "$work/logo4.txt" "$work/out4.txt" 2>/dev/null
if cmp -s "$work/logo4.txt" "$work/out4.txt"; then ok "a logo that fits is left alone"; else fail "a fitting logo was changed"; fi

# Narrower target: columns 2 and 4 are blank in both lines; the third blank
# column does not exist, so 2 columns can go but not 3.
printf '%s\n' '█ █ █' '█ █ █' >"$work/logo5.txt"
"$TOOL" "$work/logo5.txt" "$work/out3.txt" 3 2>/dev/null
if [[ $(<"$work/out3.txt") == $'███\n███' ]]; then ok "takes out as many blank columns as the target needs"; else fail "unexpected 3-column output: $(<"$work/out3.txt")"; fi
if "$TOOL" "$work/logo5.txt" "$work/out2.txt" 2 2>"$work/err2.txt"; then
  fail "a logo with no blank column left still succeeded"
else
  if grep -q 'no blank column' "$work/err2.txt"; then ok "fails when nothing blank is left to take out"; else fail "wrong error: $(<"$work/err2.txt")"; fi
fi
[[ -e $work/out2.txt ]] && fail "wrote a destination on failure"

# A missing source is an error.
if "$TOOL" "$work/nope.txt" "$work/out-nope.txt" 2>/dev/null; then fail "a missing source succeeded"; else ok "a missing source fails"; fi

# The real logo, when the package that ships it is installed here.
if [[ -r /usr/share/omarchy/logo.txt ]]; then
  "$TOOL" /usr/share/omarchy/logo.txt "$work/real.txt" 2>/dev/null
  if (( $(widest "$work/real.txt") <= 80 )) && [[ $(wc -l <"$work/real.txt") == $(wc -l </usr/share/omarchy/logo.txt) ]]; then
    ok "the installed Omarchy logo fits 80 columns with its line count kept"
  else
    fail "the installed Omarchy logo did not fit: $(widest "$work/real.txt") columns"
  fi
fi

exit "$((failures > 0))"
