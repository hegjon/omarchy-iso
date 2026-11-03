#!/bin/bash
#
# The boot logo is laid out where the installer's greeter will draw it
# (configs/airootfs/usr/share/omarchy-iso/console-logo.sh), so the greeter
# replaces it in place: the greeter's frame of logo, blank, tagline, blank and
# hint centred as a block, the logo centred at its own width, in the font the
# greeter will load. These cases run the layout against a fake console: the
# VT's size header, the framebuffer's sysfs directory, setfont, the logos.
#
# - The VGA text console (no framebuffer): the half-size logo in its own
#   font (vga-logo-font.py) at the greeter's place in half-size cells; without
#   that font the greeter's logo where it fits, the fitted copy where it does
#   not; no takeover glyph. The next layout on a framebuffer loads a whole
#   font back, and the console is cleared when the VGA console goes.
# - No display at all (no framebuffer, no VGA console): nothing until the
#   redraw has a framebuffer to draw on.
# - A UEFI framebuffer still behind the dummy console: an invisible full stop
#   first, then the layout for the size fbcon takes the console over at.
# - The font: 32 px from 1852x800 up, so 1920x1080 gets it and 1366x768,
#   1280x800 and 1600x900 keep 8x16; and the greeter's own font choice
#   (i18n_console_font) agrees for each.
# - omarchy-console-logo-redraw: only when a different framebuffer took over,
#   and never once the installer has tty1; with --wait, as soon as one does.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SHARE="$ROOT/configs/airootfs/usr/share/omarchy-iso"
REDRAW="$ROOT/configs/airootfs/usr/local/bin/omarchy-console-logo-redraw"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got '$2', expected '$3'"; fi; }
# expect <description> <string> <piece>...: the pieces occur in the string, in that order
expect() {
  local desc=$1 s=$2 got=$2 piece
  shift 2
  for piece in "$@"; do
    [[ $s == *"$piece"* ]] || { fail "$desc: got $got"; return; }
    s=${s#*"$piece"}
  done
  ok "$desc"
}
lacks() { if [[ $2 == *"$3"* ]]; then fail "$1: got $2"; else ok "$1"; fi; }
# screen <rows> <cols> [shown]: the console after the last layout, over a
# console showing the file shown (vt-screen.py), then which of shown's cells
# went blank on the way to showing the same again.
screen() { python3 "$ROOT/test/unit/vt-screen.py" "$@" <"$work/tty"; }
# layout <rows> <cols> <top> <left> <logo>: a console with only the logo on it.
layout() {
  local r line
  for ((r = 1; r <= $1; r++)); do
    if ((r >= $3)) && IFS= read -r line; then printf '%*s%s\n' $(($4 - 1)) '' "$line"; else echo; fi
  done <"$5"
}
# junk <rows> <cols>: a console full of x.
junk() { local r; for ((r = 0; r < $1; r++)); do printf "%${2}s\n" '' | tr ' ' x; done >"$work/junk"; }

# The logos: the greeter's 12 columns wide, the fitted copy 11; 3 rows each.
mkdir -p "$work/logo" "$work/share" "$work/bin" "$work/fb"
printf '%s\n' '▄▄▄▄▄▄▄▄▄▄▄▄' '█   LOGO   █' '▀▀▀▀▀▀▀▀▀▀▀▀' >"$work/logo/greeter.txt"
echo 12 >"$work/logo/greeter.cols"
printf '%s\n' '▄▄▄▄▄▄▄▄▄▄▄' '█  LOGO   █' '▀▀▀▀▀▀▀▀▀▀▀' >"$work/logo/fitted.txt"
echo 11 >"$work/logo/fitted.cols"
cp "$SHARE/console-logo.sh" "$work/share/"
: >"$work/share/console-20.psf"
: >"$work/share/console-16.psf"

# size <rows> <cols>: the VT's header in vcsa (rows, columns as single bytes).
size() { printf '%b%b\000\000' "\\$(printf %03o "$1")" "\\$(printf %03o "$2")" >"$work/vcsa"; }
# fb <xres> <yres> <name>, or fb none: the framebuffer's sysfs directory.
fb() {
  rm -rf "$work/fb"
  [[ $1 == none ]] && return
  mkdir -p "$work/fb"
  echo "$1,$2" >"$work/fb/virtual_size"
  echo "U:${1}x${2}p-0" >"$work/fb/modes"
  echo "$3" >"$work/fb/name"
}
# setfont records its call and, for the boot logo's 20 and 16 px fonts and
# the installer's 32 px one, sizes the console the way the real font change
# does. The kernel sizes the console from the framebuffer's mode, turned as
# fbcon turns the console: 16x32, 10x20 or 8x16 cells, the VT's header a byte
# each, 255 at most.
cat >"$work/bin/setfont" <<EOS
#!/bin/bash
echo "setfont \$*" >>"$work/setfont.log"
echo setfont >>"$work/order.log"
case \$* in *console-32.psf) cw=16 ch=32 ;; *console-20.psf) cw=10 ch=20 ;; *console-16.psf) cw=8 ch=16 ;; *) exit 0 ;; esac
read -r mode <"$work/fb/modes"; mode=\${mode#*:}; mode=\${mode%%[pi]*}
xres=\${mode%x*} yres=\${mode#*x}
read -r rotate <"$work/fbcon/rotate" 2>/dev/null || rotate=0
[[ \$rotate == [13] ]] && read -r xres yres <<<"\$yres \$xres"
printf '%b%b\000\000' "\\\\\$(printf %03o \$((yres / ch > 255 ? 255 : yres / ch)))" "\\\\\$(printf %03o \$((xres / cw > 255 ? 255 : xres / cw)))" >"$work/vcsa"
EOS
chmod 755 "$work/bin/setfont"

export OMARCHY_TTY="$work/tty" OMARCHY_VCSA="$work/vcsa" OMARCHY_FB="$work/fb"
export OMARCHY_CONSOLE_LOGO_DIR="$work/logo" OMARCHY_ISO_SHARE="$work/share" OMARCHY_RUN_DIR="$work/run"
export OMARCHY_VT_CURSOR="$work/global_cursor_default"
# fbcon's rotation: none, unless a case says otherwise.
mkdir -p "$work/fbcon"; echo 0 >"$work/fbcon/rotate"; export OMARCHY_FBCON="$work/fbcon"
export PATH="$work/bin:$PATH"
# shellcheck source=/dev/null
source "$SHARE/console-logo.sh"
draw() { : >"$work/tty"; rm -f "$work/setfont.log"; omarchy_console_logo; cat -v "$work/tty"; }
setfont_calls() { cat "$work/setfont.log" 2>/dev/null || true; }
# The console drivers: the VGA text console unless a case says otherwise.
export OMARCHY_VTCONSOLE="$work/vtconsole"
mkdir -p "$work/vtconsole/vtcon0"; echo "(S) VGA+" >"$work/vtconsole/vtcon0/name"

# No display at all: no framebuffer and no VGA console (a virtio GPU without
# VGA before its driver). Nothing is drawn, the layout is left to the redraw.
echo "(S) dummy device" >"$work/vtconsole/vtcon0/name"; fb none; size 25 80; out=$(draw)
check "no display: nothing drawn" "$out" ""
check "no display: recorded as laid out on no framebuffer, for the redraw" "$(cat "$work/run/console-logo")" none
echo "(S) VGA+" >"$work/vtconsole/vtcon0/name"

# The VGA text console: no framebuffer, 80x25. The greeter's 3-row logo in its
# 7-row frame starts on row 10; 12 columns centred on 80 start at column 35.
fb none; size 25 80; out=$(draw)
expect "VGA text: palette, cursor off and green before the logo" "$out" '^[]P01a1b26^[]P29ece6a^[[?25l^[[32m^[['
# Drawn over the console, not after a clear: over junk only the logo is
# left; over the logo already there (ISOLINUX's), none of it goes blank.
junk 25 80; layout 25 80 10 35 "$work/logo/greeter.txt" >"$work/shown"
check "VGA text: over a full console, only the logo is left" "$(screen 25 80 "$work/junk" | head -n 25)" "$(cat "$work/shown")"
check "VGA text: over the same logo, none of it goes blank" "$(screen 25 80 "$work/shown" | tail -n 1)" "flashed: none"
expect "VGA text: the greeter's logo on rows 10-12 at column 35" "$out" '^[[10;35H' '^[[11;35H' '^[[12;35H'
expect "VGA text: colour reset and the cursor a blank line below" "$out" '^[[0m^[[14;1H'
lacks "VGA text: no takeover glyph without a framebuffer" "$out" '.^[[0m^M'
check "VGA text: the kernel's font stays" "$(setfont_calls)" ""
check "VGA text: recorded as laid out on no framebuffer" "$(cat "$work/run/console-logo")" none
check "VGA text: consoles opened from here on get their cursor" "$(cat "$work/global_cursor_default")" 1

# A console narrower than the greeter's logo gets the fitted copy at column 1.
size 25 11; out=$(draw)
expect "11 columns: the fitted logo at column 1" "$out" '^[[10;1H' 'LOGO   '
# Its rows end in the last column, where erasing the rest of the row would
# take the last character with it.
junk 25 11; layout 25 11 10 1 "$work/logo/fitted.txt" >"$work/shown"
check "11 columns: over a full console, the logo to its last column" "$(screen 25 11 "$work/junk")" "$(cat "$work/shown"; echo "flashed: none")"
size 25 13; out=$(draw); junk 25 13; layout 25 13 10 1 "$work/logo/greeter.txt" >"$work/shown"
check "13 columns: the logo at column 1, over a full console" "$(screen 25 13 "$work/junk" | head -n 25)" "$(cat "$work/shown")"
check "13 columns: over the same logo, none of it goes blank" "$(screen 25 13 "$work/shown" | tail -n 1)" "flashed: none"

# The half-size logo in its font: 6 cells by 2 rows here. Its frame is the
# greeter's in half-size cells, so it starts on row (25-2-2)/2+1 = 11, at
# column (80-6)/2+1 = 38; the font is loaded first and the console marked.
vga=$'\uE000\uE001\uE002\uE003\uE004\uE005'
printf '%s\n' "$vga" "$vga" >"$work/logo/vga.txt"
echo 6 >"$work/logo/vga.cols"
: >"$work/logo/vga.psf"
fb none; size 25 80; out=$(draw)
check "VGA font: the logo's font is loaded" "$(setfont_calls)" "setfont -C $work/tty $work/logo/vga.psf"
expect "VGA font: the half-size logo on rows 11-12 at column 38" "$out" '^[[11;38H' '^[[12;38H'
expect "VGA font: in ISOLINUX's colors, bright green and the palette left alone" "$out" '^[[?25l^[[1;32m' '^[[11;38H'
layout 25 80 11 38 "$work/logo/vga.txt" >"$work/shown"
check "VGA font: over ISOLINUX's logo, none of it goes blank" "$(screen 25 80 "$work/shown" | tail -n 1)" "flashed: none"
junk 25 80
check "VGA font: over a full console, only the logo is left" "$(screen 25 80 "$work/junk" | head -n 25)" "$(cat "$work/shown")"
lacks "VGA font: the palette left alone" "$out" '^[]P'
if [[ -e $work/run/console-logo-vga ]]; then ok "VGA font: the console is marked as having the logo's font"; else fail "VGA font: no console-logo-vga marker"; fi
check "VGA font: the logo it drew left for the greeter" "$(cat "$work/run/vga.txt" "$work/run/vga.cols" 2>/dev/null)" "$(cat "$work/logo/vga.txt" "$work/logo/vga.cols")"
# The next layout, on a framebuffer, loads the 20 px font over the VGA logo's
# (whose blocks sit where the kernel's default font has them).
fb 1280 800 i915drmfb; size 50 160; out=$(draw)
check "after the VGA font: the 20 px font loaded on a 1280x800 framebuffer" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "after the VGA font: the greeter's logo on rows 17-19 at column 59" "$out" '^[[17;59H'
if [[ -e $work/run/console-logo-vga ]]; then fail "after the VGA font: the marker stayed"; else ok "after the VGA font: the marker goes"; fi
# A font that does not load leaves the full-size logo.
cat >"$work/bin/setfont-fail" <<'EOS'
#!/bin/bash
[[ $* == *vga.psf ]] && exit 1
exit 0
EOS
chmod 755 "$work/bin/setfont-fail"; mv "$work/bin/setfont" "$work/bin/setfont-ok"; mv "$work/bin/setfont-fail" "$work/bin/setfont"
fb none; size 25 80; out=$(draw)
expect "VGA font that does not load: the greeter's logo at full size, rows 10-12 at column 35" "$out" '^[[10;35H'
if [[ -e $work/run/console-logo-vga ]]; then fail "VGA font that does not load: marked anyway"; else ok "VGA font that does not load: not marked"; fi
mv "$work/bin/setfont" "$work/bin/setfont-fail"; mv "$work/bin/setfont-ok" "$work/bin/setfont"

# omarchy_console_vga_watch: clears the console once the VGA console is no
# longer a console driver, and only while the VGA logo is up.
export OMARCHY_VTCONSOLE="$work/vtconsole"
mkdir -p "$work/vtconsole/vtcon0"; echo "(S) VGA+" >"$work/vtconsole/vtcon0/name"
fb none; size 25 80; draw >/dev/null; : >"$work/tty"
omarchy_console_vga_watch 40 &
watcher=$!
sleep 0.3
check "VGA watch: nothing while the VGA console is there" "$(cat -v "$work/tty")" ""
echo "(S) dummy device" >"$work/vtconsole/vtcon0/name"
wait "$watcher"
check "VGA watch: the console cleared when it goes" "$(cat -v "$work/tty")" '^[[2J'
# fbcon has the console already (no longer 80x25): a layout is on its way,
# and a clear would wipe it.
: >"$work/run/console-logo-vga"; size 50 160; : >"$work/tty"
omarchy_console_vga_watch 4
check "VGA watch: no clear once fbcon has the console" "$(cat -v "$work/tty")" ""
size 25 80
rm -f "$work/run/console-logo-vga"; echo "(S) dummy device" >"$work/vtconsole/vtcon0/name"; : >"$work/tty"
omarchy_console_vga_watch 4
check "VGA watch: nothing without the VGA logo" "$(cat -v "$work/tty")" ""
rm -f "$work/logo/vga.txt" "$work/logo/vga.cols" "$work/logo/vga.psf"

# UEFI at 1920x1080: the dummy console's 80x25 until something is written.
# The takeover glyph goes out first; fbcon then makes it 240x67 (a tenth of a
# second later here), the 20 px font makes that 192x54, and the logo sits at
# row (54-7)/2+1 = 24, column (192-12)/2+1 = 91.
fb 1920 1080 simpledrmdrmfb; size 25 80
(sleep 0.15; size 67 240) &
out=$(draw)
wait
expect "UEFI 1920x1080: an invisible full stop wakes fbcon before anything else" "$out" '^[[30;40m.^[[0m^M' '^[]P01a1b26'
check "UEFI 1920x1080: the 20 px font is loaded" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "UEFI 1920x1080: laid out for 192x54, rows 24-26 at column 91" "$out" '^[[24;91H' '^[[25;91H' '^[[26;91H'
check "UEFI: recorded the framebuffer the logo is on" "$(cat "$work/run/console-logo")" simpledrmdrmfb

# OVMF's 1280x800 behind the dummy console: its 80x25 is that framebuffer in
# 16x32 cells, but while the dummy console is bound fbcon does not have tty1:
# the takeover glyph, the wait for 160x50, then the 20 px font's 128x40 and
# the layout for that (row 17, column 59).
mkdir -p "$work/vtconsole/vtcon1"; echo "(S) dummy device" >"$work/vtconsole/vtcon1/name"; echo 1 >"$work/vtconsole/vtcon1/bind"
fb 1280 800 simpledrmdrmfb; size 25 80
(sleep 0.15; echo 0 >"$work/vtconsole/vtcon1/bind"; size 50 160) &
out=$(draw)
wait
expect "UEFI 1280x800 behind the dummy console: waits for fbcon, laid out for 128x40" "$out" '^[[30;40m.^[[0m^M' '^[[17;59H'
rm -rf "$work/vtconsole/vtcon1"
# The same 80x25 a moment after fbcon has taken tty1 from the dummy console,
# before it resized it (a GPU driver's framebuffer where the firmware left
# none, QEMU's virtio-gpu-pci under UEFI): not the 1280x800 framebuffer in
# 16x32 cells, the layout waits for 160x50, then 128x40 in the 20 px font
# (row 17, column 59).
echo "BOOT_IMAGE=/vmlinuz quiet" >"$work/cmdline-plain"
fb 1280 800 virtio_gpudrmfb; size 25 80
(sleep 0.15; size 50 160) &
out=$(OMARCHY_CMDLINE="$work/cmdline-plain" draw)
wait
expect "UEFI 1280x800 just taken from the dummy console, still 80x25: laid out for 128x40" "$out" '^[[17;59H'
lacks "UEFI 1280x800 just taken from the dummy console: not laid out for 80x25 (row 5)" "$out" '^[[5;1H'
# Unless the command line names the font: fbcon=font:TER16x32 makes 80x25 the
# 1280x800 console it is, at once, no 2 s wait; the greeter's 20 px font is
# loaded over it, as the greeter would, and the logo laid out for 128x40
# (row 17, column 59), not for 80x25 to change at the greeter.
echo "BOOT_IMAGE=/vmlinuz quiet fbcon=font:TER16x32" >"$work/cmdline-font"
fb 1280 800 virtio_gpudrmfb; size 25 80
start=$(date +%s%N); out=$(OMARCHY_CMDLINE="$work/cmdline-font" draw); took=$(( ($(date +%s%N) - start) / 1000000 ))
check "fbcon=font:TER16x32 at 1280x800: the greeter's 20 px font loaded" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "fbcon=font:TER16x32 at 1280x800: laid out for 128x40" "$out" '^[[17;59H'
if (( took < 1000 )); then ok "fbcon=font:TER16x32 at 1280x800: no wait (${took} ms)"; else fail "fbcon=font:TER16x32 at 1280x800: waited ${took} ms"; fi
# fbcon=font:VGA8x8 at 1366x768 (170x96): the greeter's 20 px font loaded
# over the 8x8 too, laid out for 136x38 (row 16, column 63).
echo "BOOT_IMAGE=/vmlinuz quiet fbcon=font:VGA8x8" >"$work/cmdline-font8"
fb 1366 768 i915drmfb; size 96 170; out=$(OMARCHY_CMDLINE="$work/cmdline-font8" draw)
check "fbcon=font:VGA8x8 at 1366x768: the greeter's 20 px font loaded" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "fbcon=font:VGA8x8 at 1366x768: laid out for 136x38" "$out" '^[[16;63H'
# No font is loaded on a console fbcon does not have, whose 80x25 passes for
# 16x32 cells of the framebuffer: the dummy console still bound when the
# takeover's wait runs out (1600x900), and the VGA console with a GPU
# driver's framebuffer in sysfs before fbcon takes it over (BIOS, early i915,
# fbcon=font:): no load, and no second of loads that never take.
mkdir -p "$work/vtconsole/vtcon1"; echo "(S) dummy device" >"$work/vtconsole/vtcon1/name"; echo 1 >"$work/vtconsole/vtcon1/bind"
fb 1600 900 simpledrmdrmfb; size 25 80; draw >/dev/null
check "dummy console still bound after the wait: no font loaded" "$(setfont_calls)" ""
rm -rf "$work/vtconsole/vtcon1"
vga_name=$(cat "$work/vtconsole/vtcon0/name"); echo "(S) VGA+" >"$work/vtconsole/vtcon0/name"; echo 1 >"$work/vtconsole/vtcon0/bind"
fb 1280 800 i915drmfb; size 25 80; OMARCHY_CMDLINE="$work/cmdline-font" draw >/dev/null
check "VGA console bound, fbcon=font:: no font loaded" "$(setfont_calls)" ""
rm -f "$work/vtconsole/vtcon0/bind"; echo "$vga_name" >"$work/vtconsole/vtcon0/name"

# A GPU driver's framebuffer in sysfs while the console is still the old
# one's (1280x800's 160x50): the layout waits for fbcon to have it on the
# 2560x1440 one (320x90, which the VT's header holds as 90x255, a byte each,
# 255 at most; 256x72 in the 20 px font, centred on all 256 columns: row 33,
# column 123), not laid out for the old size at the new screen's top left.
fb 2560 1440 bochs-drmdrmfb; size 50 160
(sleep 0.15; size 90 255) &
out=$(draw)
wait
expect "a GPU driver's framebuffer: waits for the console to be on it, laid out for 256x72" "$out" '^[[30;40m.^[[0m^M' '^[[33;123H'
# A console fbcon turns a quarter turn (a portrait panel, rotate 1): as wide
# as the framebuffer is tall, on it already (240x75 on 1200x1920): no wait,
# no takeover glyph.
echo 1 >"$work/fbcon/rotate"
fb 1200 1920 i915drmfb; size 75 240
start=$(date +%s%N); out=$(draw); took=$(( ($(date +%s%N) - start) / 1000000 ))
lacks "rotated console: on the framebuffer already, no takeover glyph" "$out" '.^[[0m^M'
if (( took < 1000 )); then ok "rotated console: no wait (${took} ms)"; else fail "rotated console: waited ${took} ms"; fi
# A panel mounted in portrait and turned to landscape (a handheld's
# 1600x2560, where the kernel picks its own 16x32 font: 160x50): the 20 px
# font a landscape 2560x1600 gets, which the greeter keeps, laid out for
# 256x80 (rows 37-39, column 123).
fb 1600 2560 amdgpudrmfb; size 50 160; out=$(draw)
check "portrait panel turned to landscape: the 20 px font" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "portrait panel turned to landscape: laid out for 256x80, rows 37-39 at column 123" "$out" '^[[37;123H' '^[[38;123H' '^[[39;123H'
# A landscape 1920x1080 turned to portrait (fbcon=rotate:1): the kernel's
# 8x16, 135x120; the 20 px font, as 1080 pixels across hold the logo: 108x96,
# laid out at row 45, column 49.
fb 1920 1080 i915drmfb; size 120 135; out=$(draw)
check "landscape turned to portrait: the 20 px font" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "landscape turned to portrait: laid out for 108x96, row 45 at column 49" "$out" '^[[45;49H' '^[[46;49H' '^[[47;49H'
# A landscape 2560x1600 turned to portrait: the kernel picks its 16x32 by the
# area (100x80), the greeter's 20 px font goes over it: 160x128 (row 61,
# column 75).
fb 2560 1600 amdgpudrmfb; size 80 100; out=$(draw)
check "large landscape turned to portrait: the greeter's 20 px font over the kernel's 16x32" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "large landscape turned to portrait: laid out for 160x128, row 61 at column 75" "$out" '^[[61;75H' '^[[62;75H' '^[[63;75H'
echo 0 >"$work/fbcon/rotate"
# A laptop's 1280x800 panel with a 1920x1080 monitor plugged in: the GPU
# driver's surface is the monitor's size, the console the panel's mode, 160x50
# in the kernel's 8x16: no wait, the 20 px font by the panel's size, laid out
# for its 128x40 (rows 17-19, column 59).
fb 1280 800 i915drmfb; echo "1920,1080" >"$work/fb/virtual_size"; size 50 160
start=$(date +%s%N); out=$(draw); took=$(( ($(date +%s%N) - start) / 1000000 ))
if (( took < 1000 )); then ok "panel and monitor: no wait (${took} ms)"; else fail "panel and monitor: waited ${took} ms"; fi
check "panel and monitor: the 20 px font" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "panel and monitor: laid out for the panel's 128x40" "$out" '^[[17;59H'

# The 20 px font reset to the kernel's as fbcon finishes taking over: loaded
# again until the console counts 10-pixel cells, and laid out for that. Here
# the first two loads do nothing.
cp "$work/bin/setfont" "$work/bin/setfont.real"
cat >"$work/bin/setfont" <<EOS
#!/bin/bash
echo x >>"$work/setfont.tries"
(( \$(wc -l <"$work/setfont.tries") >= 3 )) && exec "$work/bin/setfont.real" "\$@"
echo "setfont \$*" >>"$work/setfont.log"
EOS
rm -f "$work/setfont.tries"
fb 1920 1440 bochs-drmdrmfb; size 90 240; out=$(draw)
check "20 px font reset by the takeover: loaded until it holds" "$(setfont_calls | wc -l)" 3
expect "20 px font reset by the takeover: laid out for 192x72, rows 33-35 at column 91" "$out" '^[[33;91H' '^[[34;91H' '^[[35;91H'
mv "$work/bin/setfont.real" "$work/bin/setfont"

# 1366x768 and 1280x800 get the 20 px font too (136x38, 128x40), the logo as
# wide as on every other screen; 800x600 and 640x480 keep the kernel's 8x16
# (100x37, 80x30): 80 and 64 columns of 10 pixels hold no 81-column logo.
fb 1366 768 i915drmfb; size 48 170; out=$(draw)
lacks "1366x768: already taken over, no takeover glyph" "$out" '.^[[0m^M'
check "1366x768: the 20 px font" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "1366x768: rows 16-18 at column 63" "$out" '^[[16;63H' '^[[17;63H' '^[[18;63H'
fb 1280 800 i915drmfb; size 50 160; out=$(draw)
check "1280x800: the 20 px font" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"
expect "1280x800: rows 17-19 at column 59" "$out" '^[[17;59H' '^[[18;59H' '^[[19;59H'
fb 800 600 i915drmfb; size 37 100; out=$(draw)
check "800x600: 8x16 kept" "$(setfont_calls)" ""
expect "800x600: rows 16-18 at column 45" "$out" '^[[16;45H' '^[[17;45H' '^[[18;45H'

# The initramfs's install hook adds both of the boot logo's fonts: the 20 px
# one for the rule, the 16 px one for small screens where the kernel picked
# its own 16x32 or 8x8.
# shellcheck disable=SC2329 # mkinitcpio's helpers, called by the sourced hook
hook_files=$(
  add_file() { echo "${2:-$1}"; }
  add_runscript() { :; }
  add_binary() { :; }
  warning() { :; }
  python3() { :; }
  # shellcheck source=/dev/null
  source "$ROOT/configs/airootfs/etc/initcpio/install/omarchy-logo"
  build
)
expect "initramfs: both of the boot logo's fonts" "$hook_files" /usr/share/omarchy-iso/console-20.psf /usr/share/omarchy-iso/console-16.psf
lacks "initramfs: not the installer's 32 px font" "$hook_files" /usr/share/omarchy-iso/console-32.psf

# The font rules: the boot logo's, which the greeter loads too
# (i18n_console_font TTY logo), and the installer's after it (i18n_console_font).
cp -r "$SHARE" "$work/share-i18n"
echo font >"$work/share-i18n/console-16.psf"
echo font >"$work/share-i18n/console-20.psf"
echo font >"$work/share-i18n/console-32.psf"
loaded_font() {  # loaded_font [logo]: the size i18n_console_font loads
  rm -f "$work/setfont.log"
  bash -c 'source "$1/i18n.sh"; i18n_console_font /dev/tty1 $2' _ "$work/share-i18n" "${1:-}" >/dev/null 2>&1 || true
  sed -n 's|.*/console-\([0-9]*\)\.psf$|\1|p' "$work/setfont.log" 2>/dev/null || true
}
for res in 640x480:16:16 800x600:16:16 1024x768:20:16 1280x800:20:16 1366x768:20:16 1600x900:20:16 1920x1080:20:32 2560x1440:20:32 1920x720:20:16 3840x2160:20:32; do
  IFS=x: read -r x y logo installer <<<"$res"
  fb "$x" "$y" x
  check "${x}x$y: the boot logo's font is $logo px" "$(omarchy_console_logo_font_size)" "$logo"
  check "${x}x$y: the greeter loads the same $logo px font" "$(loaded_font logo)" "$logo"
  check "${x}x$y: the installer's font is $installer px" "$(omarchy_console_font_size)" "$installer"
  check "${x}x$y: the installer's screens load it" "$(loaded_font)" "$installer"
done
# Turned a quarter turn by fbcon: by the size the console sees.
echo 1 >"$work/fbcon/rotate"
for res in 1600x2560:20:32 1200x1920:20:32 1080x1920:20:32 800x1280:20:16 1920x1080:20:16 600x800:16:16; do
  IFS=x: read -r x y logo installer <<<"$res"
  fb "$x" "$y" x
  check "${x}x$y turned: the boot logo's font is $logo px" "$(omarchy_console_logo_font_size)" "$logo"
  check "${x}x$y turned: the greeter loads the same $logo px font" "$(loaded_font logo)" "$logo"
  check "${x}x$y turned: the installer's font is $installer px" "$(omarchy_console_font_size)" "$installer"
done
echo 0 >"$work/fbcon/rotate"

# From the console the kernel makes to the greeter's font. fbcon starts the
# console in the kernel's default font, which get_default_font
# (lib/fonts/fonts.c) picks by the unturned framebuffer: 8x16 scores
# 20 - (X/8)*(Y/16)/1000 once that is over 20, TER16x32 has preference -1,
# so 16x32 from 22000 cells of 8x16 on. Whatever the kernel picked, the boot
# logo ends in the cells of the font the greeter loads: rows and columns of
# the turned framebuffer in 10x20 for 20 px, in 8x16 for 16 px.
kernel_console() {  # kernel_console X Y ROTATE
  local cw=8 ch=16 across=$1 down=$2
  (( ($1 / 8) * ($2 / 16) / 1000 >= 22 )) && cw=16 ch=32
  [[ $3 == [13] ]] && across=$2 down=$1
  size $((down / ch > 255 ? 255 : down / ch)) $((across / cw > 255 ? 255 : across / cw))
}
for rot in 0 1; do
  echo "$rot" >"$work/fbcon/rotate"
  for res in 640x480 800x600 1280x800 1366x768 1920x1080 1920x1200 1920x1440 2560x1080 2560x1440 2560x1600 3840x2160 5120x2880 4096x768 800x1280 1200x1920 1600x2560 1104x2560 1096x2560; do
    x=${res%x*} y=${res#*x} across=${res%x*} down=${res#*x}
    [[ $rot == 1 ]] && across=$y down=$x
    # The greeter's font first: its setfont resizes the fake console too.
    fb "$x" "$y" kerneldrmfb
    if [[ $(loaded_font logo) == 20 ]]; then cw=10 ch=20; else cw=8 ch=16; fi
    kernel_console "$x" "$y" "$rot"
    start=$(date +%s%N); draw >/dev/null; took=$(( ($(date +%s%N) - start) / 1000000 ))
    want="$((down / ch > 255 ? 255 : down / ch)) $((across / cw > 255 ? 255 : across / cw)) "
    check "$res, rotate $rot: the boot ends in the greeter's ${cw}x$ch cells (${took} ms)" "$(omarchy_console_size)" "$want"
    if (( $(setfont_calls | wc -l) <= 1 )); then ok "$res, rotate $rot: one font load at most"; else fail "$res, rotate $rot: $(setfont_calls | wc -l) font loads"; fi
  done
done
echo 0 >"$work/fbcon/rotate"

# The VGA text console with the greeter's 512-glyph font has eight foreground
# colors: dim text gets the normal color and secondary text 7, not 8.
muted() {
  : >"$work/tty"
  bash -c 'source "$1/i18n.sh"; i18n_console_font /dev/tty1; echo "$OMARCHY_ISO_MUTED"' _ "$work/share-i18n" 2>/dev/null
}
fb none; size 25 80
check "VGA text: secondary text in color 7" "$(muted)" 7
check "VGA text: dim text in the normal color" "$(cat -v "$work/tty")" '^[[2;7]'
fb 1280 800 x
check "framebuffer: secondary text in color 8" "$(muted)" 8
check "framebuffer: dim left alone" "$(cat -v "$work/tty")" ""

# omarchy-console-logo-redraw: redraws only for a framebuffer the logo is not
# laid out on yet, and only while the installer has not taken tty1.
redraw() { : >"$work/tty"; "$REDRAW"; cat -v "$work/tty"; }
mkdir -p "$work/run"; rm -f "$work/run/tty1-taken"
fb 1920 1080 simpledrmdrmfb; size 67 240; echo simpledrmdrmfb >"$work/run/console-logo"
check "redraw: udev's replay of the same framebuffer draws nothing" "$(redraw)" ""
fb 1920 1080 i915drmfb; size 67 240
expect "redraw: a GPU driver's framebuffer gets the logo again, in 20 px at row 24, column 91" "$(redraw)" '^[[24;91H'
check "redraw: records the new framebuffer" "$(cat "$work/run/console-logo")" i915drmfb
fb 1920 1080 amdgpudrmfb; : >"$work/run/tty1-taken"
check "redraw: nothing once the installer has tty1" "$(redraw)" ""
rm -f "$work/run/tty1-taken" "$work/run/console-logo"
check "redraw: nothing when no boot logo was drawn" "$(redraw)" ""
# A GPU driver's framebuffer in place of the firmware's while the layout is
# written: the logo is recorded as laid out on the firmware's, the one it was
# measured on, so the redraw for the driver's lays it out again (rows 24-26
# at column 91 in 20 px) instead of finding it laid out there already.
fb 1920 1080 simpledrmdrmfb; size 33 120
out=$(
  eval "real_$(declare -f omarchy_console_layout)"
  # shellcheck disable=SC2329 # called by the layout under test
  omarchy_console_layout() { echo bochs-drmdrmfb >"$work/fb/name"; real_omarchy_console_layout "$@"; }
  draw
)
check "framebuffer replaced during the layout: recorded as laid out on the one measured" "$(cat "$work/run/console-logo")" simpledrmdrmfb
expect "framebuffer replaced during the layout: the redraw lays the logo out on the new one" "$(redraw)" '^[[24;91H' '^[[25;91H' '^[[26;91H'
check "framebuffer replaced during the layout: the redraw records the new one" "$(cat "$work/run/console-logo")" bochs-drmdrmfb
rm -f "$work/run/console-logo"

# --wait: the i915 hook starts it inside the new root before switch_root, and
# it lays the logo out once the panel's framebuffer replaces the one the logo
# was drawn on (none on the VGA text console).
rm -f "$work/run/tty1-taken" "$work/run/console-logo"
fb none; size 25 80; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
check "redraw --wait: nothing while there is no framebuffer and no record" "$(cat -v "$work/tty")" ""
echo none >"$work/run/console-logo"; size 50 160; fb 1280 800 i915drmfb
wait "$waiter"
expect "redraw --wait: the logo for the panel's console once it is there, rows 17-19 at column 59" "$(cat -v "$work/tty")" '^[[17;59H' '^[[18;59H' '^[[19;59H'
check "redraw --wait: records the panel's framebuffer" "$(cat "$work/run/console-logo")" i915drmfb
# i915's framebuffer is registered before fbcon has the panel: the console
# stays 80x25 until the takeover's modeset is done.
echo none >"$work/run/console-logo"; fb 1280 800 i915drmfb; size 25 80; : >"$work/tty"
: >"$work/run/i915-loading"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
check "redraw --wait: nothing while fbcon is still taking the panel over" "$(cat -v "$work/tty")" ""
size 50 160
wait "$waiter"
expect "redraw --wait: laid out for the panel once fbcon has it, rows 17-19 at column 59" "$(cat -v "$work/tty")" '^[[17;59H' '^[[18;59H' '^[[19;59H'
if [[ -e $work/run/i915-loading ]]; then fail "redraw --wait: left the i915-loading marker"; else ok "redraw --wait: clears the i915-loading marker"; fi
# UEFI: the logo is on simpledrm until i915 takes the framebuffer over.
fb 1920 1080 simpledrmdrmfb; size 67 240; echo simpledrmdrmfb >"$work/run/console-logo"; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
check "redraw --wait: nothing while the logo's framebuffer is still there" "$(cat -v "$work/tty")" ""
fb 1920 1080 i915drmfb
wait "$waiter"
expect "redraw --wait: i915's framebuffer gets the logo in 20 px at row 24, column 91" "$(cat -v "$work/tty")" '^[[24;91H'
# The installer takes tty1 first, or no new framebuffer comes.
fb none; echo none >"$work/run/console-logo"; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.2; : >"$work/run/tty1-taken"; size 50 160; fb 1280 800 i915drmfb
wait "$waiter"
check "redraw --wait: nothing once the installer has tty1" "$(cat -v "$work/tty")" ""
rm -f "$work/run/tty1-taken"; fb none; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=4 "$REDRAW" --wait
check "redraw --wait: gives up when no framebuffer comes" "$(cat -v "$work/tty")" ""
# With the VGA logo up, it clears the console as soon as the VGA console
# goes, then lays the logo out on the framebuffer that comes, in a whole font.
echo none >"$work/run/console-logo"; : >"$work/run/console-logo-vga"; : >"$work/tty"
echo "(S) VGA+" >"$work/vtconsole/vtcon0/name"; fb none; size 25 80
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
echo "(S) dummy device" >"$work/vtconsole/vtcon0/name"
sleep 0.3
check "redraw --wait: clears the console when the VGA console goes" "$(cat -v "$work/tty")" '^[[2J'
rm -f "$work/setfont.log"; size 50 160; fb 1280 800 amdgpudrmfb
wait "$waiter"
expect "redraw --wait: then the logo for the framebuffer, rows 17-19 at column 59" "$(cat -v "$work/tty")" '^[[2J' '^[[17;59H'
check "redraw --wait: in the 20 px font" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-20.psf"

# --before-driver: udev, for a display controller before its driver loads.
# While the VGA logo is up it clears the console if a driver will load for the
# boot VGA device (or a virtio GPU on it), and leaves it alone when one is
# bound already, none exists, the device is another GPU, or no VGA logo is up.
mkdir -p "$work/sysfs/devices/pci0000:00/0000:00:02.0/virtio1" "$work/sysfs/devices/pci0000:00/0000:00:03.0"
echo 1 >"$work/sysfs/devices/pci0000:00/0000:00:02.0/boot_vga"
echo 0 >"$work/sysfs/devices/pci0000:00/0000:00:03.0/boot_vga"
echo "BOOT_IMAGE=/vmlinuz quiet" >"$work/cmdline"; export OMARCHY_CMDLINE="$work/cmdline"
cat >"$work/bin/modprobe" <<'EOS'
#!/bin/bash
[[ $* == *pci:v00001234* ]] && echo "insmod /lib/modules/x/kernel/drivers/gpu/drm/tiny/bochs.ko.zst"
[[ $* == *virtio:d00000010* ]] && echo "insmod /lib/modules/x/kernel/drivers/gpu/drm/virtio/virtio-gpu.ko.zst"
exit 0
EOS
chmod 755 "$work/bin/modprobe"
before() {  # before <modalias> [devpath]
  : >"$work/tty"
  OMARCHY_SYSFS="$work/sysfs" DEVPATH=${2:-/devices/pci0000:00/0000:00:02.0} MODALIAS=$1 "$REDRAW" --before-driver
  cat -v "$work/tty"
}
rm -f "$work/run/tty1-taken"; : >"$work/run/console-logo-vga"; size 25 80
check "before a driver: the console cleared when one will load" "$(before pci:v00001234d00001111sv0bc03sc00i00)" '^[[2J'
check "before a driver: cleared for a virtio GPU on the boot VGA device" "$(before virtio:d00000010v00001AF4 /devices/pci0000:00/0000:00:02.0/virtio1)" '^[[2J'
check "before a driver: nothing for another GPU's driver" "$(before pci:v00001234d00001111sv0bc03sc00i00 /devices/pci0000:00/0000:00:03.0)" ""
size 50 160
check "before a driver: no clear on a console another driver has already" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
size 25 80
check "before a driver: nothing when none exists for the device" "$(before pci:v0000ABCDd00000001sv0bc03sc00i00)" ""
mkdir -p "$work/sysfs/devices/pci0000:00/0000:00:02.0/driver"
check "before a driver: nothing when one is bound already" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
rmdir "$work/sysfs/devices/pci0000:00/0000:00:02.0/driver"; rm -f "$work/run/console-logo-vga"
check "before a driver: nothing without the VGA logo up" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""

# A second GPU: its driver waits while fb0 is missing or the firmware's and
# the boot VGA device has a driver bound or one to load, so that fb0, and
# fbcon's console from the VGA text console, is the boot device's; four
# seconds at most. Not the boot VGA device's own driver, not on a GPU
# driver's framebuffer, not without a boot VGA device or a driver for it.
# Counted in the helper's sleeps of 0.05 s (a stand-in that logs and sleeps).
mkdir -p "$work/sysfs/bus/pci/devices" "$work/sysfs/devices/pci0000:00/0000:00:03.0/virtio2" "$work/hold-bin"
ln -sfn "$work/sysfs/devices/pci0000:00/0000:00:02.0" "$work/sysfs/bus/pci/devices/0000:00:02.0"
ln -sfn "$work/sysfs/devices/pci0000:00/0000:00:03.0" "$work/sysfs/bus/pci/devices/0000:00:03.0"
boot_dev="$work/sysfs/devices/pci0000:00/0000:00:02.0"
bochs=pci:v00001234d00001111sv0bc03sc00i00 second=/devices/pci0000:00/0000:00:03.0
echo $bochs >"$boot_dev/modalias"
cat >"$work/hold-bin/sleep" <<EOS
#!/bin/bash
echo >>"$work/sleeps"
exec $(type -P sleep) "\$@"
EOS
# perl makes the freeze's KDSETMODE call: a stand-in records it.
cat >"$work/hold-bin/perl" <<EOS
#!/bin/bash
echo "kd \$4" >>"$work/order.log"
EOS
chmod 755 "$work/hold-bin/sleep" "$work/hold-bin/perl"
held() {  # held <modalias> <devpath> [steps]: the helper's sleeps
  rm -f "$work/sleeps"
  PATH="$work/hold-bin:$PATH" OMARCHY_REDRAW_HOLD_STEPS=${3:-80} before "$1" "$2" >/dev/null
  if [[ -e $work/sleeps ]]; then echo $(($(wc -l <"$work/sleeps"))); else echo 0; fi
}
fb none; : >"$work/run/console-logo-vga"; size 25 80
( sleep 0.4; fb 1280 800 bochs-drmdrmfb ) &
n=$(held $bochs $second); wait
if (( n >= 6 && n < 80 )); then ok "hold: another GPU's driver waits for the boot VGA device's framebuffer ($n sleeps)"; else fail "hold: another GPU's driver slept $n times, its framebuffer 0.4 s away"; fi
fb none
check "hold: a virtio GPU on another PCI device too, until its steps run out" "$(held virtio:d00000010v00001AF4 $second/virtio2 6)" 6
check "hold: not the boot VGA device's own driver" "$(held $bochs /devices/pci0000:00/0000:00:02.0)" 0
echo pci:v0000ABCDd00000001sv0bc03sc00i00 >"$boot_dev/modalias"
check "hold: not while the boot VGA device has no driver to load" "$(held $bochs $second)" 0
mkdir -p "$boot_dev/driver"
check "hold: while the boot VGA device has one bound" "$(held $bochs $second 4)" 4
rmdir "$boot_dev/driver"; echo $bochs >"$boot_dev/modalias"; echo 0 >"$boot_dev/boot_vga"
check "hold: not without a boot VGA device" "$(held $bochs $second)" 0
echo 1 >"$boot_dev/boot_vga"; fb 1280 800 bochs-drmdrmfb
check "hold: not on a GPU driver's framebuffer" "$(held $bochs $second)" 0
# UEFI: the firmware's framebuffer is fb0 until the boot device's driver
# replaces it, and the redraw for that one records it a moment later. This
# device's driver replaces nothing the logo is on then: no freeze, whether or
# not the boot device's step froze the console already.
rm -f "$work/run/console-logo-vga"
for frozen in no yes; do
  rm -f "$work/order.log" "$work/run/console-frozen"
  [[ $frozen == yes ]] && echo simpledrmdrmfb >"$work/run/console-frozen"
  fb 1280 800 simpledrmdrmfb; echo simpledrmdrmfb >"$work/run/console-logo"
  ( sleep 0.4; fb 1280 800 bochs-drmdrmfb; sleep 0.3; echo bochs-drmdrmfb >"$work/run/console-logo" ) &
  n=$(held $bochs $second); wait
  if (( n >= 6 && n < 80 )); then ok "hold, UEFI (frozen: $frozen): another GPU's driver waits for the boot device's framebuffer ($n sleeps)"; else fail "hold, UEFI (frozen: $frozen): another GPU's driver slept $n times, the boot device's framebuffer 0.4 s away"; fi
  check "hold, UEFI (frozen: $frozen): no freeze for it" "$(cat "$work/order.log" 2>/dev/null)" ""
done
fb none; rm -rf "$work/sysfs/bus"
rm -f "$work/run/console-logo" "$work/run/console-frozen" "$work/order.log" "$boot_dev/modalias"

# On a framebuffer the console is frozen instead: tty1 in graphics mode, the
# screen keeps the logo, nothing is drawn. The redraw for the driver's
# framebuffer erases the text kept for the old one while still frozen (fbcon
# shows black, not that text cut and scrolled), gives the text mode back, then
# loads its font; udev's replay of the frozen framebuffer changes nothing; the
# installer's claim gives the text mode back if no framebuffer came, the logo
# kept. perl makes the KDSETMODE call: a stand-in records the mode, or fails
# as without perl, or plays the installer claiming tty1 in the meantime.
cat >"$work/bin/perl" <<EOS
#!/bin/bash
[[ -e $work/no-perl ]] && exit 1
[[ -e $work/claim-meanwhile && \$4 == 1 ]] && : >"$work/run/tty1-taken"
echo "kd \$4" >>"$work/order.log"
EOS
chmod 755 "$work/bin/perl"
rm -f "$work/order.log" "$work/run/console-frozen"; echo simpledrmdrmfb >"$work/run/console-logo"
fb 1280 800 simpledrmdrmfb; size 50 160
check "before a driver, framebuffer: nothing drawn" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
check "before a driver, framebuffer: tty1 in graphics mode" "$(cat "$work/order.log")" "kd 1"
check "before a driver, framebuffer: marked frozen on its framebuffer" "$(cat "$work/run/console-frozen")" simpledrmdrmfb
check "before a driver, framebuffer: once" "$(before pci:v00001234d00001111sv0bc03sc00i00)$(cat "$work/order.log")" "kd 1"
: >"$work/tty"; "$REDRAW"
check "redraw, frozen: udev's replay of the frozen framebuffer changes nothing" "$(cat -v "$work/tty")$(cat "$work/order.log")" "kd 1"
rm -f "$work/order.log"; fb 1920 1080 bochs-drmdrmfb; size 67 240
expect "redraw, frozen: the old text erased, then the logo for the driver's framebuffer" "$(redraw)" '^[[2J' '^[[24;91H'
check "redraw, frozen: text mode back before the font loads" "$(cat "$work/order.log")" "$(printf 'kd 0\nsetfont')"
if [[ -e $work/run/console-frozen ]]; then fail "redraw, frozen: still marked frozen"; else ok "redraw, frozen: no longer marked frozen"; fi
rm -f "$work/order.log"; echo simpledrmdrmfb >"$work/run/console-logo"; fb 1280 800 simpledrmdrmfb; size 50 160
before pci:v00001234d00001111sv0bc03sc00i00 >/dev/null; : >"$work/tty"
omarchy_console_claim_tty1
check "claim, frozen: text mode back for the installer, the logo not erased" "$(cat -v "$work/tty")$(cat "$work/order.log")" "$(printf 'kd 1\nkd 0')"
if [[ -e $work/run/console-frozen ]]; then fail "claim, frozen: still marked frozen"; else ok "claim, frozen: no longer marked frozen"; fi
check "before a driver, framebuffer: nothing once the installer has tty1" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
rm -f "$work/run/tty1-taken" "$work/order.log"; : >"$work/claim-meanwhile"
before pci:v00001234d00001111sv0bc03sc00i00 >/dev/null
check "before a driver, framebuffer: a claim during the freeze gets the text mode back" "$(cat "$work/order.log")" "$(printf 'kd 1\nkd 0')"
if [[ -e $work/run/console-frozen ]]; then fail "claim during the freeze: still marked frozen"; else ok "claim during the freeze: not marked frozen"; fi
rm -f "$work/claim-meanwhile" "$work/run/tty1-taken" "$work/order.log"
before pci:v00001234d00001111sv0bc03sc00i00 >/dev/null; : >"$work/no-perl"
omarchy_console_claim_tty1
if [[ -e $work/run/console-frozen ]]; then ok "claim, text mode not back: the mark stays for the next try"; else fail "claim, text mode not back: mark gone"; fi
rm -f "$work/run/tty1-taken" "$work/run/console-frozen" "$work/order.log"
check "before a driver, framebuffer: nothing where tty1 can not be frozen" "$(before pci:v00001234d00001111sv0bc03sc00i00)$(cat "$work/order.log" 2>/dev/null)" ""
if [[ -e $work/run/console-frozen ]]; then fail "before a driver, no perl: marked frozen"; else ok "before a driver, no perl: not frozen"; fi
rm -f "$work/no-perl"; echo none >"$work/run/console-logo"
check "before a driver: nothing without a logo on the screen" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
echo i915drmfb >"$work/run/console-logo"
check "before a driver: nothing on a GPU driver's framebuffer already" "$(before pci:v00001234d00001111sv0bc03sc00i00 /devices/pci0000:00/0000:00:03.0)$(cat "$work/order.log" 2>/dev/null)" ""
echo "EFI VGA" >"$work/run/console-logo"
before pci:v00001234d00001111sv0bc03sc00i00 /devices/pci0000:00/0000:00:03.0 >/dev/null
check "before a driver: frozen on efifb, for any display controller's driver" "$(cat "$work/order.log" 2>/dev/null)" "kd 1"
omarchy_console_claim_tty1; rm -f "$work/run/tty1-taken" "$work/order.log"
echo "BOOT_IMAGE=/vmlinuz quiet nomodeset" >"$work/cmdline"
echo simpledrmdrmfb >"$work/run/console-logo"
check "before a driver, nomodeset: no freeze" "$(before pci:v00001234d00001111sv0bc03sc00i00)$(cat "$work/order.log" 2>/dev/null)" ""
: >"$work/run/console-logo-vga"; size 25 80
check "before a driver, nomodeset: the VGA logo kept" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
echo "BOOT_IMAGE=/vmlinuz quiet" >"$work/cmdline"
rm -f "$work/run/console-logo" "$work/run/console-logo-vga" "$work/order.log"

# One layout at a time: a redraw waits for one in progress (the lock), then
# finds the logo laid out on this framebuffer and draws nothing.
rm -f "$work/run/tty1-taken" "$work/run/console-logo-vga"; echo none >"$work/run/console-logo"
fb 1280 800 i915drmfb; size 50 160; : >"$work/tty"
( flock 9; sleep 0.5; echo i915drmfb >"$work/run/console-logo" ) 9>>"$work/run/console-logo.lock" &
holder=$!
sleep 0.1
start=$(date +%s%N); "$REDRAW"; took=$(( ($(date +%s%N) - start) / 1000000 ))
wait "$holder"
if (( took >= 300 )); then ok "redraw: waits for a layout in progress (${took} ms)"; else fail "redraw: did not wait for the lock (${took} ms)"; fi
check "redraw: then finds the logo laid out on this framebuffer and draws nothing" "$(cat -v "$work/tty")" ""

# No logo files: nothing drawn, no error.
export OMARCHY_CONSOLE_LOGO_DIR="$work/missing"
fb none; size 25 80
check "no logo files: nothing written" "$(draw)" ""

# omarchy_console_no_driver_coming: the configurator stops waiting for a
# wider console where no GPU driver will take the VGA one over.
dev="$work/sysfs/bus/pci/devices/0000:00:02.0"; other="$work/sysfs/bus/pci/devices/0000:00:1f.2"
mkdir -p "$dev" "$other"
echo 0x010601 >"$other/class"; echo pci:v00001234d00001111sv0sd0bc01sc06i01 >"$other/modalias"
echo 0x030000 >"$dev/class"
echo "BOOT_IMAGE=/vmlinuz quiet" >"$work/cmdline"
coming() { if OMARCHY_SYSFS="$work/sysfs" OMARCHY_CMDLINE="$work/cmdline" omarchy_console_no_driver_coming; then echo none; else echo coming; fi; }
fb none
echo pci:v00001002d00005046sv0sd0bc03sc00i00 >"$dev/modalias"
check "no driver coming: a card without a driver (ati-vga)" "$(coming)" none
echo pci:v00001234d00001111sv0sd0bc03sc00i00 >"$dev/modalias"
check "no driver coming: no, one will load (bochs)" "$(coming)" coming
echo "BOOT_IMAGE=/vmlinuz quiet nomodeset" >"$work/cmdline"
check "no driver coming: nomodeset" "$(coming)" none
echo "BOOT_IMAGE=/vmlinuz quiet" >"$work/cmdline"; mkdir "$dev/driver"
echo pci:v00001002d00005046sv0sd0bc03sc00i00 >"$dev/modalias"
check "no driver coming: no, one is bound, its framebuffer can still come" "$(coming)" coming
rmdir "$dev/driver"; fb 1280 800 bochs-drmdrmfb
check "no driver coming: no, there is a framebuffer" "$(coming)" coming
fb none

# omarchy_console_claim_tty1: the installer's first draw on tty1 marks it
# taken, after a layout that holds the lock has finished.
rm -f "$work/run/tty1-taken"
( flock 9; sleep 0.4 ) 9>>"$work/run/console-logo.lock" &
holder=$!
sleep 0.1
start=$(date +%s%N)
omarchy_console_claim_tty1
took=$((($(date +%s%N) - start) / 1000000))
wait "$holder"
if [[ -e $work/run/tty1-taken ]]; then ok "claim: tty1 marked taken"; else fail "claim: no tty1-taken marker"; fi
if ((took >= 200)); then ok "claim: waited for the layout holding the lock (${took} ms)"; else fail "claim: did not wait for the lock (${took} ms)"; fi
OMARCHY_RUN_DIR=/proc/omarchy-no-such-dir omarchy_console_claim_tty1 && ok "claim: no run directory, no failure" || fail "claim failed without a run directory"
# .automated_script.sh runs it under set -euo pipefail: a lock it cannot open
# must not end the login.
mkdir -p "$work/readonly"; chmod 500 "$work/readonly"
survived=$(OMARCHY_RUN_DIR="$work/readonly" bash -c 'set -euo pipefail; source "$1"; omarchy_console_claim_tty1; echo survived' _ "$SHARE/console-logo.sh" 2>/dev/null || true)
chmod 700 "$work/readonly"
check "claim: an unwritable run directory does not end a strict caller" "$survived" survived


# GRUB's logo where the console draws it (configs/grub/themes/omarchy/theme.txt,
# builder/logo-png.py): the boot logo's layout on screens of every common size,
# a logo as big as Omarchy's (81 columns, 10 rows), against the theme's place
# for its image. Equal to the pixel where the screen is a multiple of 20 wide
# and of 40 high, within one cell elsewhere.
export OMARCHY_CONSOLE_LOGO_DIR="$work/logo"
rm -f "$work/run/tty1-taken" "$work/run/console-frozen"
python3 - "$work/logo/greeter.txt" <<'PY'
import sys
lines = ["▄" * 81] + ["█" + " " * 79 + "█"] * 8 + ["▀" * 81]
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
echo 81 >"$work/logo/greeter.cols"
theme="$ROOT/configs/grub/themes/omarchy/theme.txt"
image=$(sed -n '/^+ image {/,/^}/p' "$theme")
theme_left=$(sed -n 's/^ *left = 50%-\([0-9]*\)$/\1/p' <<<"$image")
theme_top=$(sed -n 's/^ *top = 50%-\([0-9]*\)$/\1/p' <<<"$image")
check "theme: the logo image is the 81x10 logo in 10x20 cells" \
  "$(sed -n 's/^ *\(width\|height\) = \([0-9]*\)$/\2/p' <<<"$image" | paste -sd x)" 810x200
at_first_line=$'\e\\[([0-9]+);([0-9]+)H\xe2\x96\x84'
for res in 1024x768 1280x720 1280x800 1366x768 1440x900 1600x900 1680x1050 1920x1080 1920x1200 2256x1504 2560x1440 2560x1600 2880x1800 3000x2000 3840x2160; do
  x=${res%x*} y=${res#*x}
  fb "$x" "$y" simpledrmdrmfb; size $((y / 16)) $((x / 8 > 255 ? 255 : x / 8))
  draw >/dev/null
  # The first line's place: its cursor move right before its first ▄.
  [[ $(<"$work/tty") =~ $at_first_line ]] || { fail "$res: no logo line in the layout"; continue; }
  row=${BASH_REMATCH[1]} col=${BASH_REMATCH[2]}
  console_x=$(( (col - 1) * 10 )) console_y=$(( (row - 1) * 20 ))
  grub_x=$(( x / 2 - theme_left )) grub_y=$(( y / 2 - theme_top ))
  if (( x % 20 == 0 && y % 40 == 0 )); then
    check "$res: GRUB's logo exactly where the console draws it" "$grub_x,$grub_y" "$console_x,$console_y"
  elif (( grub_x - console_x > -10 && grub_x - console_x < 10 && grub_y - console_y > -20 && grub_y - console_y < 20 )); then
    ok "$res: GRUB's logo within a cell of the console's ($((grub_x - console_x)),$((grub_y - console_y)) px)"
  else
    fail "$res: GRUB's logo at $grub_x,$grub_y, the console's at $console_x,$console_y"
  fi
done
# logo-png.py draws each block as the console's 10x20 cells do: the image of
# "▀▄█ " is 40x20, the upper half of the first cell, the lower of the second,
# both of the third, none of the fourth; a glyph the console draws in its font
# is refused.
printf '%s\n' '▀▄█ ' >"$work/blocks.txt"
python3 "$ROOT/builder/logo-png.py" "$work/blocks.txt" 10 '#9ece6a' "$work/blocks.png"
check "logo-png: the blocks drawn as the console's cells" "$(python3 - "$work/blocks.png" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
width, height = struct.unpack(">II", data[16:24])
body, at = b"", 8
while at < len(data):
    n, kind = struct.unpack(">I4s", data[at:at + 8])
    if kind == b"IDAT":
        body += data[at + 8:at + 8 + n]
    at += 12 + n
raw = zlib.decompress(body)
stride = 1 + width * 4
lit = lambda x, y: raw[y * stride + 1 + x * 4 + 3] == 255 and raw[y * stride + 1 + x * 4:y * stride + 1 + x * 4 + 3] == bytes.fromhex("9ece6a")
cells = "".join("".join("#" if lit(c * 10 + 5, y) else "." for c in range(4)) + " " for y in (5, 15))
print(f"{width}x{height} {cells.strip()}")
PY
)" "40x20 #.#. .##."
printf '%s\n' 'OM' >"$work/letters.txt"
if python3 "$ROOT/builder/logo-png.py" "$work/letters.txt" 10 '#9ece6a' "$work/letters.png" 2>/dev/null; then
  fail "logo-png: drew letters, which the console draws in its font"
else
  ok "logo-png: refuses what is not a block"
fi

exit "$((failures > 0))"
