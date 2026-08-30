# shellcheck shell=bash
# Target setup phases: the Omarchy runtime's own setup, run inside the target.
#  1. point the target at the offline pacman.conf
#  2. bind-mount the offline mirror + /opt/packages into the target for
#     target pacman and bundled language runtimes
#  3. arch-chroot as root → omarchy-apply-system --first-install
#  4. arch-chroot as user → omarchy-provision-user --first-install
# Plus hibernation (root-owned boot configuration, before user setup) and the
# install-debug helpers.

# Configure swap/resume in the target as root before user setup.
#
# Hibernation is system boot configuration, not per-user setup. The final
# Limine UKI build still happens later in finalize_limine_boot after this
# writes the resume hook and kernel cmdline drop-in.
configure_hibernation() {
  if [[ ! -e $CTX_TARGET/usr/bin/omarchy-hibernation-setup ]]; then
    debug_log 'skipping hibernation: /usr/bin/omarchy-hibernation-setup is not installed'
    return 0
  fi
  arch-chroot "$CTX_TARGET" env OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log \
    /usr/bin/omarchy-hibernation-setup --force --no-rebuild
}

install_debug_enabled() {
  [[ ${OMARCHY_INSTALL_DEBUG:-} == 1 || -e /usr/share/omarchy-iso/install-debug ]]
}

debug_log() {
  install_debug_enabled || return 0
  mkdir -p "${CTX_LOG_PATH%/*}"
  printf '[install-debug] %s\n' "$*" >>"$CTX_LOG_PATH"
}

prepare_target_setup() {
  [[ $CTX_TARGET_SETUP_PREPARED == true ]] && return 0
  require_target_is_mnt

  cp /etc/pacman.conf "$CTX_TARGET/etc/pacman.conf"

  # Static mount units: starting an already-active mount is a no-op, so the
  # phase units that share this helper cannot stack a second bind the way
  # repeated mount --bind calls could, and PartOf= the install target
  # unmounts them on any group teardown.
  local unit
  for unit in mnt-var-cache-omarchy-mirror-offline.mount mnt-opt-packages.mount; do
    systemctl start "$unit" ||
      fail "could not bind the live tree into the target: journalctl -u $unit"
  done

  CTX_TARGET_SETUP_PREPARED=true
}

ensure_finalizer_log_started() {
  if [[ -z $CTX_OMARCHY_START_TIME ]]; then
    CTX_OMARCHY_START_EPOCH=$(date +%s)
    CTX_OMARCHY_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  fi

  mkdir -p "${CTX_LOG_PATH%/*}"
  touch "$CTX_LOG_PATH"
  chmod 0666 "$CTX_LOG_PATH"

  if [[ $CTX_FINALIZER_HEADER_WRITTEN != true ]]; then
    printf '=== Omarchy Target Setup Started: %s ===\n' "$CTX_OMARCHY_START_TIME" >>"$CTX_LOG_PATH"
    CTX_FINALIZER_HEADER_WRITTEN=true
  fi
}

