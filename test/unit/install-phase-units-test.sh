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

check "run-phase is executable in the ISO" \
  grep -qF '["/usr/share/omarchy-iso/orchestrator/run-phase"]="0:0:755"' "$ROOT/configs/profiledef.sh"
# The sourced-main check needs the library reachable the way run-phase finds
# it; point it at the vendored tree the way the harness does.
check "sourcing main.sh defines but does not run the install" \
  env OMARCHY_ARCHINSTALL_LIB="$ROOT/archinstall-bash/lib" bash -c \
    "source '$ORCH/main.sh' && declare -F main >/dev/null && declare -F install_root_image >/dev/null"
check "run-phase refuses an unknown phase" \
  bash -c "! env OMARCHY_ARCHINSTALL_LIB='$ROOT/archinstall-bash/lib' '$ORCH/run-phase' no_such_phase 2>/dev/null"

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'the install target and its first phase unit are wired\n'
