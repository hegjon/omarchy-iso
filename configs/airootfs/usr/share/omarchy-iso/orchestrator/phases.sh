# shellcheck shell=bash
# Phase state machine. Each phase is a (name, function) pair; functions run in
# this shell under set -eE and either return cleanly or exit (fail/die, or any
# failing command) to abort the install. The EXIT trap installed by main.sh
# records the failure in state.json.

PHASE_NAMES=() PHASE_FNS=()
PHASES_JSON='[]'
PHASE_STATE_PATH=''
PHASE_CURRENT_INDEX=0
PHASE_CURRENT_NAME='Starting installation'
PHASE_STARTED_AT=''
PHASE_TOTAL=0
PHASE_RUN_STARTED_AT=''
PHASE_FINISHED=false

add_phase() {
  PHASE_NAMES+=("$1")
  PHASE_FNS+=("$2")
}

now() {
  date '+%s.%N'
}

elapsed_since() {
  awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }'
}

# _write_state(): the dashboard polls this file while phases update it. Write
# atomically so the reader never observes a truncated JSON document.
phases_write_state() {
  local path=$1 extra=${2:-'{}'} tmp
  tmp="${path%/*}/.${path##*/}.tmp"
  jq -n --arg started "$PHASE_RUN_STARTED_AT" --arg target "$CTX_TARGET" --argjson total "$PHASE_TOTAL" \
    --argjson index "$PHASE_CURRENT_INDEX" --arg phase "$PHASE_CURRENT_NAME" --arg phase_started "${PHASE_STARTED_AT:-}" \
    --argjson phases "$PHASES_JSON" --argjson extra "$extra" '
    {started_at: ($started | tonumber), target: $target, total_phases: $total, current_index: $index,
     current_phase: $phase, phases: $phases}
    + (if $phase_started == "" then {} else {phase_started_at: ($phase_started | tonumber)} end)
    + $extra' >"$tmp"
  mv "$tmp" "$path"
}

# Phases that can measure themselves (the root image unpack, the verify
# wait) publish phase_progress (0..1) for the dashboard. It means nothing
# across phases, and every regular phase-boundary write regenerates the state
# without it — exactly the clearing the Python orchestrator did explicitly.
# Best effort: progress display must never fail an install.
phases_write_progress() {
  local fraction=$1
  [[ $fraction =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  [[ -n $PHASE_STATE_PATH ]] || return 0
  phases_write_state "$PHASE_STATE_PATH" \
    "$(jq -n --argjson p "$fraction" '{phase_progress: ([0, ([1, $p] | min)] | max)}')" 2>/dev/null || true
}

phases_record() {
  local name=$1 status=$2 elapsed=$3 err=${4:-}
  PHASES_JSON=$(jq -c --arg name "$name" --arg status "$status" --argjson elapsed "$elapsed" --arg err "$err" \
    '. + [{name: $name, status: $status, elapsed: $elapsed} + (if $err == "" then {} else {error: $err} end)]' <<<"$PHASES_JSON")
}

# run(ctx, phases)
phases_run() {
  mkdir -p "$CTX_STATE_DIR"
  PHASE_STATE_PATH="$CTX_STATE_DIR/state.json"
  PHASE_RUN_STARTED_AT=$(now)
  PHASE_TOTAL=${#PHASE_NAMES[@]}
  PHASE_CURRENT_INDEX=0
  PHASE_CURRENT_NAME='Starting installation'
  PHASES_JSON='[]'
  phases_write_state "$PHASE_STATE_PATH"

  local i
  for i in "${!PHASE_NAMES[@]}"; do
    PHASE_CURRENT_INDEX=$i
    PHASE_CURRENT_NAME=${PHASE_NAMES[i]}
    PHASE_STARTED_AT=$(now)
    phases_write_state "$PHASE_STATE_PATH"

    info "› ${PHASE_NAMES[i]}"
    ORCH_LAST_ERROR=''
    "${PHASE_FNS[i]}"
    phases_record "${PHASE_NAMES[i]}" ok "$(elapsed_since "$PHASE_STARTED_AT")"
    PHASE_STARTED_AT=''
    phases_write_state "$PHASE_STATE_PATH"
  done

  PHASE_CURRENT_INDEX=$((PHASE_TOTAL > 0 ? PHASE_TOTAL - 1 : 0))
  PHASE_CURRENT_NAME='Installation complete'
  PHASE_FINISHED=true
  # Expected vs actual for the bar's denominator, so drift is visible in
  # acceptance runs rather than only by watching a bar creep.
  local final
  final=$(jq -n --arg finished "$(now)" --argjson installed "$(installed_package_count "$CTX_TARGET")" \
    --argjson expected "$(expected_package_count)" \
    '{finished_at: ($finished | tonumber), installed_packages: $installed, expected_packages: $expected}')
  phases_write_state "$PHASE_STATE_PATH" "$final"

  local timing="$CTX_TARGET/var/log/omarchy-install-timing.json"
  mkdir -p "${timing%/*}"
  phases_write_state "$timing" "$final"
}

# Called from the EXIT trap when a phase did not complete.
phases_record_failure() {
  local message=$1
  [[ -n $PHASE_STARTED_AT && -n $PHASE_STATE_PATH ]] || return 0
  local elapsed
  elapsed=$(elapsed_since "$PHASE_STARTED_AT")
  phases_record "$PHASE_CURRENT_NAME" failed "$elapsed" "$message"
  phases_write_state "$PHASE_STATE_PATH"
  error "Phase '$PHASE_CURRENT_NAME' failed after $(printf '%.1f' "$elapsed")s: $message"
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
