# shellcheck shell=bash
# Phases up to and including the Arch + Omarchy install, and the helpers they
# share with the boot setup: package targets, pacman hook masking, the offline
# package cache, the Omarchy install intent (omarchy_install.boot/storage) and
# the pre-mounted (protected) target's fstab/crypttab.

# Build-time files the ISO ships for the installer (package lists, targets).
OMARCHY_ISO_SHARE=${OMARCHY_ISO_SHARE:-/usr/share/omarchy-iso}

# Package targets are written by builder/build-iso.sh. Stable ISOs use the
# stable package names, while dev/local-source ISOs install the dev package
# names explicitly instead of relying on provides=omarchy resolution.
iso_ref() {
  if [[ -n ${OMARCHY_ISO_REF:-} ]]; then
    printf '%s' "${OMARCHY_ISO_REF// /}"
  elif [[ -f /root/omarchy_iso_ref ]]; then
    ctx_read_env_file /root/omarchy_iso_ref
  else
    printf 'stable'
  fi
}

# _package_targets(): defaults by ISO ref, then the build's package-targets
# file, then the environment.
package_target() {
  local key=$1 runtime=omarchy settings=omarchy-settings nvim=omarchy-nvim line k v
  case $(iso_ref) in
    dev|local) runtime=omarchy-dev settings=omarchy-settings-dev ;;
  esac
  if [[ -f $OMARCHY_ISO_SHARE/package-targets ]]; then
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}
      [[ -z $line || $line == \#* || $line != *=* ]] && continue
      k=${line%%=*}
      v=${line#*=}
      v=${v#"${v%%[![:space:]]*}"}
      v=${v%"${v##*[![:space:]]}"}
      v=${v#[\"\']}
      v=${v%[\"\']}
      case ${k%"${k##*[![:space:]]}"} in
        OMARCHY_RUNTIME_PACKAGE) runtime=$v ;;
        OMARCHY_SETTINGS_PACKAGE) settings=$v ;;
        OMARCHY_NVIM_PACKAGE) nvim=$v ;;
      esac
    done <"$OMARCHY_ISO_SHARE/package-targets"
  fi
  [[ -n ${OMARCHY_RUNTIME_PACKAGE:-} ]] && runtime=$OMARCHY_RUNTIME_PACKAGE
  [[ -n ${OMARCHY_SETTINGS_PACKAGE:-} ]] && settings=$OMARCHY_SETTINGS_PACKAGE
  [[ -n ${OMARCHY_NVIM_PACKAGE:-} ]] && nvim=$OMARCHY_NVIM_PACKAGE
  case $key in
    runtime) printf '%s' "$runtime" ;;
    settings) printf '%s' "$settings" ;;
    nvim) printf '%s' "$nvim" ;;
    *) fail "unknown package target: $key" ;;
  esac
}

omarchy_runtime_package() { package_target runtime; }
omarchy_settings_package() { package_target settings; }
omarchy_nvim_package() { package_target nvim; }

# ─────────────────────────────────────────────────────────────────────────────
# prepare_live: ready the live ISO for the install — tear down any previous
# holders on the install disk (via the bash helper), then parse the
# configurator output.
#
# The live pacman keyring is deliberately NOT waited on. The offline repo is
# SigLevel = Never (see configs/pacman-offline.conf for why that is required:
# pacstrap verifies against the LIVE GpgDir, so anything short of Never makes
# installs depend on archiso's boot-time pacman-init.service). That service
# (gpg key generation + populating every keyring, Type=oneshot with no start
# timeout) can take minutes on real hardware reading from USB — blocking on
# it here stalled installs at 5% while it ground away in the background, and
# racing it failed pacstrap with "required key missing from keyring".
# ─────────────────────────────────────────────────────────────────────────────

prepare_live() {
  if [[ $CTX_IS_PROTECTED == true ]]; then
    info '› protected mode: skipping whole-disk cleanup'
  else
    local disk
    disk=$(install_disk)
    if [[ -n $disk ]]; then
      info "› cleaning up holders on install disk: $disk"
      omarchy-iso-cleanup-disk "$disk"
    fi
  fi

  info '› loading configurator output'
  arch_load_config
}

# _install_disk(): the device being wiped, or nothing for pre_mounted /
# no-wipe configs.
install_disk() {
  user_configuration_get '.disk_config.device_modifications // [] | map(select(.wipe == true)) | .[0].device'
}

# Everything that can fail before the disk is touched. The next phase
# partitions, formats and encrypts as its first step, and a failure after
# that leaves a wiped (or wiped and encrypted) disk with no system on it: so
# the stream, its checksum and a layout the image can land on are all checked
# here, where failing costs nothing.
prepare_install_target() {
  if [[ $CTX_IS_PROTECTED == true ]]; then
    verify_protected_mounts
    # The protected layout exists already; check the real mounts.
    root_image_target_mounts
  else
    verify_root_image_layout
  fi
  verify_root_image_stream
  verify_offline_mirror
}

