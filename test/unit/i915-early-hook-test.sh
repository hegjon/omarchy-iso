#!/bin/bash
#
# The live initramfs loads i915 at once only on the Intel GPUs that need no
# firmware, listed in i915-early.ids from the kernel's own table: the
# generations before Skylake. The hook decides by PCI vendor, class and
# device ID, so a newer Intel GPU, a non-Intel one, or an Intel device that
# is not a display controller must all be left to the live root.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/configs/airootfs/etc/initcpio/hooks/omarchy-i915"
IDS="$ROOT/configs/airootfs/usr/share/omarchy-iso/i915-early.ids"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
# wanted <description> yes|no: the hook's verdict on the fake PCI bus
wanted() { if omarchy_i915_wanted; then v=yes; else v=no; fi; if [[ $v == "$2" ]]; then ok "$1"; else fail "$1: wanted=$v"; fi; }
listed() { if grep -qx "$2" "$IDS"; then v=yes; else v=no; fi; if [[ $v == "$3" ]]; then ok "$1"; else fail "$1"; fi; }

count=$(grep -cE '^[0-9a-f]{4}$' "$IDS")
if (( count >= 100 )); then ok "$count device IDs listed"; else fail "only $count device IDs listed"; fi
listed "GM45 (the ThinkPad X200) is listed" 2a42 yes
listed "Broadwell is listed" 1616 yes
listed "Skylake is not listed, it wants firmware" 1916 no
listed "Meteor Lake is not listed, it needs GuC firmware" 7d55 no
if grep -vE '^(#|[0-9a-f]{4}$)' "$IDS" | grep -q .; then fail "a line is neither a comment nor a 4-digit hex ID"; else ok "every line is a comment or a 4-digit hex ID"; fi

# shellcheck source=/dev/null
source "$HOOK"
export OMARCHY_I915_IDS="$IDS" OMARCHY_PCI_DEVICES="$work/pci"
bus() { rm -rf "$work/pci"; mkdir -p "$work/pci"; }
device() { mkdir -p "$work/pci/$1"; printf '0x%s\n' "$2" >"$work/pci/$1/vendor"; printf '0x%s\n' "$3" >"$work/pci/$1/device"; printf '0x%s\n' "$4" >"$work/pci/$1/class"; }

bus; device 0000:00:02.0 8086 2a42 030000
wanted "GM45 display controller" yes
bus; device 0000:00:02.0 8086 1916 030000
wanted "Skylake display controller: left to the live root" no
bus; device 0000:01:00.0 1002 731f 030000
wanted "an AMD GPU: left alone" no
bus; device 0000:00:14.0 8086 2a42 0c0330
wanted "an Intel device that is not a display controller: ignored" no
bus; device 0000:00:02.0 8086 2a42 030000; device 0000:01:00.0 10de 1c82 030000
wanted "GM45 beside another GPU" yes
bus
wanted "no PCI devices: nothing" no
bus; device 0000:00:02.0 8086 2a42 030000
OMARCHY_I915_IDS="$work/missing" wanted "no ID list: nothing" no

exit "$((failures > 0))"
