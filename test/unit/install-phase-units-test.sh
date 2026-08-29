#!/bin/bash
#
# The behavior of the install's systemd hosting, driven for real: the
# run-phase entrypoint (dispatch, the destruction boundary, the failure-path
# mount cleanup and error handover), the orchestrator's unit join, the CPU
# governor helper against a fake sysfs, and the cross-process passphrase
# guarantee. What a unit file merely declares is not restated here — the
# integration installs prove the wiring.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ORCH="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator"

failures=0
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description"
    failures=$((failures + 1))
  fi
}

# The governor helper: boost and restore run in different processes, so the
# mechanics are driven against a fake sysfs to prove the state file carries
# the governors across.
cpu_governor_mechanics() {
  local d
  d=$(mktemp -d) || return 1
  mkdir -p "$d/sys/cpu0/cpufreq" "$d/sys/cpu1/cpufreq"
  printf 'schedutil\n' >"$d/sys/cpu0/cpufreq/scaling_governor"
  printf 'powersave\n' >"$d/sys/cpu1/cpufreq/scaling_governor"
  CPU_SYSFS="$d/sys" OMARCHY_INSTALL_STATE_DIR="$d/state" \
    "$ROOT/configs/airootfs/usr/local/bin/omarchy-cpu-governor" boost >/dev/null &&
  [[ $(<"$d/sys/cpu0/cpufreq/scaling_governor") == performance ]] &&
  [[ $(<"$d/sys/cpu1/cpufreq/scaling_governor") == performance ]] &&
  CPU_SYSFS="$d/sys" OMARCHY_INSTALL_STATE_DIR="$d/state" \
    "$ROOT/configs/airootfs/usr/local/bin/omarchy-cpu-governor" restore &&
  [[ $(<"$d/sys/cpu0/cpufreq/scaling_governor") == schedutil ]] &&
  [[ $(<"$d/sys/cpu1/cpufreq/scaling_governor") == powersave ]] &&
  [[ ! -e $d/state/cpu-governors ]]
  local rc=$?
  rm -rf "$d"
  return $rc
}
check "boost and restore carry the governors through the state file" cpu_governor_mechanics

# run-phase itself: sourceable main.sh, dispatch, refusals — including the
# destruction boundary, which must fail loudly rather than skip.
check "sourcing main.sh defines but does not run the install" \
  bash -c "env OMARCHY_ARCHINSTALL_LIB='$ROOT/archinstall-bash/lib' bash -c \
    \"source '$ORCH/main.sh' && declare -F main >/dev/null && declare -F install_root_image >/dev/null\""
check "run-phase refuses an unknown phase" \
  bash -c "! env OMARCHY_ARCHINSTALL_LIB='$ROOT/archinstall-bash/lib' '$ORCH/run-phase' no_such_phase 2>/dev/null"

fixtures=$(mktemp -d)
trap 'rm -rf "$fixtures"' EXIT
cat >"$fixtures/config.json" <<'JSON'
{"disk_config": {"config_type": "default_layout", "device_modifications": []},
 "bootloader_config": {"bootloader": "limine"}, "hostname": "phase-smoke",
 "omarchy_install": {"mode": "full_disk", "target_mount": "/mnt"}}
JSON
printf '{"users": [{"username": "smoke", "!password": "x"}]}\n' >"$fixtures/creds.json"
run_phase_env() { # extra-env... phase
  env OMARCHY_INSTALL_CONFIG="$fixtures/config.json" OMARCHY_INSTALL_CREDS="$fixtures/creds.json" \
    OMARCHY_INSTALL_STATE_DIR="$fixtures/state" OMARCHY_ARCHINSTALL_LIB="$ROOT/archinstall-bash/lib" \
    "$@"
}
check "run-phase rebuilds context and library config, then dispatches" \
  bash -c "$(declare -f run_phase_env); fixtures='$fixtures'; ROOT='$ROOT'
    run_phase_env env RUN_PHASE_NO_TARGET=1 '$ORCH/run-phase' config_summary 2>/dev/null | grep -q phase-smoke"
check "and persisted the env files a phase unit would read" \
  bash -c "test -f '$fixtures/state/context.env' && test -f '$fixtures/state/install.env'"
check "run-phase refuses a phase before the disk phase mounted the target" \
  bash -c "$(declare -f run_phase_env); fixtures='$fixtures'; ROOT='$ROOT'
    run_phase_env '$ORCH/run-phase' config_summary 2>&1 | grep -q 'not a mounted install target'"