# ─────────────────────────────────────────────────────────────────────────────
# arch_install_system: archinstall-bash partitions and mounts per the
# configurator JSON, the root image is unpacked onto the mounted layout, and
# the library finishes with the per-machine package delta, users, and fstab.
#
# The phase sequence is the same for full-disk and protected installs. The
# JSON decides whether the installer should create/mount a disk layout or use
# a pre-mounted target, and Omarchy derives boot/fstab details from that same
# input.
# ─────────────────────────────────────────────────────────────────────────────

arch_install_system() {
  arch_load_config

  if ! disk_is_pre_mount; then
    info '› partitioning + formatting + encrypting'
    fs_perform_filesystem_operations
    info '› mounting the layout'
    installer_mount_ordered_layout
  fi

  # Before anything writes into the target: the image replaces the (empty)
  # root subvolume the installer created, and everything written there first
  # would go with it.
  install_root_image

  if [[ $CFG_HAS_MIRROR_CONFIG == true ]]; then
    installer_set_mirrors live
  fi

  mount_offline_package_cache
  mask_mkinitcpio_pacman_hooks / "${DEFERRED_BOOT_HOOKS[@]}"

  info '› installing per-machine packages (mkinitcpio deferred to final Limine UKI build)'
  # The base strap reduces to the packages the image does not carry (the
  # kernel and the CPU microcode — the library straps only what the target
  # lacks); hostname,
  # locale and the console keymap (written with systemd-firstboot, never
  # booting the target) are part of minimal installation as before.
  installer_minimal_installation --no-mkinitcpio

  if [[ $CFG_HAS_MIRROR_CONFIG == true ]]; then
    installer_set_mirrors on_target
  fi

  if [[ $CFG_SWAP_ENABLED == true ]]; then
    installer_setup_swap
  fi

  configure_limine_boot

  info '› creating user (with /etc/skel populated)'
  if ((${#USER_NAME[@]})); then
    installer_create_users
  fi

  if [[ $CFG_HAS_APP_CONFIG == true ]]; then
    # The image carries the application handlers' package sets (PipeWire and
    # friends); the strap-only-missing mode reduces this to the
    # hardware-detected firmware.
    info '› installing archinstall application selections'
    applications_install
  fi

  # Tailscale is bundled in the offline mirror but only installed when an
  # autoinstall drive staged an auth key; must happen here, while the mirror
  # is still bind-mounted, not in the phase that configures the join.
  if [[ -n $CTX_TAILSCALE_AUTHKEY_PATH ]]; then
    info '› installing tailscale (auth key staged for first boot)'
    installer_add_additional_packages tailscale
  fi

  unmask_mkinitcpio_pacman_hooks / "${DEFERRED_BOOT_HOOKS[@]}"
  unmount_offline_package_cache

  # After the last pacstrap: each one runs its own pacman-key --init on the
  # target's gnupg dir. Runs on while the phases below configure the target;
  # create_factory_snapshot joins it.
  start_target_keyring_init

  # Standard arch finishers.
  [[ -n $CFG_TIMEZONE ]] && { installer_set_timezone "$CFG_TIMEZONE" || true; }
  if [[ $CFG_NTP == true ]]; then
    installer_activate_time_synchronization
  fi
  [[ -n $CFG_ROOT_ENC_PASSWORD ]] && { installer_set_user_password root "$CFG_ROOT_ENC_PASSWORD" || true; }

  if disk_is_pre_mount; then
    write_pre_mounted_fstab
  else
    installer_genfstab
  fi

  installer_finish
}

# Let pacstrap consume bundled packages without copying them first.
#
# Pacstrap always points pacman's CacheDir inside the target. Without this
# bind mount, pacman copies every package from the ISO's file:// repository
# into that cache and then extracts it, duplicating several GiB of I/O.
# Mount the already-populated offline repository at the target cache for the
# duration of package installation. It is unmounted before genfstab so the
# live-only bind can never leak into the installed system's fstab.
mount_offline_package_cache() {
  local source=/var/cache/omarchy/mirror/offline target="$CTX_TARGET/var/cache/pacman/pkg"
  [[ -d $source ]] || fail "offline package cache missing: $source"
  # The mirror lives on the boot medium, mounted here by
  # var-cache-omarchy-mirror-offline.mount. An empty directory means that mount
  # did not happen -- a damaged or truncated image, or a medium that went away
  # -- and pacstrapping from it would fail package by package instead of
  # saying so once, now, before the target is touched.
  mountpoint -q "$source" ||
    fail "offline package mirror is not mounted at $source: the mirror on the install medium (arch/x86_64/mirror) did not mount"
  mkdir -p "$target"
  mount --bind "$source" "$target"
  CTX_BIND_MOUNTS+=("$target")
}

unmount_offline_package_cache() {
  local target="$CTX_TARGET/var/cache/pacman/pkg" kept=() m
  umount "$target"
  for m in "${CTX_BIND_MOUNTS[@]}"; do
    [[ $m == "$target" ]] || kept+=("$m")
  done
  CTX_BIND_MOUNTS=("${kept[@]}")
}

DEFERRED_BOOT_HOOKS=(
  60-mkinitcpio-remove.hook
  60-limine-mkinitcpio-remove-pre.hook
  80-limine-efi-deploy.hook
  90-limine-mkinitcpio-remove-post.hook
  90-mkinitcpio-install.hook
)

# Inside the target chroot, only the install hook is worth deferring.
# limine-entry-tool's 90-mkinitcpio-install.hook triggers on usr/lib/firmware/*,
# usr/src/*/dkms.conf and usr/lib/modules/*/pkgbase, and anything but a
# usr/lib/modules path makes it rebuild the initramfs and UKI for EVERY
# installed kernel. omarchy-apply-system's hardware scripts routinely install
# such packages (sof-firmware on Intel audio, nvidia-open-dkms, linux-ptl on
# Panther Lake, linux-t2 on Macs), so the phase can pay for several full UKI
# builds. finalize_limine_boot runs limine-update right after, which pipes
# "rebuild" into the same script and rebuilds every kernel unconditionally —
# those mid-phase builds are always thrown away, and are stale anyway (nvidia.sh
# writes its mkinitcpio drop-in after installing the driver).
#
# The kernel-removal hooks stay live: they only prune Limine entries, which is
# exactly what ptl-kernel.sh's "pacman -Rdd linux" needs.
TARGET_DEFERRED_BOOT_HOOKS=(90-mkinitcpio-install.hook)

is_devnull_symlink() {
  [[ -L $1 && $(readlink "$1") == /dev/null ]]
}

# Temporarily suppress boot-image pacman hooks around a package install.
#
# With root / this masks the LIVE hook dir, which is what pacstrap reads:
# pacstrap uses the live system's /etc/pacman.conf, and pacman.conf(5) notes
# that HookDir is absolute and the target root is not prepended, so
# target-side /mnt/etc/pacman.d/hooks masks do not override target
# /usr/share/libalpm hooks during installation. The target's real hooks still
# get installed and become active after reboot.
#
# Passing the target masks the same way inside it, for pacman runs that
# happen under arch-chroot (see TARGET_DEFERRED_BOOT_HOOKS).
mask_mkinitcpio_pacman_hooks() {
  local root=${1%/} name path backup
  shift
  local hooks_dir="$root/etc/pacman.d/hooks"
  mkdir -p "$hooks_dir"
  for name in "$@"; do
    path="$hooks_dir/$name"
    backup="$hooks_dir/$name.omarchy-backup"
    is_devnull_symlink "$path" && continue
    if [[ -e $path || -L $path ]]; then
      rm -f "$backup"
      mv "$path" "$backup"
    fi
    ln -s /dev/null "$path"
  done
}

unmask_mkinitcpio_pacman_hooks() {
  local root=${1%/} name path backup
  shift
  local hooks_dir="$root/etc/pacman.d/hooks"
  for name in "$@"; do
    path="$hooks_dir/$name"
    backup="$hooks_dir/$name.omarchy-backup"
    if is_devnull_symlink "$path"; then
      rm -f "$path" || info "warning: failed to restore pacman hook mask for $name"
    fi
    if [[ -e $backup || -L $backup ]]; then
      mv "$backup" "$path" || info "warning: failed to restore pacman hook mask for $name"
    fi
  done
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Install intent helpers: normalize the Omarchy-specific part of the
# configurator JSON so full-disk and pre-mounted installs feed the same boot
# and target setup code.
# ─────────────────────────────────────────────────────────────────────────────

# _boot_intent(key): omarchy_install.boot with the defaults applied.
boot_intent() {
  local key=$1 value
  value=$(omarchy_install_get ".boot.$key")
  if [[ -z $value ]]; then
    case $key in
      esp_mount) value=/boot ;;
      esp_path) value=/EFI/limine ;;
      efi_binary) value=limine_x64.efi ;;
      enable_fallback) [[ $CTX_IS_PROTECTED == true ]] && value=false || value=true ;;
    esac
  fi
  printf '%s' "$value"
}

