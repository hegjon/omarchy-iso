# The Omarchy boot logo on tty1, laid out where the installer's greeter will
# draw it. POSIX sh: sourced by the live initramfs's hooks (busybox ash,
# etc/initcpio/hooks/omarchy-logo and omarchy-i915), by
# omarchy-console-logo-redraw in the live root, and by i18n.sh for the font
# rule. Sourced, not executed; nothing here may fail the caller.
#
# A BIOS machine boots on the VGA text console and gets a framebuffer only
# when its GPU driver loads; a UEFI machine has the firmware's framebuffer
# from the start but nothing draws on it. Either way the screen was black
# from the kernel's start until the greeter. The initramfs hook puts the
# logo on tty1 as the boot's first act, laid out the way the configurator's
# greeter() lays it out (logo, blank, tagline, blank, hint centred as a
# block, the logo centred at its own width), so the greeter draws over it in
# place: same font, same rows and columns.
#
# Three things decide the layout:
# - The console's size, from the VT's header in /dev/vcsa1. On a UEFI
#   machine fbcon defers taking the firmware framebuffer over until
#   something is written to the console, and a space does not count (the
#   dummy console ignores its erase character): until then the VT is the
#   dummy console's 80x25. omarchy_console_takeover writes an invisible full
#   stop and waits for the size to move.
# - The font (omarchy_console_logo_font_size): the 20 px Terminus, 10x20
#   cells, wherever the greeter's 81-column logo fits in them (a framebuffer
#   at least 810 pixels wide as the console sees it): the logo is then 810
#   pixels wide on every screen, the size GRUB's menu draws it at
#   (builder/boot-menu-theme.sh renders the same logo.txt ten pixels a logo
#   pixel), so the boot menu hands over to the boot's logo in place. 8x16
#   below that (640x480, 800x600). The greeter loads its font by the same
#   rule (i18n_console_font TTY logo); the installer's screens after it go
#   by omarchy_console_font_size, 16x32 from 1852x800 up. The kernel's own
#   font is not always 8x16 on a small screen: where it picked its 16x32 or
#   8x8 the 8x16 font is loaded here too.
# - The logo: the greeter's own (81 columns) on a framebuffer console, the
#   copy fitted to 80 columns (omarchy-console-logo) where that is narrower.
#   The VGA text console's cells are 9x16 pixels of a 720x400 picture
#   stretched over the panel, twice a framebuffer console's 8x16 on a
#   1280x800 one, so there the logo is drawn at half size in a font of its
#   own (vga-logo-font.py: each cell a 2x4 piece of its pixel grid), which
#   puts it at the greeter's size and place. A GPU driver taking the console
#   over draws its cells in the kernel's default font, where those pieces are
#   box drawing: omarchy_console_vga_watch clears the console when the VGA
#   console goes. The font is CP437 otherwise, like the kernel's, so the
#   greeter's logo needs no font loaded on the driver's console.
#
# The paths are variables for the unit test (test/unit/console-logo-hook-test.sh).

# omarchy_console_size: "rows cols " of tty1.
omarchy_console_size() {
    hexdump -n 2 -v -e '1/1 "%u "' "${OMARCHY_VCSA:-/dev/vcsa1}" 2>/dev/null
}

# omarchy_fb_size: "xres yres" of the framebuffer's mode, the one fbcon sizes
# the console by: the first of its modes (the mode it registered with). Its
# virtual size is the whole surface, which a GPU driver makes as big as its
# biggest output: a laptop's panel with a bigger monitor plugged in has the
# console on the panel's mode in the monitor's surface.
omarchy_fb_size() {
    local fb="${OMARCHY_FB:-/sys/class/graphics/fb0}" mode="" xres yres
    read -r mode 2>/dev/null <"$fb/modes"
    mode=${mode#*:}
    mode=${mode%%[pi]*}
    case $mode in
        [0-9]*x[0-9]*) echo "${mode%x*} ${mode#*x}" ;;
        *) [ -r "$fb/virtual_size" ] && IFS=, read -r xres yres <"$fb/virtual_size" && echo "$xres $yres" ;;
    esac
}