# run-phase's failure-path mount cleanup: the hosted phase registers stage
# mounts in a per-process array, so the entrypoint must unmount them itself
# when the phase dies — and must not touch them on a clean exit, where the
# phase already unmounted its own.
cleanup_trap_mechanics() {
  local d
  d=$(mktemp -d) || return 1
  sed -n '/^run_phase_cleanup() {/,/^}/p' "$ORCH/run-phase" >"$d/fn.sh"
  UNMOUNT_LOG="$d/log" bash -c '
    umount() { echo "UNMOUNTED:$1" >>"$UNMOUNT_LOG"; }
    source "'"$d"'/fn.sh"
    CTX_BIND_MOUNTS=(/stage/a /stage/b)
    (exit 7); run_phase_cleanup
    CTX_BIND_MOUNTS=(/stage/c)
    (exit 0); run_phase_cleanup
  '
  local got
  got=$(cat "$d/log" 2>/dev/null)
  rm -rf "$d"
  [[ $got == $'UNMOUNTED:/stage/a\nUNMOUNTED:/stage/b' ]]
}
check "run-phase unmounts the phase's stage mounts on a failing exit only" cleanup_trap_mechanics

# And hands the phase's own fail() message to the orchestrator through the
# state dir — the journal buries it under command output and systemd's exit
# lines, which is exactly how the re-flash advice got lost once.
error_handover() {
  local d got
  d=$(mktemp -d) || return 1
  sed -n '/^run_phase_cleanup() {/,/^}/p' "$ORCH/run-phase" >"$d/fn.sh"
  bash -c '
    umount() { :; }
    source "'"$d"'/fn.sh"
    CTX_STATE_DIR="'"$d"'"; CTX_BIND_MOUNTS=()
    ORCH_LAST_ERROR="install medium is corrupt: re-flash it"
    (exit 1); run_phase_cleanup
  '
  got=$(cat "$d/phase-error" 2>/dev/null)
  rm -rf "$d"
  [[ $got == "install medium is corrupt: re-flash it" ]]
}
check "run-phase hands the phase's fail message over on a failing exit" error_handover

run_phase_unit_prefers_handover() {
  local d out
  d=$(mktemp -d) || return 1
  out=$(bash -c '
    # The unit writes the handover file on its way down, after run_phase_unit
    # cleared any stale one — the stub mirrors that sequence.
    systemctl() { [[ $1 == start ]] && { printf "install medium is too slow: try another USB stick" >"$CTX_STATE_DIR/phase-error"; return 1; }; echo mocked; }
    journalctl() { echo "systemd noise only"; }
    fail() { echo "FAIL:$*"; exit 1; }
    CTX_STATE_DIR="'"$d"'"
    '"$(sed -n '/^run_phase_unit() {/,/^}/p' "$ORCH/root_image.sh")"'
    run_phase_unit some.unit "the gate"
  ' 2>&1)
  rm -rf "$d"
  [[ $out == *"install medium is too slow"* && $out != *"systemd noise"* ]]
}
check "run_phase_unit prefers the handed-over message to the journal" run_phase_unit_prefers_handover

# The property the deferred-encrypted flavor of that phase depends on: the
# generated LUKS passphrase is generated once and reused by every later
# context rebuild — two separate processes must agree on it.
passphrase_deterministic() {
  local d p1 p2
  d=$(mktemp -d) || return 1
  printf '{"disk_config": {"config_type": "default_layout", "device_modifications": [], "disk_encryption": {"encryption_type": "luks"}}, "omarchy_install": {"defer_provisioning": true}}' >"$d/config.json"
  touch "$d/marker"
  ctx_pass() {
    env OMARCHY_INSTALL_CONFIG="$d/config.json" OMARCHY_INSTALL_CREDS="$d/absent" \
      OMARCHY_INSTALL_DEFER_PROVISIONING_FILE="$d/marker" OMARCHY_INSTALL_STATE_DIR="$d/state" \
      OMARCHY_ARCHINSTALL_LIB="$ROOT/archinstall-bash/lib" bash -c \
      "source '$ORCH/main.sh' && ctx_from_env >/dev/null 2>&1 && jq -r .encryption_password \"\$CTX_STATE_DIR/provisioning-user_credentials.json\""
  }
  p1=$(ctx_pass); p2=$(ctx_pass)
  rm -rf "$d"
  [[ -n $p1 && $p1 == "$p2" ]]
}
check "the generated passphrase is deterministic across processes" passphrase_deterministic

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'the install phase hosting behaves\n'