storage_intent() {
  omarchy_install_get ".storage.$1"
}

verify_protected_mounts() {
  local target=$CTX_TARGET key device esp_mount

  # Devices before the mountpoint: when the configurator hands over paths for
  # partitions that do not exist, "root_device /dev/nvme0n1p12 does not
  # exist" is diagnosable from the log alone, where "/mnt is not a
  # mountpoint" sends everyone looking at the mount instead of the paths.
  for key in esp_device root_device; do
    device=$(storage_intent "$key")
    [[ -n $device ]] || fail "protected mode: omarchy_install.storage.$key missing"
    [[ -e $device ]] || fail "protected mode: $key $device does not exist"
  done

  is_mountpoint "$target" || fail "protected mode: $target is not a mountpoint"

  esp_mount=$(boot_intent esp_mount)
  local esp_mp="$target/${esp_mount#/}"
  if ! is_mountpoint "$esp_mp"; then
    local esp_dev
    esp_dev=$(storage_intent esp_device)
    info "› remounting protected ESP $esp_dev at $esp_mp"
    mkdir -p "$esp_mp"
    mount "$esp_dev" "$esp_mp"
  fi

  local kernel
  kernel=$(storage_intent kernel)
  info "› protected target verified: kernel=${kernel:-linux} esp=$esp_mount"
}

