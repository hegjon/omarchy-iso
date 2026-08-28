#!/usr/bin/env bash
# The phase runner and exit handling main.sh relies on: state.json for the
# dashboard on success and on failure, fail()/die()/plain command failures all
# recorded with a message, cleanup on every path.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

cleanup_live_hook_masks() { record cleanup_live_hook_masks; }
cleanup_target_hook_masks() { record cleanup_target_hook_masks; }
cleanup_protected_state() { record cleanup_protected_state; }
error() { printf '%s\n' "$*" >&2; }

ok_phase() { record ok_phase; }
fail_phase() { fail 'boom'; }
cmd_fail_phase() { record before; false; record after; }
die_phase() { die 'library says no'; }

# Run a phase list exactly the way main.sh does, in a subshell.
run_main() {
  fresh_target
  (
    set -eEuo pipefail
    trap 'orchestrator_on_err "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
    trap orchestrator_on_exit EXIT
    PHASE_NAMES=() PHASE_FNS=()
    local p
    for p in "$@"; do add_phase "phase $p" "$p"; done
    phases_run
    ORCH_SUCCESS=true
  ) 2>"$ERR"
}
state() { jq -r "$1" "$CTX_STATE_DIR/state.json"; }

section 'success'
run_main ok_phase ok_phase
check 'exit 0' eq "$?" 0
check 'all phases ok' eq "$(state '[.phases[].status] | join(",")')" 'ok,ok'
check 'complete' eq "$(state .current_phase)" 'Installation complete'
check 'finished_at' test "$(state .finished_at)" != null
check 'index/total' eq "$(state '"\(.current_index)/\(.total_phases)"')" 1/2
check 'target published' eq "$(state .target)" "$CTX_TARGET"
check 'timing copy in target' test -f "$CTX_TARGET/var/log/omarchy-install-timing.json"
check 'cleanup ran' contains "$(calls)" cleanup_target_hook_masks

section 'fail() in a phase'
run_main ok_phase fail_phase ok_phase
check 'exit 1' eq "$?" 1
check 'failed phase recorded' eq "$(state '.phases[-1] | "\(.name):\(.status):\(.error)"')" 'phase fail_phase:failed:boom'
check 'earlier phase ok' eq "$(state '.phases[0].status')" ok
check 'later phase never ran' eq "$(state '.phases | length')" 2
check 'current phase is the failed one' eq "$(state .current_phase)" 'phase fail_phase'
check 'not finished' eq "$(state '.finished_at // "none"')" none
check 'halted message' contains "$(cat "$ERR")" "Phase 'phase fail_phase' failed after"
check 'halted message (2)' contains "$(cat "$ERR")" 'Installation halted.'
check 'cleanup ran' contains "$(calls)" cleanup_protected_state

section 'a failing command in a phase'
run_main cmd_fail_phase
check 'exit 1' eq "$?" 1
check 'stopped at the command' eq "$(calls | grep -c 'before\|after')" 1
check 'error names the command' contains "$(state '.phases[-1].error')" 'command failed (exit 1): false'

section 'die() from archinstall-bash'
die() { ORCH_LAST_ERROR=$*; printf 'error: %s\n' "$*" >&2; exit 1; } # the library's die with its hook applied
run_main die_phase
check 'exit 1' eq "$?" 1
check 'library message recorded' eq "$(state '.phases[-1].error')" 'library says no'

section 'the orchestrator ui wins over the library in either load order'
# The library defines info/error/list_contains only when none exist (its
# define-if-missing guards), and ui.sh defines unconditionally — so the
# orchestrator's shapes are in effect whichever side loads first, and
# main.sh's ui-first order is a contract, not a tightrope.
export ARCHINSTALL_LOG_DIR="$TMP/archinstall-log"
out=$(bash -c '
  source "$1/archinstall-bash/lib/archinstall.sh"
  source "$1/configs/airootfs/usr/share/omarchy-iso/orchestrator/ui.sh"
  info hi; list_contains "a b" b && echo contained
' _ "$ROOT" 2>&1)
check 'library first: info has the indented shape' eq "$out" $'\n    hi\ncontained'
out=$(bash -c '
  source "$1/configs/airootfs/usr/share/omarchy-iso/orchestrator/ui.sh"
  source "$1/archinstall-bash/lib/archinstall.sh"
  info hi; list_contains "a b" b && echo contained
' _ "$ROOT" 2>&1)
check 'ui first (main.sh order): the library defers to it' eq "$out" $'\n    hi\ncontained'

finish
