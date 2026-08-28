#!/usr/bin/env bash
#
# Omarchy install orchestrator.
#
# Single tool that owns the full install phase ordering, with archinstall-bash
# used as a library subsystem (not as the top-level installer). The live-ISO
# wrapper (omarchy-iso-install) consumes CLI args and passes configuration
# paths via OMARCHY_INSTALL_* environment variables.
#
# Phase functions run in this shell: any failing command, fail() or the
# library's die() ends the install, and the EXIT trap does what the Python
# orchestrator's finally did — record the failed phase for the dashboard,
# restore CPU governors, unwind bind mounts and hook masks, tear down a
# protected target.

set -eEuo pipefail

ORCHESTRATOR_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# ui.sh before the library, structurally: the orchestrator's info, error and
# list_contains must be the definitions in effect (the dashboard log relies
# on their shape), and the library defines its own only when none exist —
# so precedence is a define-if-missing contract, not source-order luck.
# shellcheck disable=SC1090
source "$ORCHESTRATOR_DIR/ui.sh"
OMARCHY_ARCHINSTALL_LIB=${OMARCHY_ARCHINSTALL_LIB:-/usr/share/archinstall-bash/lib}
if [[ ! -f $OMARCHY_ARCHINSTALL_LIB/archinstall.sh ]]; then
  printf 'error: archinstall-bash missing at %s\n' "$OMARCHY_ARCHINSTALL_LIB" >&2
  exit 2
fi
# shellcheck disable=SC1091
source "$OMARCHY_ARCHINSTALL_LIB/archinstall.sh"
for _module in context phases archinstall root_image install limine target_setup provisioning lifecycle; do
  # shellcheck disable=SC1090
  source "$ORCHESTRATOR_DIR/$_module.sh"
done
unset _module

# Phase order. The ordering is the whole point of this orchestrator:
# package-install hooks (limine-mkinitcpio-hook, in particular) and useradd
# happen at points where their prerequisites are guaranteed to be in place.
#
# Full-disk and protected installs use the same phase sequence. The
# configurator only changes the JSON input: full-disk asks the installer to
# create/mount the layout, while protected provides an already-mounted target
# and the partition details Omarchy needs for boot/fstab generation.
build_phases() {
  add_phase 'Preparing live environment' prepare_live
  add_phase 'Preparing install target' prepare_install_target
  add_phase 'Installing Arch + Omarchy' arch_install_system
  add_phase 'Configuring hibernation' configure_hibernation_unit
  add_phase 'Configuring system' run_system_finalizer_unit
  # Before finalize_limine_boot: the deferred-provisioning cryptkey drop-in
  # and keyfile must be in place for the final UKI build.
  add_phase 'Staging provisioning' stage_provisioning_state_unit
  add_phase 'Finalizing Limine boot' finalize_limine_boot_unit
  add_phase 'Finalizing user' run_chroot_finalizer_unit
  add_phase 'Configuring login' configure_login_unit
  add_phase 'Configuring SSH access' configure_ssh_access_unit
  add_phase 'Configuring Tailscale' configure_tailscale_unit
  add_phase 'Configuring DNS resolver' configure_dns_resolver_unit
  add_phase 'Validating boot setup' validate_boot_unit
  add_phase 'Creating factory snapshot' create_factory_snapshot_unit
}

main() {
  ctx_from_env

  local who=$CTX_USERNAME
  [[ -n $who ]] || who='deferred provisioning (user created at first boot)'
  info "Installing Omarchy for $who → $CTX_TARGET"

  # The umbrella for the systemd-run phases: parts declare PartOf= it, so
  # stopping it is the group abort that takes any running phase's cgroup.
  systemctl start omarchy-install.target >/dev/null 2>&1 || true

  trap 'orchestrator_on_err "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
  trap orchestrator_on_exit EXIT
  trap orchestrator_on_interrupt INT TERM

  arch_init_library
  boost_cpu_governor
  build_phases
  phases_run

  ORCH_SUCCESS=true
  info 'Installation complete.'
}

# Executed (omarchy-iso-install execs this file): run the install. Sourced
# (run-phase, which hosts one phase function in its own process for the
# systemd phase units): definitions only.
[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
