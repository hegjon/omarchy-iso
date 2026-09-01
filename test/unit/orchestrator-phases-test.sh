#!/usr/bin/env bash
# The systemd-backed phase state: progress published over sd_notify, the
# timing record generated from systemd's own unit timestamps, and the exit
# trap's cleanup. The unit graph itself is the install's state now -- there
# is no parallel document to seed, enter or finalize per phase.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

cleanup_target_hook_masks() { record cleanup_target_hook_masks; }
cleanup_protected_state() { record cleanup_protected_state; }
systemctl() { record "systemctl $*"; }
error() { printf '%s\n' "$*" >&2; }

section 'progress rides sd_notify STATUS='
systemd-notify() { record "systemd-notify $* socket=${NOTIFY_SOCKET:-}"; }
reset_calls
# Unset in a subshell: a desktop session exports its own NOTIFY_SOCKET, and
# in production the unit's own socket must win when present.
(unset NOTIFY_SOCKET; phases_write_progress 0.25)
check 'fraction published' contains "$(calls)" '--status=progress=0.25'
check 'socket defaulted for watcher subshells' contains "$(calls)" 'socket=/run/systemd/notify'
reset_calls
(NOTIFY_SOCKET=/run/unit/socket phases_write_progress 0.25)
check 'the unit-provided socket wins' contains "$(calls)" 'socket=/run/unit/socket'
reset_calls
phases_write_progress bogus
phases_write_progress ''
check 'garbage never reaches systemd' eq "$(calls)" ''
# Progress is best effort: a notify failure must never fail the phase.
systemd-notify() { return 1; }
check 'a failed notify is swallowed' phases_write_progress 0.5
unset -f systemd-notify

section 'the timing record comes from the unit timestamps'
fresh_target
UNITS="$TMP/units"
rm -rf "$UNITS"
mkdir -p "$UNITS"
export OMARCHY_INSTALL_UNITS_DIR="$UNITS"
make_unit() { # unit-basename display-name
  printf '[Service]\nExecStart=/usr/share/omarchy-iso/orchestrator/run-phase fn "%s"\n' \
    "$2" >"$UNITS/omarchy-install-$1.service"
}
make_unit alpha 'First phase'
make_unit beta 'Second phase'
make_unit gamma 'Never ran'
# Not a phase unit: no run-phase ExecStart, must not appear in the record.
printf '[Service]\nExecStart=/usr/bin/true\n' >"$UNITS/omarchy-install-helper.service"
# The stub answers `show <unit> -p ActiveState,Result,ExecMainStart...,ExecMainExit... --value`
# in systemctl's --value format: one line per property, in the asked order.
# beta started first and failed; alpha ran after it and succeeded (the sort
# must follow the timestamps, not the file names); gamma never ran.
systemctl() {
  case "$2" in
    omarchy-install-alpha.service) printf 'active\nsuccess\n2000000\n3500000\n' ;;
    omarchy-install-beta.service) printf 'failed\nexit-code\n1000000\n1750000\n' ;;
    omarchy-install-gamma.service) printf 'inactive\nsuccess\n0\n0\n' ;;
    *) printf 'inactive\nsuccess\n0\n0\n' ;;
  esac
}
mkdir -p "$CTX_TARGET/var/lib/pacman/local/pkg-one-1.0-1" "$CTX_TARGET/var/lib/pacman/local/pkg-two-1.0-1"
expected_package_count() { printf 3; }
phases_finalize
TIMING="$CTX_TARGET/var/log/omarchy-install-timing.json"
check 'timing copy in target' test -f "$TIMING"
check 'phases in start order, only the ones that ran' \
  eq "$(jq -r '[.phases[].name] | join(",")' "$TIMING")" 'Second phase,First phase'
check 'status from the unit result' \
  eq "$(jq -r '[.phases[].status] | join(",")' "$TIMING")" 'failed,ok'
check 'elapsed from the monotonic pair' \
  eq "$(jq -r '[.phases[].elapsed] | join(",")' "$TIMING")" '0.750,1.500'
check 'package counts recorded' \
  eq "$(jq -r '"\(.installed_packages)/\(.expected_packages)"' "$TIMING")" '2/3'
check 'finished stamp present' test "$(jq -r .finished_at "$TIMING")" != null
unset OMARCHY_INSTALL_UNITS_DIR
systemctl() { record "systemctl $*"; }

section 'exit trap: cleanup on the failure path'
fresh_target
reset_calls
(
  set -eEuo pipefail
  trap 'orchestrator_on_err "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
  trap orchestrator_on_exit EXIT
  fail 'graph start failed'
) 2>"$ERR"
check 'exit 1' eq "$?" 1
check 'halt message' contains "$(cat "$ERR")" 'Installation halted.'
check 'group abort issued' contains "$(calls)" 'systemctl stop omarchy-install.target'
check 'the protected-target release ran' contains "$(calls)" cleanup_protected_state
check 'the target hook unmask is the system unit'\''s, not the trap'\''s' \
  test -z "$(calls | grep cleanup_target_hook_masks || true)"

section 'exit trap: an interrupt tells its own story'
fresh_target
reset_calls
(
  set -eEuo pipefail
  trap orchestrator_on_exit EXIT
  ORCH_INTERRUPTED=true
  exit 130
) 2>"$ERR"
check 'exit 130' eq "$?" 130
check 'interrupt message' contains "$(cat "$ERR")" 'Installation interrupted.'
check 'group abort issued' contains "$(calls)" 'systemctl stop omarchy-install.target'

finish
