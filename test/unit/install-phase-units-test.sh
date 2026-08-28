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

# Fourth: provisioning staging, after the system finalizer.
check "the provisioning unit is part of the target" \
  grep -qxF 'PartOf=omarchy-install.target' "$UNITS/omarchy-install-provisioning.service"
check "it is ordered after the system unit" \
  grep -qxF 'After=omarchy-install-system.service' "$UNITS/omarchy-install-provisioning.service"
check "it runs its phase through run-phase" \
  grep -qxF 'ExecStart=/usr/share/omarchy-iso/orchestrator/run-phase stage_provisioning_state' \
    "$UNITS/omarchy-install-provisioning.service"
for env in '/usr/share/omarchy-iso/orchestrator/context.env' \
           '-/run/omarchy-install/context.env' '-/run/omarchy-install/install.env'; do
  check "provisioning unit reads $env" \
    grep -qxF "EnvironmentFile=$env" "$UNITS/omarchy-install-provisioning.service"
done
check "the phase loop runs provisioning staging via its unit" \
  grep -qF "add_phase 'Staging provisioning' stage_provisioning_state_unit" "$ORCH/main.sh"

# Fifth: the Limine finalization, after provisioning staging.
check "the limine unit is part of the target" \
  grep -qxF 'PartOf=omarchy-install.target' "$UNITS/omarchy-install-limine.service"
check "it is ordered after the provisioning unit" \
  grep -qxF 'After=omarchy-install-provisioning.service' "$UNITS/omarchy-install-limine.service"
check "it runs its phase through run-phase" \
  grep -qxF 'ExecStart=/usr/share/omarchy-iso/orchestrator/run-phase finalize_limine_boot' \
    "$UNITS/omarchy-install-limine.service"
for env in '/usr/share/omarchy-iso/orchestrator/context.env' \
           '-/run/omarchy-install/context.env' '-/run/omarchy-install/install.env'; do
  check "limine unit reads $env" \
    grep -qxF "EnvironmentFile=$env" "$UNITS/omarchy-install-limine.service"
done
check "the phase loop runs the limine finalization via its unit" \
  grep -qF "add_phase 'Finalizing Limine boot' finalize_limine_boot_unit" "$ORCH/main.sh"

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
printf 'the install target and its phase units are wired\n'
