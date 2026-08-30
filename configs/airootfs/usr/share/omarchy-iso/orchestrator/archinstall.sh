# shellcheck shell=bash
# The wall around archinstall-bash (/usr/share/archinstall-bash), the bash port
# of archinstall this ISO ships. main.sh sources it into the orchestrator's
# shell before the orchestrator's own modules (whose info/error definitions
# must win); the phases call its functions directly (config_load, fs_*,
# installer_*, applications_install, the PART_*/CFG_* state it parses). Keep
# the surface the orchestrator uses listed here, so a library change has one
# place to hit.
#
# Used by the phases:
#   config_load                     ArchConfigHandler (config + creds JSON)
#   installer_init                  Installer(target, kernels)
#   fs_perform_filesystem_operations
#   installer_mount_ordered_layout
#   installer_set_mirrors live|on_target
#   installer_minimal_installation --no-mkinitcpio
#   installer_setup_swap, installer_create_users, applications_install
#   installer_add_additional_packages, installer_set_timezone,
#   installer_activate_time_synchronization, installer_set_user_password,
#   installer_genfstab, installer_finish
#   installer_get_root / _boot_partition / _efi_partition (indexes into PART_*)
#   installer_get_kernel_params, get_parent_device_path, get_unique_path_for_device
#   disk_is_pre_mount, sysinfo_has_uefi, CFG_* flags

arch_init_library() {
  declare -F config_load >/dev/null || fail 'archinstall-bash is not loaded (main.sh sources it before the orchestrator modules)'
  # The library's die() exits the phase; record its message for the handover.
  ARCHINSTALL_ON_DIE=orchestrator_record_error
}

# load_arch_config(): the configurator output as the library sees it.
arch_load_config() {
  if [[ -f $CTX_CREDS_PATH ]]; then
    config_load "$CTX_ARCH_CONFIG_PATH" "$CTX_CREDS_PATH"
  else
    config_load "$CTX_ARCH_CONFIG_PATH"
  fi
  installer_init "$CTX_TARGET" "${CFG_KERNELS[@]}"
}

arch_bootloader_enabled() {
  [[ -n $CFG_BOOTLOADER && $CFG_BOOTLOADER != no_bootloader ]]
}

arch_is_limine() {
  [[ $CFG_BOOTLOADER == limine ]]
}

arch_has_uefi() {
  [[ -d /sys/firmware/efi ]]
}
