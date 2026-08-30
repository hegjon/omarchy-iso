# shellcheck shell=bash
# Phase state, file-backed. The sequencing itself lives in the phase units'
# Requires=/After= edges (systemd walks the graph when the orchestrator
# starts the terminal unit); what lives here is the state.json contract the
# dashboard polls -- seeded by the orchestrator, updated by each phase's own
# run-phase process, finalized by the orchestrator. Every writer goes
# through one atomic read-modify-write so the poller never observes a
# truncated document, and sequential phases mean no two phase writers race.

PHASE_STATE_FILE=''

now() {
  date '+%s.%N'
}

elapsed_since() {
  awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }'
}

phases_state_init() {
  PHASE_STATE_FILE="$CTX_STATE_DIR/state.json"
}

phases_state_update() { # jq args...
  local tmp="${PHASE_STATE_FILE%/*}/.${PHASE_STATE_FILE##*/}.tmp"
  jq "$@" "$PHASE_STATE_FILE" >"$tmp" && mv "$tmp" "$PHASE_STATE_FILE"
}

# The roster IS the unit graph: a phase unit is exactly a unit whose
# ExecStart runs run-phase, so the dashboard's denominator comes from
# counting them -- no second list to keep in step with the edges.
phase_unit_count() {
  grep -lE '^ExecStart=.*run-phase ' /etc/systemd/system/omarchy-install-*.service 2>/dev/null | wc -l
}

phases_seed_state() {
  mkdir -p "$CTX_STATE_DIR"
  phases_state_init
  jq -n --arg started "$(now)" --arg target "$CTX_TARGET" \
    --argjson total "$(phase_unit_count)" '
    {started_at: ($started | tonumber), target: $target, total_phases: $total,
     current_index: 0, current_phase: "Starting installation", phases: []}' >"$PHASE_STATE_FILE"
}

# run-phase, at phase start: who is running, since when. Clears the previous
# phase's progress -- phase_progress means nothing across phases.
phases_enter() {
  phases_state_init
  # A phase started outside a seeded install (a manual systemctl start)
  # still runs; it just has no state document to report into.
  [[ -f $PHASE_STATE_FILE ]] || return 0
  phases_state_update --arg name "$1" --arg t "$(now)" \
    '.current_phase = $name | .phase_started_at = ($t | tonumber)
     | .current_index = (.phases | length) | del(.phase_progress)'
}

# run-phase, at phase end (either way): the phase's permanent record.
phases_leave() { # name, ok|failed, started_at, [error]
  local name=$1 status=$2 started=$3 err=${4:-}
  phases_state_init
  # A phase started outside a seeded install (a manual systemctl start)
  # still runs; it just has no state document to report into.
  [[ -f $PHASE_STATE_FILE ]] || return 0
  phases_state_update --arg name "$name" --arg status "$status" \
    --argjson elapsed "$(elapsed_since "$started")" --arg err "$err" \
    '.phases += [{name: $name, status: $status, elapsed: $elapsed}
                 + (if $err == "" then {} else {error: $err} end)]
     | del(.phase_started_at)'
}

# Phases that can measure themselves (the root image unpack, the verify
# wait) publish phase_progress (0..1) for the dashboard. File-backed, so it
# works from whichever process hosts the phase. Best effort: progress
# display must never fail an install.
phases_write_progress() {
  local fraction=$1
  [[ $fraction =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  phases_state_init
  [[ -f $PHASE_STATE_FILE ]] || return 0
  phases_state_update --argjson p "$fraction" \
    '.phase_progress = ([0, ([1, $p] | min)] | max)' 2>/dev/null || true
}

# Orchestrator, after the graph completes. Expected vs actual for the bar's
# denominator, so drift is visible in acceptance runs rather than only by
# watching a bar creep; the timing copy lands on the installed system.
phases_finalize() {
  phases_state_init
  phases_state_update --arg finished "$(now)" \
    --argjson installed "$(installed_package_count "$CTX_TARGET")" \
    --argjson expected "$(expected_package_count)" '
    .current_phase = "Installation complete"
    | .current_index = (if .total_phases > 0 then .total_phases - 1 else 0 end)
    | .finished_at = ($finished | tonumber)
    | .installed_packages = $installed | .expected_packages = $expected
    | del(.phase_started_at)'

  local timing="$CTX_TARGET/var/log/omarchy-install-timing.json"
  mkdir -p "${timing%/*}"
  cp "$PHASE_STATE_FILE" "$timing"
}

# Orchestrator's exit trap, for a failure no phase recorded: an interrupt,
# or dying outside any phase. A real phase failure was already written by
# that phase's run-phase; appending it again would tell it twice.
phases_record_failure() {
  local message=$1 name started elapsed=0
  phases_state_init
  [[ -f $PHASE_STATE_FILE ]] || return 0
  [[ $(jq -r '.phases[-1].status // ""' "$PHASE_STATE_FILE" 2>/dev/null) == failed ]] && return 0
  name=$(jq -r '.current_phase' "$PHASE_STATE_FILE" 2>/dev/null)
  started=$(jq -r '.phase_started_at // empty' "$PHASE_STATE_FILE" 2>/dev/null)
  [[ -n $started ]] && elapsed=$(elapsed_since "$started")
  phases_state_update --arg name "$name" --arg err "$message" --argjson elapsed "$elapsed" \
    '.phases += [{name: $name, status: "failed", elapsed: $elapsed, error: $err}]
     | del(.phase_started_at)'
  error "Phase '$name' failed after $(printf '%.1f' "$elapsed")s: $message"
}

# _installed_package_count(): one directory per package under local/, which
# is what the dashboard counts live.
installed_package_count() {
  local local_db="$1/var/lib/pacman/local" n=0 entry
  [[ -d $local_db ]] || { printf 0; return 0; }
  for entry in "$local_db"/*/; do
    [[ -d $entry ]] && n=$((n + 1))
  done
  printf '%s' "$n"
}

expected_package_count() {
  local n
  n=$(awk 'NR == 1 { print $1; exit }' /usr/share/omarchy-iso/expected-packages 2>/dev/null)
  [[ $n =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}
