#!/bin/bash
#
# The systemd side of the install: omarchy-install.target as the umbrella the
# phase units (and the keyring init) belong to, and the first migrated phase,
# omarchy-install-image.service, hosted by run-phase. What is checked here is
# the wiring that decides whether a phase runs in the right context and can
# be aborted as a group — cheap to check, expensive to discover from a
# wedged install.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
UNITS="$ROOT/configs/airootfs/etc/systemd/system"
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

check "the install target exists" test -f "$UNITS/omarchy-install.target"
check "the image unit is part of it" \
  grep -qxF 'PartOf=omarchy-install.target' "$UNITS/omarchy-install-image.service"
check "so is the keyring init" \
  grep -qxF 'PartOf=omarchy-install.target' "$UNITS/omarchy-target-keyring.service"
check "the orchestrator starts the target" \
  grep -qF 'systemctl start omarchy-install.target' "$ORCH/main.sh"

check "the image unit is a oneshot" \
  grep -qxF 'Type=oneshot' "$UNITS/omarchy-install-image.service"
check "it runs the phase through run-phase" \
  grep -qxF 'ExecStart=/usr/share/omarchy-iso/orchestrator/run-phase install_root_image' \
    "$UNITS/omarchy-install-image.service"
# Context defaults, this run's resolved values, and the raw inputs
# ctx_from_env rebuilds the rest from — later files win.
for env in '/usr/share/omarchy-iso/orchestrator/context.env' \
           '-/run/omarchy-install/context.env' '-/run/omarchy-install/install.env'; do
  check "image unit reads $env" \
    grep -qxF "EnvironmentFile=$env" "$UNITS/omarchy-install-image.service"
done
check "its timeout is sized on the stream at build" \
  grep -qF 'omarchy-install-image.service.d' "$ROOT/builder/build-iso.sh"

# The second migrated phase: hibernation, ordered after the image — the edge
# is inert while the orchestrator serializes, and is the graph the eventual
# all-units install enforces by itself.
check "the hibernation unit is part of the target" \
  grep -qxF 'PartOf=omarchy-install.target' "$UNITS/omarchy-install-hibernation.service"
check "it is ordered after the image unit" \
  grep -qxF 'After=omarchy-install-image.service' "$UNITS/omarchy-install-hibernation.service"
check "it runs its phase through run-phase" \
  grep -qxF 'ExecStart=/usr/share/omarchy-iso/orchestrator/run-phase configure_hibernation' \
    "$UNITS/omarchy-install-hibernation.service"
for env in '/usr/share/omarchy-iso/orchestrator/context.env' \
           '-/run/omarchy-install/context.env' '-/run/omarchy-install/install.env'; do
  check "hibernation unit reads $env" \
    grep -qxF "EnvironmentFile=$env" "$UNITS/omarchy-install-hibernation.service"
done
check "the phase loop runs hibernation via its unit" \
  grep -qF "add_phase 'Configuring hibernation' configure_hibernation_unit" "$ORCH/main.sh"

# Third: the system finalizer, ordered after hibernation.
check "the system unit is part of the target" \
  grep -qxF 'PartOf=omarchy-install.target' "$UNITS/omarchy-install-system.service"
check "it is ordered after the hibernation unit" \
  grep -qxF 'After=omarchy-install-hibernation.service' "$UNITS/omarchy-install-system.service"
check "it runs its phase through run-phase" \
  grep -qxF 'ExecStart=/usr/share/omarchy-iso/orchestrator/run-phase run_system_finalizer' \
    "$UNITS/omarchy-install-system.service"
for env in '/usr/share/omarchy-iso/orchestrator/context.env' \
           '-/run/omarchy-install/context.env' '-/run/omarchy-install/install.env'; do
  check "system unit reads $env" \
    grep -qxF "EnvironmentFile=$env" "$UNITS/omarchy-install-system.service"
done
check "the phase loop runs the system finalizer via its unit" \
  grep -qF "add_phase 'Configuring system' run_system_finalizer_unit" "$ORCH/main.sh"

check "run-phase is executable in the ISO" \
  grep -qF '["/usr/share/omarchy-iso/orchestrator/run-phase"]="0:0:755"' "$ROOT/configs/profiledef.sh"
# The sourced-main check needs the library reachable the way run-phase finds
# it; point it at the vendored tree the way the harness does.
check "sourcing main.sh defines but does not run the install" \
  env OMARCHY_ARCHINSTALL_LIB="$ROOT/archinstall-bash/lib" bash -c \
    "source '$ORCH/main.sh' && declare -F main >/dev/null && declare -F install_root_image >/dev/null"
check "run-phase refuses an unknown phase" \
  bash -c "! env OMARCHY_ARCHINSTALL_LIB='$ROOT/archinstall-bash/lib' '$ORCH/run-phase' no_such_phase 2>/dev/null"

# The full hosting path, with the library config loaded: fixture inputs in,
# context and CFG_* rebuilt, a harmless function dispatched. This is the
# contract every migrated phase rides on.
fixtures=$(mktemp -d)
trap 'rm -rf "$fixtures"' EXIT
cat >"$fixtures/config.json" <<'JSON'
{"disk_config": {"config_type": "default_layout", "device_modifications": []},
 "bootloader_config": {"bootloader": "limine"}, "hostname": "phase-smoke",
 "omarchy_install": {"mode": "full_disk", "target_mount": "/mnt"}}
JSON
printf '{"users": [{"username": "smoke", "!password": "x"}]}\n' >"$fixtures/creds.json"
check "run-phase rebuilds context and library config, then dispatches" \
  bash -c "env OMARCHY_INSTALL_CONFIG='$fixtures/config.json' OMARCHY_INSTALL_CREDS='$fixtures/creds.json' \
      OMARCHY_INSTALL_STATE_DIR='$fixtures/state' OMARCHY_ARCHINSTALL_LIB='$ROOT/archinstall-bash/lib' \
      '$ORCH/run-phase' config_summary 2>/dev/null | grep -q 'phase-smoke'"
check "and persisted the env files a phase unit would read" \
  bash -c "test -f '$fixtures/state/context.env' && test -f '$fixtures/state/install.env'"

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'the install target and its phase units are wired\n'
