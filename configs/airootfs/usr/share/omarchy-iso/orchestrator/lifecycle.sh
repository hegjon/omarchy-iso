# shellcheck shell=bash
# What main()'s finally did in Python: CPU governors, hook masks and the
# protected target are put back on every exit path (mounts are systemd's:
# PartOf= the install target tears them down). All idempotent.

# The live hook masks install_system_payload puts up around pacstrap; Python
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
#
# Swapoff, umount -R, and close of the mappers the mounts were backed by —
# shared with the dashboard's pre-reboot release. omarchy_root is named
# explicitly because a failure between luksOpen and mount leaves it open with
# nothing in the mount table for the release to see. On failure the script
# names the holders on stderr; surface that in the install log.
cleanup_protected_state() {
  [[ $CTX_IS_PROTECTED == true ]] || return 0
  local out line
  out=$(omarchy-release-install-target "$CTX_TARGET" omarchy_root 2>&1) || true
  while IFS= read -r line; do
    [[ -n $line ]] && info "release: $line"
  done <<<"$out"
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
    else
      # A phase that failed recorded itself from its own process;
      # phases_record_failure self-guards against telling it twice, and
      # covers what no phase could record -- a death outside the graph.
      phases_record_failure "${ORCH_LAST_ERROR:-install exited with status $status}"
      error 'Installation halted.'
      [[ $status -ne 0 ]] || status=1
    fi
  fi
  # Stopping the target is the group abort and the governor restore in one:
  # PartOf= takes down any running phase unit cgroup-complete, and the CPU
  # boost unit's ExecStop puts the saved governors back. Idempotent when
  # nothing is running.
  systemctl stop omarchy-install.target >/dev/null 2>&1 || true
  # No-op after a completed install (create_factory_snapshot joined it); on a
  # failure it ends the unit before the target is torn down.
  stop_target_keyring_init
  cleanup_live_hook_masks
  cleanup_target_hook_masks
  [[ $ORCH_SUCCESS == true ]] || cleanup_protected_state
  exit "$status"
}

orchestrator_on_interrupt() {
  ORCH_INTERRUPTED=true
  exit 130
}