# omarchy_fb_turned_size: "across down", omarchy_fb_size as the console sees
# it: turned a quarter turn where fbcon turns the console, as it does for a
# panel mounted in portrait (a handheld's 1600x2560 is a 2560x1600 console)
# and for fbcon=rotate:.
omarchy_fb_turned_size() {
    local size rotate=0
    size=$(omarchy_fb_size)
    [ -n "$size" ] || return 0
    read -r rotate 2>/dev/null <"${OMARCHY_FBCON:-/sys/class/graphics/fbcon}/rotate"
    case $rotate in
        1 | 3) echo "${size#* } ${size% *}" ;;
        *) echo "$size" ;;
    esac
}

# omarchy_console_fits_fb: tty1 is the framebuffer's size in cells of 8x16,
# 8x8, 10x20 or 16x32 pixels (the kernel's fonts, the logo's 20 px one and
# the installer's 32 px one), turned as fbcon
# turns the console (omarchy_fb_turned_size): fbcon has tty1 on it. Columns
# and rows both: a framebuffer twice as wide as the one before has as many
# 16-pixel columns as the old console had 8-pixel ones. The VT's header holds
# each in a byte, 255 at most (2560 pixels of 8 read 255 columns, as do 2048
# of 8: both are told apart by the rows). Never while the dummy console or the
# VGA one is bound (a GPU driver's framebuffer is in sysfs before fbcon takes
# the VGA console over), and never 80x25 in 16x32 cells: that is a 1280x800
# framebuffer's console (OVMF's default mode), but also the dummy console's
# size, which tty1 keeps for a moment after fbcon has taken it from the dummy
# one (QEMU's virtio-gpu-pci under UEFI, no firmware framebuffer before it);
# neither the kernel nor the 32 px font's rule puts a 1280x800 framebuffer in
# 16x32 cells, only a font named on the command line (fbcon=font:) does.
omarchy_console_fits_fb() {
    local size across down cw con
    size=$(omarchy_fb_turned_size)
    across=${size% *} down=${size#* }
    [ "${across:-0}" -gt 0 ] 2>/dev/null && [ "${down:-0}" -gt 0 ] 2>/dev/null || return 1
    for con in "${OMARCHY_VTCONSOLE:-/sys/class/vtconsole}"/vtcon*; do
        case $(cat "$con/name" 2>/dev/null) in
            *dummy* | *VGA*) [ "$(cat "$con/bind" 2>/dev/null)" = 1 ] && return 1 ;;
        esac
    done
    # shellcheck disable=SC2046 # rows and columns, two words
    set -- $(omarchy_console_size)
    [ "${2:-0}" -gt 0 ] 2>/dev/null || return 1
    for cw in 8 10 16; do
        if [ "$cw" = 16 ] && [ "$1" -eq 25 ] && [ "$2" -eq 80 ]; then
            case " $(cat "${OMARCHY_CMDLINE:-/proc/cmdline}" 2>/dev/null) " in
                *" fbcon="*font:*) ;;
                *) continue ;;
            esac
        fi
        # The virtual height may count a second, panning screen.
        if [ "$2" -eq $((across / cw > 255 ? 255 : across / cw)) ] &&
            { [ "$1" -eq $((down / cw / 2 > 255 ? 255 : down / cw / 2)) ] ||
                [ "$1" -eq $((down / cw / 4 > 255 ? 255 : down / cw / 4)) ] ||
                { [ "$cw" = 8 ] && [ "$1" -eq $((down / 8 > 255 ? 255 : down / 8)) ]; }; }; then
            return 0
        fi
    done
    return 1
}

# omarchy_console_takeover: on a framebuffer the console is not on yet, the
# dummy console's 80x25 or the framebuffer a GPU driver just replaced, write
# a full stop in black on black so fbcon takes the console over, and give the
# takeover two seconds: on UEFI it runs from a workqueue as soon as something
# is written, and a GPU driver taking over from the VGA console or the
# firmware's framebuffer has its framebuffer in sysfs before the modeset of
# fbcon's takeover is done (in QEMU under load, longer than half a second; a
# layout made before then was for the old console, at its top left).
omarchy_console_takeover() {
    local tty="${OMARCHY_TTY:-/dev/tty1}" fb="${OMARCHY_FB:-/sys/class/graphics/fb0}" i=0
    [ -e "$fb" ] || return 0
    omarchy_console_fits_fb && return 0
    printf '\033[30;40m.\033[0m\r' 2>/dev/null >>"$tty"
    while [ "$i" -lt 40 ] && ! omarchy_console_fits_fb; do
        sleep 0.05
        i=$((i + 1))
    done
}