# HOME/USER/LOGNAME/SHELL for a chroot run as the user, from the target's passwd.
target_user_env() {
  local user=$1 home="/home/$1" shell=/bin/bash entry
  entry=$(awk -F: -v u="$user" '$1 == u && NF >= 7 { print $6 "\t" $7; exit }' "$CTX_TARGET/etc/passwd" 2>/dev/null || true)
  if [[ -n $entry ]]; then
    [[ -n ${entry%%$'\t'*} ]] && home=${entry%%$'\t'*}
    [[ -n ${entry#*$'\t'} ]] && shell=${entry#*$'\t'}
  fi
  printf '%s\n' "HOME=$home" "USER=$user" "LOGNAME=$user" "SHELL=$shell"
}

# run_target_setup_command [--user USER] CMD...: arch-chroot into the target
# with the Omarchy install environment, the unified log bind-mounted inside.
run_target_setup_command() {
  local user=''
  if [[ ${1:-} == --user ]]; then
    user=$2
    shift 2
  fi

  prepare_target_setup
  ensure_finalizer_log_started

  local target_log="$CTX_TARGET/var/log/omarchy-install.log" log_bind_mounted=false
  mkdir -p "${target_log%/*}"
  touch "$target_log"
  chmod 0666 "$target_log"

  if mount --bind "$CTX_LOG_PATH" "$target_log"; then
    log_bind_mounted=true
  else
    printf '[orchestrator] WARNING: failed to bind unified setup log\n' >>"$CTX_LOG_PATH"
  fi

  local -a env_extras=(
    OMARCHY_PATH=/usr/share/omarchy
    OMARCHY_INSTALL=/usr/share/omarchy/install
    "OMARCHY_INSTALL_USER=$CTX_USERNAME"
    "OMARCHY_START_TIME=$CTX_OMARCHY_START_TIME"
    "OMARCHY_START_EPOCH=$CTX_OMARCHY_START_EPOCH"
    "OMARCHY_USER_NAME=$CTX_FULL_NAME"
    "OMARCHY_USER_EMAIL=$CTX_EMAIL"
    "OMARCHY_MIRROR=$(read_omarchy_mirror)"
    "OMARCHY_ISO_REF=$(iso_ref)"
    "OMARCHY_RUNTIME_PACKAGE=$(omarchy_runtime_package)"
    "OMARCHY_SETTINGS_PACKAGE=$(omarchy_settings_package)"
    "OMARCHY_NVIM_PACKAGE=$(omarchy_nvim_package)"
    OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
    OMARCHY_LOG_TO_STDOUT=1
  )
  if install_debug_enabled; then
    env_extras+=(OMARCHY_INSTALL_DEBUG=1)
    debug_log "running target setup command: $*"
  fi

  local -a chroot_cmd=(arch-chroot)
  if [[ -n $user ]]; then
    chroot_cmd+=(-u "$user")
    local -a user_env
    mapfile -t user_env < <(target_user_env "$user")
    env_extras+=("${user_env[@]}")
  fi
  chroot_cmd+=("$CTX_TARGET" env --unset=XDG_RUNTIME_DIR "${env_extras[@]}" "$@")

  local rc=0
  "${chroot_cmd[@]}" || rc=$?

  if [[ $log_bind_mounted == true ]]; then
    umount "$target_log" >/dev/null 2>&1 || true
    cp -p "$CTX_LOG_PATH" "$target_log" 2>/dev/null && chmod 0644 "$target_log" || true
  else
    { printf '\n=== Target setup log ===\n'; cat "$target_log"; } >>"$CTX_LOG_PATH" 2>/dev/null || true
  fi
  ((rc == 0)) || fail "$1 failed (exit $rc)"
}

run_system_finalizer() {
  local -a cmd
  if [[ $CTX_DEFER_PROVISIONING == true ]]; then
    cmd=(/usr/bin/omarchy-apply-system --defer-provisioning --first-install)
  else
    cmd=(/usr/bin/omarchy-apply-system --install-user "$CTX_USERNAME" --first-install)
  fi

  # The exit trap restores the mask if the finalizer fails (cleanup_target_hook_masks).
  mask_mkinitcpio_pacman_hooks "$CTX_TARGET" "${TARGET_DEFERRED_BOOT_HOOKS[@]}"
  run_target_setup_command "${cmd[@]}"
  unmask_mkinitcpio_pacman_hooks "$CTX_TARGET" "${TARGET_DEFERRED_BOOT_HOOKS[@]}"
}

run_chroot_finalizer() {
  if [[ $CTX_DEFER_PROVISIONING == true ]]; then
    info '› deferred-provisioning install: user finalization deferred to first boot'
    return 0
  fi
  run_target_setup_command --user "$CTX_USERNAME" /usr/bin/omarchy-provision-user --force --first-install
}

read_omarchy_mirror() {
  local mirror
  mirror=$(ctx_read_env_file /root/omarchy_mirror)
  printf '%s' "${mirror:-stable}"
}