is_mountpoint() {
  [[ -n $(findmnt -rn "$1" 2>/dev/null) ]]
}

# ── pre-mounted fstab / crypttab / cmdline ───────────────────────────────────

btrfs_root_device() {
  local luks_uuid mapper
  luks_uuid=$(storage_intent luks_uuid)
  if [[ -n $luks_uuid ]]; then
    mapper=$(storage_intent root_mapper)
    printf '%s' "${mapper:-/dev/mapper/omarchy_root}"
  else
    storage_intent root_device
  fi
}

blkid_uuid() {
  local uuid
  uuid=$(blkid -s UUID -o value "$1") || fail "blkid failed for $1"
  [[ -n $uuid ]] || fail "blkid returned no UUID for $1"
  printf '%s' "$uuid"
}

esp_device() {
  local dev
  dev=$(storage_intent esp_device)
  if [[ -z $dev ]]; then
    local esp_mp
    esp_mp="$CTX_TARGET/$(boot_intent esp_mount | sed 's|^/||')"
    dev=$(findmnt -n -o SOURCE "$esp_mp") || fail "could not resolve ESP device at $esp_mp"
    [[ -n $dev ]] || fail "could not resolve ESP device at $esp_mp"
  fi
  printf '%s' "$dev"
}

write_pre_mounted_fstab() {
  local btrfs_uuid esp_uuid esp_mount
  btrfs_uuid=$(blkid_uuid "$(btrfs_root_device)")
  esp_uuid=$(blkid_uuid "$(esp_device)")
  esp_mount=$(boot_intent esp_mount)
  local opts='noatime,compress=zstd,subvol='
  cat >"$CTX_TARGET/etc/fstab" <<FSTAB
# /etc/fstab — generated by Omarchy ISO
# <device>  <mount>  <fs>  <options>  <dump>  <pass>
UUID=$btrfs_uuid  /                      btrfs  ${opts}@       0 0
UUID=$btrfs_uuid  /home                  btrfs  ${opts}@home   0 0
UUID=$btrfs_uuid  /var/log               btrfs  ${opts}@log    0 0
UUID=$btrfs_uuid  /var/cache/pacman/pkg  btrfs  ${opts}@pkg    0 0
UUID=$esp_uuid  $esp_mount                   vfat   umask=0077              0 2
FSTAB
}

write_pre_mounted_crypttab() {
  local luks_uuid
  luks_uuid=$(storage_intent luks_uuid)
  [[ -n $luks_uuid ]] || return 0
  printf 'omarchy_root  UUID=%s  none  luks,discard\n' "$luks_uuid" >"$CTX_TARGET/etc/crypttab.initramfs"
}

build_pre_mounted_cmdline() {
  local btrfs_uuid=$1 luks_uuid mapper
  luks_uuid=$(storage_intent luks_uuid)
  if [[ -n $luks_uuid ]]; then
    mapper=$(storage_intent root_mapper)
    printf 'cryptdevice=UUID=%s:omarchy_root root=%s zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs' \
      "$luks_uuid" "${mapper:-/dev/mapper/omarchy_root}"
  else
    printf 'root=UUID=%s zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs' "$btrfs_uuid"
  fi
}

write_pre_mounted_limine_defaults() {
  local btrfs_uuid cmdline
  btrfs_uuid=$(blkid_uuid "$(btrfs_root_device)")
  cmdline=$(build_pre_mounted_cmdline "$btrfs_uuid")
  write_pre_mounted_crypttab
  write_limine_defaults "$cmdline" "$(boot_intent esp_mount)" "$(boot_intent enable_fallback)"
}