# omarchy_console_kd_mode 0|1: tty1 in text mode (0) or graphics mode (1),
# where the console keeps its text but draws none of it and the screen keeps
# what it shows. KDSETMODE, by perl: no command in the live root makes the
# call, and the initramfs, which has no perl, needs none. Fails where it can
# not (the caller goes on without).
omarchy_console_kd_mode() {
    command -v perl >/dev/null 2>&1 || return 1
    perl -e 'open(my $t, "+<", $ARGV[0]) or exit 1; ioctl($t, 0x4B3A, $ARGV[1] + 0) or exit 1' \
        "${OMARCHY_TTY:-/dev/tty1}" "$1" 2>/dev/null
}

# omarchy_console_thaw: tty1 back in text mode, if omarchy-console-logo-redraw
# put it in graphics mode ahead of a GPU driver (its --before-driver). The
# mark stays until that worked, for the next caller to try again.
omarchy_console_thaw() {
    local run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}"
    [ -e "$run/console-frozen" ] || return 0
    omarchy_console_kd_mode 0 && rm -f "$run/console-frozen"
}

# omarchy_console_claim_tty1: the installer draws on tty1 from here, and the
# boot logo is no longer laid out again when a GPU driver replaces the
# framebuffer, nor the VGA one cleared (omarchy-console-logo-redraw). Taken
# under the layout lock, so a layout in progress finishes first. Until then
# the redraw goes on after the login too: the login waits for udev to settle
# (omarchy-cidata-load), GPU drivers and all, before the configurator starts,
# and a driver that loaded after the login left the console blank until the
# greeter (test/boot-render with a udev rule that holds the driver back). A
# layout takes three seconds at most (the takeover's two, the 32 px font's
# one); the claim waits five, and never fails its caller (set -e). A console
# still in graphics mode for a GPU driver that brought no framebuffer gets
# its text mode back, or the installer would draw unseen: after the claim, so
# that a freeze the wait ran out on finds tty1 taken, or is found here.
omarchy_console_claim_tty1() {
    local run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}"
    mkdir -p "$run" 2>/dev/null || return 0
    {
        flock -w 5 9 || true
        : >"$run/tty1-taken"
        omarchy_console_thaw
    } 9>>"$run/console-logo.lock" 2>/dev/null || true
    return 0
}

# omarchy_console_no_driver_coming: true where no GPU driver will give tty1 a
# framebuffer any more: there is none, and either the kernel runs nomodeset or
# no display controller has a driver bound or one to load. The live login runs
# after udev has settled (omarchy-cidata-load), so by the configurator's first
# screen a driver that is coming has loaded or is loading.
omarchy_console_no_driver_coming() {
    local fb="${OMARCHY_FB:-/sys/class/graphics/fb0}" dev class alias cmdline=""
    [ -e "$fb" ] && return 1
    read -r cmdline <"${OMARCHY_CMDLINE:-/proc/cmdline}" 2>/dev/null
    case " $cmdline " in *" nomodeset "*) return 0 ;; esac
    for dev in "${OMARCHY_SYSFS:-/sys}"/bus/pci/devices/*; do
        read -r class <"$dev/class" 2>/dev/null || continue
        case $class in 0x03*) ;; *) continue ;; esac
        [ -e "$dev/driver" ] && return 1
        read -r alias <"$dev/modalias" 2>/dev/null || continue
        modprobe -n -b -v "$alias" 2>/dev/null | grep -q '^insmod ' && return 1
    done
    return 0
}

# omarchy_console_vga_bound: the VGA text console (vgacon) is still a console
# driver; a GPU driver unregisters it when it takes the hardware over.
omarchy_console_vga_bound() {
    grep -qs 'VGA' "${OMARCHY_VTCONSOLE:-/sys/class/vtconsole}"/vtcon*/name
}

# omarchy_console_vga_watch [STEPS]: while the half-size logo is up in its own
# font, clear tty1 as soon as the VGA console is gone, before fbcon shows its
# lines; a GPU driver's modeset leaves the screen dark in between. Only while
# the console is still the dummy one the driver put in its place (80x25): it
# shows nothing, and no layout can come before fbcon has the console. Once
# fbcon has it, a layout is on its way and a clear would wipe it. Polls every
# 0.05 s, STEPS times at most (default 200), and stops early once the
# initramfs is gone (the paths with it) or the installer has tty1.
omarchy_console_vga_watch() {
    local tty="${OMARCHY_TTY:-/dev/tty1}" run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}" i=0
    while [ "$i" -lt "${1:-200}" ] && [ -e "$run/console-logo-vga" ] && [ ! -e "$run/tty1-taken" ]; do
        if [ -d "${OMARCHY_VTCONSOLE:-/sys/class/vtconsole}" ] && ! omarchy_console_vga_bound; then
            [ "$(omarchy_console_size)" = "25 80 " ] && printf '\033[2J' 2>/dev/null >>"$tty"
            return 0
        fi
        sleep 0.05
        i=$((i + 1))
    done
}

