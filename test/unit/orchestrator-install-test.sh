#!/usr/bin/env bash
# arch_install_system: the order it drives the archinstall-bash steps in,
# against a stub of the library that records every call — the root image
# unpacked before anything writes into the target, the per-machine delta
# after it, the keyring unit started after the last pacstrap. Also the
# package target helpers.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

# ── stub library ──────────────────────────────────────────────────────────────
CFG_HAS_MIRROR_CONFIG=true CFG_SWAP_ENABLED=true CFG_HAS_APP_CONFIG=true
CFG_TIMEZONE=UTC CFG_NTP=true CFG_ROOT_ENC_PASSWORD='$y$hash' USER_NAME=(jeff) PRE_MOUNT=false
arch_load_config() { record arch_load_config; }
disk_is_pre_mount() { [[ $PRE_MOUNT == true ]]; }
# The disk phase persists what formatting discovered; the stub discovers
# like the real one so the handoff to later phase processes is testable.
fs_perform_filesystem_operations() {
  record fs_perform_filesystem_operations
  PART_DEVPATH=(/dev/vda1 /dev/vda2) PART_PARTN=(1 2)
  PART_PARTUUID=(1111-aaaa 2222-bbbb) PART_UUID=(3333-cccc 4444-dddd)
}
for fn in require_target_is_mnt installer_mount_ordered_layout installer_set_mirrors \
          installer_minimal_installation installer_setup_swap installer_create_users applications_install \
          installer_add_additional_packages installer_set_timezone installer_activate_time_synchronization \
          installer_set_user_password installer_genfstab installer_finish \
          mount_offline_package_cache unmount_offline_package_cache configure_limine_boot \
          start_target_keyring_init \
          write_pre_mounted_fstab; do
  eval "$fn() { record \"$fn\${*:+ \$*}\"; }"
done
mask_mkinitcpio_pacman_hooks() { record "mask $1"; }
unmask_mkinitcpio_pacman_hooks() { record "unmask $1"; }

reset() {
  fresh_target
  CFG_HAS_MIRROR_CONFIG=true CFG_SWAP_ENABLED=true CFG_HAS_APP_CONFIG=true CFG_TIMEZONE=UTC CFG_NTP=true
  CFG_ROOT_ENC_PASSWORD='$y$hash' USER_NAME=(jeff) PRE_MOUNT=false
}
steps() { calls | tr '\n' ';'; }

# The old single phase is now four: disk layout, image unpack (its own unit,
# started by the phase loop), package payload, base finishers. The three
# hosted functions run here in the loop's order; the image unit sits between
# disk and payload by build_phases wiring, checked below by executing it.
run_split() {
  run_phase install_disk_layout &&
    run_phase install_system_payload &&
    run_phase finalize_base_system
}

section 'full-disk order'
reset; run_split
check 'phases ok' eq "$?" 0
check 'sequence' eq "$(steps)" \
'fs_perform_filesystem_operations;installer_mount_ordered_layout;require_target_is_mnt;installer_set_mirrors live;mask /;installer_minimal_installation --no-mkinitcpio;installer_set_mirrors on_target;installer_setup_swap;configure_limine_boot;installer_create_users;applications_install;unmask /;start_target_keyring_init;unmount_offline_package_cache;installer_set_timezone UTC;installer_activate_time_synchronization;installer_set_user_password root $y$hash;installer_genfstab;installer_finish;'

section 'library-state handoff between phase processes'
# The persist/restore pair extracted from run-phase, driven the way two
# consecutive phase processes run them: the first persists what formatting
# discovered and the ledger the pacstrap marked; the second starts with the
# virgin ledger arch_init_library seeds and must get both back.
handoff_roundtrip() {
  local d rc=0
  d=$(mktemp -d) || return 1
  eval "$(sed -n '/^LIBRARY_STATE_VARS=/,/^# library-state helpers end/p' "$ORCHESTRATOR/run-phase")"
  (
    CTX_STATE_DIR=$d
    PART_PARTUUID=(1111-aaaa 2222-bbbb)
    declare -A INST_HELPER_FLAGS=([base]=true [base-strapped]=true)
    persist_library_state
  )
  (
    CTX_STATE_DIR=$d
    declare -A INST_HELPER_FLAGS=([base]=false)
    source "$d/library-state.sh"
    [[ ${INST_HELPER_FLAGS[base]} == true && ${PART_PARTUUID[1]} == 2222-bbbb ]]
  ) || rc=1
  rm -rf "$d"
  return "$rc"
}
check 'library state survives the process boundary' handoff_roundtrip

section 'invariants'
check 'mkinitcpio deferred to the final UKI build' contains "$(steps)" 'installer_minimal_installation --no-mkinitcpio'
check 'limine set up after the base delta, before useradd' test "$(calls | grep -n 'configure_limine_boot\|installer_create_users' | cut -d: -f1 | tr '\n' ' ')" == '9 10 '
check 'package cache unmounted before genfstab' test "$(calls | grep -n 'unmount_offline_package_cache\|installer_genfstab' | cut -d: -f1 | tr '\n' ' ')" == '14 18 '
check 'live hooks unmasked after the last pacstrap' test "$(calls | grep -n 'applications_install\|^unmask' | cut -d: -f1 | tr '\n' ' ')" == '11 12 '
check 'keyring init started after the last pacstrap' test "$(calls | grep -n 'applications_install\|start_target_keyring_init' | cut -d: -f1 | tr '\n' ' ')" == '11 13 '

