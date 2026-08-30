#!/usr/bin/env bash
# The file-backed phase state main.sh and run-phase share: seeded by the
# orchestrator, entered/left by each phase's own process, finalized on
# success, with the failure fallback recording exactly once. Drives the real
# helpers against a throwaway state dir the way the two processes do.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

cleanup_live_hook_masks() { record cleanup_live_hook_masks; }
cleanup_target_hook_masks() { record cleanup_target_hook_masks; }
cleanup_protected_state() { record cleanup_protected_state; }
stop_target_keyring_init() { record stop_target_keyring_init; }
systemctl() { record "systemctl $*"; }
error() { printf '%s\n' "$*" >&2; }

# The roster is counted off the shipped unit files; the sandbox has none.
phase_unit_count() { echo 2; }

state() { jq -r "$1" "$CTX_STATE_DIR/state.json"; }

# One phase's life as run-phase lives it.
simulate_phase() { # name, ok|failed, [error]
  local started
  phases_enter "$1"
  started=$(now)
  phases_leave "$1" "$2" "$started" "${3:-}"
}

section 'success: seed, two phases, finalize'
fresh_target
phases_seed_state
check 'seeded pending' eq "$(state '"\(.current_phase)/\(.total_phases)"')" 'Starting installation/2'
simulate_phase 'phase one' ok
check 'first recorded' eq "$(state '.phases[0] | "\(.name):\(.status)"')" 'phase one:ok'
simulate_phase 'phase two' ok
phases_finalize
check 'all phases ok' eq "$(state '[.phases[].status] | join(",")')" 'ok,ok'
check 'complete' eq "$(state .current_phase)" 'Installation complete'
check 'finished_at' test "$(state .finished_at)" != null
check 'index/total' eq "$(state '"\(.current_index)/\(.total_phases)"')" 1/2
check 'target published' eq "$(state .target)" "$CTX_TARGET"
check 'timing copy in target' test -f "$CTX_TARGET/var/log/omarchy-install-timing.json"

section 'a phase failure is recorded once'
fresh_target
phases_seed_state
simulate_phase 'phase one' ok
simulate_phase 'phase two' failed 'boom'
# The orchestrator's exit trap fires after the graph start fails; the
# phase already told its story, so the fallback must not tell it twice.
phases_record_failure 'install phase omarchy-install-two.service failed' 2>/dev/null
check 'recorded exactly once' eq "$(state '.phases | length')" 2
check 'the phase’s own words' eq "$(state '.phases[-1] | "\(.name):\(.status):\(.error)"')" 'phase two:failed:boom'

section 'a failure no phase recorded falls back to current_phase'
fresh_target
phases_seed_state
phases_enter 'phase interrupted'
phases_record_failure 'interrupted' 2>/dev/null
check 'fallback recorded' eq "$(state '.phases[-1] | "\(.name):\(.status):\(.error)"')" 'phase interrupted:failed:interrupted'
check 'started stamp cleared' eq "$(state '.phase_started_at // "gone"')" gone

section 'progress: clamped, phase-scoped'
fresh_target
phases_seed_state
phases_enter 'measuring phase'
phases_write_progress 1.5
check 'clamped high' eq "$(state .phase_progress)" 1
phases_write_progress 0.25
check 'fraction kept' eq "$(state .phase_progress)" 0.25
phases_write_progress bogus
check 'garbage ignored' eq "$(state .phase_progress)" 0.25
phases_enter 'next phase'
check 'cleared on the next phase' eq "$(state '.phase_progress // "gone"')" gone

section 'exit trap: cleanup on the failure path, once'
fresh_target
reset_calls
(
  set -eEuo pipefail
  trap 'orchestrator_on_err "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
  trap orchestrator_on_exit EXIT
  phases_seed_state
  phases_enter 'phase doomed'
  fail 'graph start failed'
) 2>"$ERR"
check 'exit 1' eq "$?" 1
check 'failure recorded via fallback' eq "$(state '.phases[-1] | "\(.name):\(.status)"')" 'phase doomed:failed'
check 'halt message' contains "$(cat "$ERR")" 'Installation halted.'
check 'group abort issued' contains "$(calls)" 'systemctl stop omarchy-install.target'
check 'cleanups ran' contains "$(calls)" cleanup_target_hook_masks

finish
