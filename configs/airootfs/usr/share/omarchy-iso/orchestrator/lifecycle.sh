# shellcheck shell=bash
# What main()'s finally did in Python: CPU governors, bind mounts, hook masks
# and the protected target are put back on every exit path. All idempotent.

CPU_SYSFS=${CPU_SYSFS:-/sys/devices/system/cpu}
declare -gA CPU_GOVERNORS=()

# Run the live CPUs flat out for the install.
#
# Package extraction and the UKI build are both CPU-bound, and archiso boots
# on whatever governor the kernel defaults to. Writing an unsupported governor
# just fails, so nothing needs probing first, and hosts without cpufreq (most
# VMs) have no paths at all.
boost_cpu_governor() {
  local path current
  for path in "$CPU_SYSFS"/cpu*/cpufreq/scaling_governor; do
    [[ -f $path ]] || continue
    current=$(<"$path") || continue
    printf 'performance\n' >"$path" 2>/dev/null || continue
    CPU_GOVERNORS[$path]=$current
  done
  ((${#CPU_GOVERNORS[@]})) && info "› CPU governor set to performance (${#CPU_GOVERNORS[@]} CPUs)"
  return 0
}

# Only matters when an install fails and the user keeps using the live
# environment — a successful one reboots out of it.
restore_cpu_governors() {
  local path
  for path in "${!CPU_GOVERNORS[@]}"; do
    printf '%s\n' "${CPU_GOVERNORS[$path]}" >"$path" 2>/dev/null || true
  done
  return 0
}

cleanup_bind_mounts() {
  local mount_point
  for mount_point in "${CTX_BIND_MOUNTS[@]}"; do
    umount "$mount_point" >/dev/null 2>&1 || true
  done
  CTX_BIND_MOUNTS=()
}

# The live hook masks arch_install_system puts up around pacstrap; Python
# restored them in that phase's finally.
cleanup_live_hook_masks() {
  unmask_mkinitcpio_pacman_hooks / "${DEFERRED_BOOT_HOOKS[@]}"
}

# Restore the target's deferred boot hooks. Idempotent, and a no-op when
# nothing was masked, so the exit trap can call it on any exit path: an
# interrupt must never leave the installed system with its UKI rebuild hook
# pointing at /dev/null.
cleanup_target_hook_masks() {
  unmask_mkinitcpio_pacman_hooks "$CTX_TARGET" "${TARGET_DEFERRED_BOOT_HOOKS[@]}"
}

# Tear down protected-mode mounts and LUKS mapper after a failed install.
# Successful protected installs intentionally keep the target mounted until
# reboot.
cleanup_protected_state() {
  [[ $CTX_IS_PROTECTED == true ]] || return 0
  umount -R "$CTX_TARGET" >/dev/null 2>&1 || true
  if [[ -e /dev/mapper/omarchy_root ]]; then
    cryptsetup close omarchy_root >/dev/null 2>&1 || true
  fi
}

# ── exit handling (installed by main) ─────────────────────────────────────────

ORCH_SUCCESS=false
ORCH_INTERRUPTED=false

orchestrator_on_err() {
  # Only the first failure matters; fail()/die() already stored their message.
  [[ -n $ORCH_LAST_ERROR ]] || ORCH_LAST_ERROR="command failed (exit $1): $2 (${3##*/}:$4)"
}

orchestrator_on_exit() {
  local status=$?
  trap - EXIT ERR INT TERM
  if [[ $ORCH_SUCCESS != true ]]; then
    if [[ $ORCH_INTERRUPTED == true ]]; then
      phases_record_failure 'interrupted'
      error 'Installation interrupted.'
      status=130
    elif [[ -n $PHASE_STARTED_AT ]]; then
      phases_record_failure "${ORCH_LAST_ERROR:-phase exited with status $status}"
      error 'Installation halted.'
      [[ $status -ne 0 ]] || status=1
    fi
  fi
  restore_cpu_governors
  cleanup_bind_mounts
  cleanup_live_hook_masks
  cleanup_target_hook_masks
  [[ $ORCH_SUCCESS == true ]] || cleanup_protected_state
  exit "$status"
}

orchestrator_on_interrupt() {
  ORCH_INTERRUPTED=true
  exit 130
}

