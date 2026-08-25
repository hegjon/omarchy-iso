#!/bin/bash
#
# Runs inside the live root while mkarchiso builds it, after the live
# packages were installed.

set -euo pipefail

# The splash always precedes the installer on the live ISO: append the
# starting line under the logo for the real-root plymouthd too. The
# initramfs copy of the theme gets the same append from the
# omarchy-start-banner initcpio hook (which runs earlier, when the kernel
# package's install hook builds the initramfs).
snippet=/usr/share/omarchy-iso/plymouth-starting-line.script
theme=/usr/share/plymouth/themes/omarchy/omarchy.script
if [[ -f $snippet && -f $theme ]] && ! grep -q 'omarchy-starting-line' "$theme"; then
  cat "$snippet" >>"$theme"
fi