section 'phase wiring'
# Walks the real unit graph: from the terminal unit, follow each Requires=
# on another phase unit back to the root. The chain must be one linear path
# that covers every run-phase unit exactly once, and the canonical
# disk -> image -> strap -> base order must sit inside it.
walk_phase_graph() {
  local units_dir="$ROOT/configs/airootfs/etc/systemd/system" chain=() unit=omarchy-install-factory-snapshot.service
  local -A seen=()
  local prev
  while [[ -n $unit ]]; do
    [[ -z ${seen[$unit]:-} ]] || { echo "cycle at $unit"; return 1; }
    seen[$unit]=1
    chain=("$unit" "${chain[@]}")
    prev=$(grep -oE '^Requires=omarchy-install-[a-z-]+\.service' "$units_dir/$unit" 2>/dev/null | cut -d= -f2)
    unit=$prev
  done
  local expected total
  expected=$(grep -lE '^ExecStart=.*run-phase ' "$units_dir"/omarchy-install-*.service | wc -l)
  total=${#chain[@]}
  [[ $total == "$expected" ]] || { echo "chain covers $total of $expected phase units"; return 1; }
  printf ';%s' "${chain[@]}"
  printf ';'
}
GRAPH=$(walk_phase_graph) || { echo "$GRAPH"; false; }
check 'the Requires= chain covers every phase unit' test -n "$GRAPH"
check 'disk, image, strap, base sit in order inside it' contains "$GRAPH" \
  'omarchy-install-disk.service;omarchy-install-image.service;omarchy-install-strap.service;omarchy-install-base.service;'
check 'the chain begins at the live preparation' contains "$GRAPH" \
  ';omarchy-install-prepare-live.service;omarchy-install-prepare-target.service;'
check 'the chain ends at the factory snapshot' contains "$GRAPH" 'omarchy-install-factory-snapshot.service;'

section 'pre-mounted target'
reset; PRE_MOUNT=true; run_split
check 'phases ok' eq "$?" 0
check 'no disk steps' test -z "$(calls | grep 'fs_perform\|mount_ordered' || true)"
check 'own fstab instead of genfstab' test "$(calls | grep -c 'write_pre_mounted_fstab')" == 1 -a -z "$(calls | grep installer_genfstab || true)"
check 'finish still last' eq "$(calls | tail -n1)" installer_finish

section 'optional steps follow the configuration'
reset; CFG_HAS_MIRROR_CONFIG=false CFG_SWAP_ENABLED=false CFG_HAS_APP_CONFIG=false CFG_TIMEZONE='' CFG_NTP=false CFG_ROOT_ENC_PASSWORD='' USER_NAME=()
run_split
check 'phases ok' eq "$?" 0
for absent in installer_set_mirrors installer_setup_swap applications_install installer_create_users installer_set_timezone installer_activate_time_synchronization installer_set_user_password; do
  check "no $absent" test -z "$(calls | grep "^$absent" || true)"
done

section 'tailscale package when an auth key is staged'
reset; CTX_TAILSCALE_AUTHKEY_PATH="$TMP/authkey"; run_split
check 'installed while the mirror is mounted' test "$(calls | grep -n 'installer_add_additional_packages tailscale\|unmount_offline' | cut -d: -f1 | tr '\n' ' ')" == '12 15 '

section 'a failing step aborts the phase'
reset; installer_minimal_installation() { record minimal; fail 'pacstrap exploded'; }
run_phase install_disk_layout; run_phase install_system_payload
check 'phase failed' test "$?" -ne 0
check 'stopped there' eq "$(calls | tail -n1)" minimal
check 'message' contains "$(cat "$ERR")" 'pacstrap exploded'
eval "installer_minimal_installation() { record \"installer_minimal_installation\${*:+ \$*}\"; }"

# ── package targets ──────────────────────────────────────────────────────────
section 'package targets'
export OMARCHY_ISO_SHARE="$TMP/share"; mkdir -p "$OMARCHY_ISO_SHARE"
unset OMARCHY_RUNTIME_PACKAGE OMARCHY_SETTINGS_PACKAGE OMARCHY_NVIM_PACKAGE
OMARCHY_ISO_REF=stable
check 'stable defaults' eq "$(package_target runtime)/$(package_target settings)/$(package_target nvim)" omarchy/omarchy-settings/omarchy-nvim
OMARCHY_ISO_REF=dev
check 'dev defaults' eq "$(package_target runtime)/$(package_target settings)" omarchy-dev/omarchy-settings-dev
printf '# written by build-iso\nOMARCHY_RUNTIME_PACKAGE="omarchy-git"\nOMARCHY_SETTINGS_PACKAGE = omarchy-settings-git \n' >"$OMARCHY_ISO_SHARE/package-targets"
check 'package-targets file (quotes, spaces, comments)' eq "$(package_target runtime)/$(package_target settings)/$(package_target nvim)" omarchy-git/omarchy-settings-git/omarchy-nvim
OMARCHY_NVIM_PACKAGE=omarchy-nvim-x
check 'environment wins' eq "$(package_target nvim)" omarchy-nvim-x
unset OMARCHY_NVIM_PACKAGE; rm "$OMARCHY_ISO_SHARE/package-targets"; OMARCHY_ISO_REF=stable

finish