# omarchy_console_font_size: 32 or 16, the installer's console font for this
# framebuffer (i18n_console_font), by its size as the console sees it: a
# portrait panel turned to landscape gets the font a landscape one of its
# size gets, and a landscape screen turned to portrait keeps the console
# wider than the logo.
omarchy_console_font_size() {
    local size across down
    size=$(omarchy_fb_turned_size)
    across=${size% *} down=${size#* }
    if [ "${across:-0}" -ge 1852 ] 2>/dev/null && [ "${down:-0}" -ge 800 ] 2>/dev/null; then
        echo 32
    else
        echo 16
    fi
}

# omarchy_console_logo_font_size: 20 or 16, the boot logo's and the greeter's
# console font for this framebuffer: 20 where the 81-column logo fits in its
# 10-pixel columns, by the size the console sees (omarchy_fb_turned_size).
omarchy_console_logo_font_size() {
    local size
    size=$(omarchy_fb_turned_size)
    if [ "${size%% *}" -ge 810 ] 2>/dev/null && [ "${size#* }" -ge 300 ] 2>/dev/null; then
        echo 20
    else
        echo 16
    fi
}

# omarchy_console_cells: the cells tty1 counts of the framebuffer as the
# console sees it: 16x32 (rows and columns both: the VT's header stops columns
# at 255, which 4096 pixels of 16 reach as 2048 of 8 do), 10x20 (as many rows
# as 20 pixels give, and no more columns than 10 give: 8x16 cells give more
# of both), 8x8 (more rows than 8x16 cells give: the kernel's font under 400
# pixels high, fbcon=font:), or 8x16.
omarchy_console_cells() {
    local size across down
    size=$(omarchy_fb_turned_size)
    across=${size% *} down=${size#* }
    # shellcheck disable=SC2046 # rows and columns, two words
    set -- $(omarchy_console_size)
    if [ "${1:-0}" -gt 0 ] 2>/dev/null && [ "$1" -le $((${down:-0} / 32)) ] && [ "${2:-0}" -le $((${across:-0} / 16)) ]; then
        echo 16x32
    elif [ "${1:-0}" -gt 0 ] 2>/dev/null && [ "$1" -le $((${down:-0} / 20)) ] && [ "${2:-0}" -le $((${across:-0} / 10)) ]; then
        echo 10x20
    elif [ "${1:-0}" -gt $((${down:-0} / 16)) ] 2>/dev/null; then
        echo 8x8
    else
        echo 8x16
    fi
}

# omarchy_console_font TTY FONT CELLS: load FONT, and again until the console
# counts its CELLS (omarchy_console_cells). A font loaded as fbcon takes a GPU
# driver's framebuffer over can be reset to the kernel's when the takeover
# finishes: the logo was then laid out at 8x16, and jumped to 16x32 at the
# greeter (QEMU under load, BIOS at 1920x1440). A second at most.
omarchy_console_font() {
    local tty="$1" font="$2" cells="$3" i=0
    while :; do
        setfont -C "$tty" "$font" 2>/dev/null
        [ "$(omarchy_console_cells)" = "$cells" ] && return 0
        [ "$i" -lt 10 ] || return 0
        sleep 0.1
        i=$((i + 1))
    done
}

# omarchy_console_layout TOP LEFT ROWS COLS LOGO_COLS FILE: the escapes that
# draw FILE's lines from row TOP, column LEFT, on a ROWS x COLS console, over
# what it shows rather than after clearing it: the rows above erased, each
# line drawn with what is left and right of it erased, the rows below erased.
# A logo on the screen already, cell for cell (ISOLINUX's, the boot's under
# the greeter), stays up instead of going dark for a clear (a frame of black
# in QEMU, where each of the clear's writes to the VGA's memory leaves the
# guest). Erasing the rest of a row that ends in the last column would erase
# that column (the VT holds the cursor there until the next character), so
# such rows are erased first. LOGO_COLS is the widest line's width.
omarchy_console_layout() {
    local top="$1" left="$2" rows="$3" cols="$4" logo_cols="$5" file="$6" row line
    [ "$top" -gt 1 ] && printf '\033[%d;%dH\033[1J' "$((top - 1))" "$cols"
    row=$top
    while IFS= read -r line; do
        if [ $((left + logo_cols)) -gt "$cols" ]; then
            printf '\033[%d;1H\033[2K\033[%d;%dH%s' "$row" "$row" "$left" "$line"
        elif [ "$left" -gt 1 ]; then
            printf '\033[%d;1H\033[%dX\033[%d;%dH%s\033[K' "$row" "$((left - 1))" "$row" "$left" "$line"
        else
            printf '\033[%d;1H%s\033[K' "$row" "$line"
        fi
        row=$((row + 1))
    done <"$file"
    [ "$row" -le "$rows" ] && printf '\033[%d;1H\033[J' "$row"
    return 0
}

omarchy_console_logo() {
    local tty="${OMARCHY_TTY:-/dev/tty1}" fb="${OMARCHY_FB:-/sys/class/graphics/fb0}"
    local dir="${OMARCHY_CONSOLE_LOGO_DIR:-/usr/share/omarchy-iso/console-logo}"
    local share="${OMARCHY_ISO_SHARE:-/usr/share/omarchy-iso}" run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}"
    local logo rows cols logo_rows logo_cols top left row line fb_name=none size frame=4 screen i turned cells
    [ -e "$tty" ] || return 0
    omarchy_console_takeover
    # The framebuffer the layout is for, read before the console is measured:
    # one a GPU driver puts in its place while the layout is made is not taken
    # as laid out, and its redraw lays the logo out again.
    [ -r "$fb/name" ] && read -r fb_name <"$fb/name"
    size=$(omarchy_console_logo_font_size)
    logo=greeter
    if [ ! -e "$fb" ] && ! omarchy_console_vga_bound; then
        # No display yet: a GPU with neither a firmware framebuffer nor VGA
        # (QEMU's virtio-gpu-pci on UEFI) shows nothing until its driver
        # loads, and fbcon would then show this layout, made for the dummy
        # console's 80x25, at the top left of the driver's framebuffer until
        # the redraw. The console stays empty; the redraw draws the logo.
        mkdir -p "$run" 2>/dev/null && echo none 2>/dev/null >"$run/console-logo"
        [ -w /dev/kmsg ] && echo "omarchy-logo: no display yet, the logo waits for a framebuffer" 2>/dev/null >/dev/kmsg
        return 0
    fi
    if [ ! -e "$fb" ]; then
        # The VGA text console: the half-size logo, in its font.
        if [ -r "$dir/vga.psf" ] && [ -r "$dir/vga.txt" ] && setfont -C "$tty" "$dir/vga.psf" 2>/dev/null; then
            logo=vga
            frame=2
        fi
    elif [ "$size" = 20 ] && [ -r "$share/console-20.psf" ] && omarchy_console_fits_fb; then
        # Only once fbcon has tty1: on the dummy or the VGA console a load
        # never takes, and the retries would hold the logo back a second.
        omarchy_console_font "$tty" "$share/console-20.psf" 10x20
    elif [ -r "$share/console-16.psf" ] && [ "$(omarchy_console_cells)" != 8x16 ] && omarchy_console_fits_fb; then
        # The kernel's own 16x32 where the rule and the greeter have 8x16: it
        # picks that font by the framebuffer's unturned area, from 22000 cells
        # of 8x16 (get_default_font, lib/fonts/fonts.c): a 2560x1440 screen
        # turned to portrait, a portrait panel the kernel does not turn; its
        # 8x8 under 400 pixels high; fbcon=font:. Kept, the logo would change
        # size at the greeter. Only on the framebuffer: the dummy console's
        # and the VGA one's 80x25 can pass for 16x32 cells of one.
        omarchy_console_font "$tty" "$share/console-16.psf" 8x16
    fi
    # shellcheck disable=SC2046 # rows and columns, two words
    set -- $(omarchy_console_size)
    rows=${1:-25}
    cols=${2:-80}
    # The VT's header holds 255 at most, and the 20 px font's columns pass
    # that from 2560 pixels on: there the console is the framebuffer's size
    # in its cells, which the greeter (stty) counts too. Laid out for 255
    # columns, the logo sat 640 pixels left of the middle of a 3840x2160
    # screen until the greeter drew it in the middle.
    if { [ "$cols" -ge 255 ] || [ "$rows" -ge 255 ]; } && omarchy_console_fits_fb; then
        turned=$(omarchy_fb_turned_size)
        cells=$(omarchy_console_cells)
        [ "$cols" -ge 255 ] && cols=$((${turned%% *} / ${cells%x*}))
        [ "$rows" -ge 255 ] && rows=$((${turned#* } / ${cells#*x}))
    fi

    # The widths come from the generator's sidecars: busybox's awk and wc
    # count bytes, and the block glyphs are three each.
    if [ "$logo" = vga ]; then
        logo_cols=$(cat "$dir/vga.cols" 2>/dev/null)
    else
        logo_cols=$(cat "$dir/greeter.cols" 2>/dev/null)
        if [ ! -r "$dir/greeter.txt" ] || ! [ "${logo_cols:-0}" -gt 0 ] 2>/dev/null || [ "$cols" -lt "$logo_cols" ]; then
            logo=fitted
            logo_cols=$(cat "$dir/fitted.cols" 2>/dev/null)
        fi
    fi
    [ "${logo_cols:-0}" -gt 0 ] 2>/dev/null || logo_cols=80
    [ -r "$dir/$logo.txt" ] || return 0
    logo_rows=$(wc -l <"$dir/$logo.txt")
    # The greeter's frame: logo, blank, tagline, blank, hint; in half-size
    # cells those four lines are two.
    top=$(((rows - logo_rows - frame) / 2 + 1))
    [ "$top" -lt 1 ] && top=1
    left=$(((cols - logo_cols) / 2 + 1))
    [ "$left" -lt 1 ] && left=1
    screen=$(
        if [ "$logo" = vga ]; then
            # ISOLINUX put this logo up already, in its colors: bright green
            # on the VGA palette's black (configs/syslinux/omarchy-logo.txt).
            # Drawn the same, it stays as it is; the installer's palette
            # comes with a GPU driver's framebuffer or the login.
            printf '\033[?25l\033[1;32m'
        else
            # Palette entries 0 and 2 as .automated_script.sh sets them later.
            printf '\033]P01a1b26\033]P29ece6a\033[?25l\033[32m'
        fi
        omarchy_console_layout "$top" "$left" "$rows" "$cols" "$logo_cols" "$dir/$logo.txt"
        printf '\033[0m\033[%d;1H' "$((top + logo_rows + 1))"
    )
    # In one write, and again on a fresh open if that fails: login hangs tty1
    # up as it starts the session (util-linux login's vhangup), and a layout
    # it cut off half way left the console cleared and the logo missing until
    # the greeter (QEMU under load, one BIOS boot in six; the journal had the
    # layout, the screen only its clear).
    i=0
    while [ "$i" -lt 3 ]; do
        printf '%s' "$screen" 2>/dev/null >>"$tty" && break
        i=$((i + 1))
        sleep 0.05
    done

    # Which framebuffer the logo is laid out for: omarchy-console-logo-redraw
    # compares it, and .automated_script.sh leaves the logo up while it exists.
    # console-logo-vga: the console has the VGA logo's font; vga.txt and
    # vga.cols beside it are the logo on the screen, for the greeter to keep
    # (the configurator's greeter_vga; the live root has no copy of its own).
    if mkdir -p "$run" 2>/dev/null; then
        echo "$fb_name" 2>/dev/null >"$run/console-logo"
        if [ "$logo" = vga ]; then
            : 2>/dev/null >"$run/console-logo-vga"
            cp "$dir/vga.txt" "$dir/vga.cols" "$run/" 2>/dev/null
        else
            rm -f "$run/console-logo-vga"
        fi
    fi
    [ -w /dev/kmsg ] && echo "omarchy-logo: ${cols}x$rows on $fb_name, $logo logo at row $top column $left" 2>/dev/null >/dev/kmsg
    # The BIOS boot starts without a cursor, so none shows below ISOLINUX's
    # logo (configs/syslinux/omarchy-logo.cfg); tty1 keeps its own hidden,
    # the consoles opened from here on get theirs.
    echo 1 2>/dev/null >"${OMARCHY_VT_CURSOR:-/sys/module/vt/parameters/global_cursor_default}"
    return 0
}
