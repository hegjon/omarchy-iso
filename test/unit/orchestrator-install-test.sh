#!/usr/bin/env bash
# arch_install_system: the order it drives the archinstall-bash steps in,
# against a stub of the library that records every call — the root image
# unpacked before anything writes into the target, the per-machine delta
# after it, the keyring unit started after the last pacstrap. Also the
# package target helpers.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

# ── stub library ──────────────────────────────────────────────────────────────
CFG_HAS_MIRROR_CONFIG=true CFG_SWAP_ENABLED=true CFG_SWAP_ALGO=zstd CFG_HAS_APP_CONFIG=true
CFG_TIMEZONE=UTC CFG_NTP=true CFG_ROOT_ENC_PASSWORD='$y$hash' USER_NAME=(jeff) PRE_MOUNT=false
arch_load_config() { record arch_load_config; }
disk_is_pre_mount() { [[ $PRE_MOUNT == true ]]; }
for fn in fs_perform_filesystem_operations installer_mount_ordered_layout installer_set_mirrors \
          installer_minimal_installation installer_setup_swap installer_create_users applications_install \
          installer_add_additional_packages installer_set_timezone installer_activate_time_synchronization \
          installer_set_user_password installer_genfstab installer_finish \
          mount_offline_package_cache unmount_offline_package_cache configure_limine_boot \
          install_root_image start_target_keyring_init \
          drop_archinstall_zram_conf write_pre_mounted_fstab; do
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

section 'full-disk order'
reset; run_phase arch_install_system
check 'phase ok' eq "$?" 0
check 'sequence' eq "$(steps)" \
'arch_load_config;fs_perform_filesystem_operations;installer_mount_ordered_layout;install_root_image;installer_set_mirrors live;mount_offline_package_cache;mask /;installer_minimal_installation --no-mkinitcpio;installer_set_mirrors on_target;installer_setup_swap zstd;drop_archinstall_zram_conf;configure_limine_boot;installer_create_users;applications_install;unmask /;unmount_offline_package_cache;start_target_keyring_init;installer_set_timezone UTC;installer_activate_time_synchronization;installer_set_user_password root $y$hash;installer_genfstab;installer_finish;'

section 'invariants'
check 'mkinitcpio deferred to the final UKI build' contains "$(steps)" 'installer_minimal_installation --no-mkinitcpio'
check 'image unpacked before anything writes into the target' test "$(calls | grep -n '^install_root_image\|^mount_offline_package_cache' | cut -d: -f1 | tr '\n' ' ')" == '4 6 '
check 'limine set up after the base delta, before useradd' test "$(calls | grep -n 'configure_limine_boot\|installer_create_users' | cut -d: -f1 | tr '\n' ' ')" == '12 13 '
check 'package cache unmounted before genfstab' test "$(calls | grep -n 'unmount_offline_package_cache\|installer_genfstab' | cut -d: -f1 | tr '\n' ' ')" == '16 21 '
check 'live hooks unmasked after the last pacstrap' test "$(calls | grep -n 'applications_install\|^unmask' | cut -d: -f1 | tr '\n' ' ')" == '14 15 '
check 'keyring init started after the last pacstrap' test "$(calls | grep -n 'unmount_offline_package_cache\|start_target_keyring_init' | cut -d: -f1 | tr '\n' ' ')" == '16 17 '

section 'pre-mounted target'
reset; PRE_MOUNT=true; run_phase arch_install_system
check 'phase ok' eq "$?" 0
check 'no disk steps' test -z "$(calls | grep 'fs_perform\|mount_ordered' || true)"
check 'image still unpacked' test "$(calls | grep -c 'install_root_image')" == 1
check 'own fstab instead of genfstab' test "$(calls | grep -c 'write_pre_mounted_fstab')" == 1 -a -z "$(calls | grep installer_genfstab || true)"
check 'finish still last' eq "$(calls | tail -n1)" installer_finish

section 'optional steps follow the configuration'
reset; CFG_HAS_MIRROR_CONFIG=false CFG_SWAP_ENABLED=false CFG_HAS_APP_CONFIG=false CFG_TIMEZONE='' CFG_NTP=false CFG_ROOT_ENC_PASSWORD='' USER_NAME=()
run_phase arch_install_system
check 'phase ok' eq "$?" 0
for absent in installer_set_mirrors installer_setup_swap drop_archinstall_zram_conf applications_install installer_create_users installer_set_timezone installer_activate_time_synchronization installer_set_user_password; do
  check "no $absent" test -z "$(calls | grep "^$absent" || true)"
done

section 'tailscale package when an auth key is staged'
reset; CTX_TAILSCALE_AUTHKEY_PATH="$TMP/authkey"; run_phase arch_install_system
check 'installed while the mirror is mounted' test "$(calls | grep -n 'installer_add_additional_packages tailscale\|unmount_offline' | cut -d: -f1 | tr '\n' ' ')" == '15 17 '

section 'a failing step aborts the phase'
reset; installer_minimal_installation() { record minimal; fail 'pacstrap exploded'; }
run_phase arch_install_system
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
