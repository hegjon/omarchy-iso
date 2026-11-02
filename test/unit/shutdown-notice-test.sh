#!/bin/bash
# shellcheck disable=SC2015 # ok/fail lines
#
# omarchy-shutdown-notice (getty@tty1's ExecStopPost): on a shutdown it writes
# "Rebooting..." or "Powering off..." on tty1, in the greeter's tagline row
# while the greeter is up and alone on a cleared screen otherwise, and leaves
# the cursor off that row; when getty stops for anything else it writes
# nothing. Runs it against a file in place of tty1, with systemctl and stty
# stubbed.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
NOTICE="$ROOT/configs/airootfs/usr/local/bin/omarchy-shutdown-notice"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

mkdir -p "$work/bin" "$work/run"
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
case $1 in
  is-system-running) cat "$STATE" ;;
  list-jobs) cat "$JOBS" ;;
esac
STUB
printf '#!/bin/bash\necho "50 160"\n' >"$work/bin/stty"
chmod +x "$work/bin/"*

notice() { # STATE JOBS -> what the notice wrote on "tty1"
  echo "$1" >"$work/state"; echo "$2" >"$work/jobs"; : >"$work/tty1"
  PATH="$work/bin:$PATH" STATE="$work/state" JOBS="$work/jobs" OMARCHY_NOTICE_TTY="$work/tty1" \
    OMARCHY_RUN_DIR="$work/run" bash "$NOTICE" || fail "the notice exited non-zero"
  cat -v "$work/tty1"
}

echo "30 32" >"$work/run/greeter-rows"
out=$(notice running "")
[[ -z $out ]] && ok "getty stopping outside a shutdown: nothing written" || fail "wrote outside a shutdown: $out"
out=$(notice stopping "1 reboot.target start waiting")
[[ $out == *'[30;1H^[[2K^[[32;1H^[[2K^[[30;75HRebooting...^[[32;1H' ]] &&
  ok "a reboot at the greeter: Rebooting... in the tagline's row, centred, the cursor on the hint's row" ||
  fail "reboot at the greeter: $out"
out=$(notice stopping "2 poweroff.target start waiting")
[[ $out == *'Powering off...'* ]] && ok "a poweroff: Powering off..." || fail "poweroff: $out"
rm "$work/run/greeter-rows"
out=$(notice stopping "1 reboot.target start waiting")
[[ $out == *'^[[H^[[2J^[[25;75HRebooting...^[[27;1H' ]] &&
  ok "no greeter up: the screen cleared, the notice centred, the cursor two rows under it" ||
  fail "no greeter: $out"

exit "$((failures > 0))"
