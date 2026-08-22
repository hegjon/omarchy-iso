# shellcheck shell=bash
# Orchestrator progress lines.
#
# These land in the install log, not on a screen: omarchy-install-dashboard owns
# the visible UI, captures the orchestrator's stdout into the support log, and
# strips CSI sequences on the way in. Plain writes keep the same indented shape
# the dashboard's filters expect. bash writes are unbuffered, so lines never
# reorder against pacstrap's or arch-chroot's in the log.

info() {
  printf '\n    %s\n' "$*"
}

error() {
  printf '\n    %s\n' "$*" >&2
}

# Abort the current phase with a message (the Python orchestrator raised
# RuntimeError). The phase runner's EXIT trap records it in state.json.
ORCH_LAST_ERROR=''
fail() {
  ORCH_LAST_ERROR=$*
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# archinstall-bash's die() calls this before exiting (ARCHINSTALL_ON_DIE).
orchestrator_record_error() {
  ORCH_LAST_ERROR=$*
}

# Read a whole file into stdout, tolerating a missing one.
read_text() {
  [[ -f $1 ]] && cat "$1"
  return 0
}

# _optional_path(): a path the caller always passes but that need not exist.
# Prints it when the file is there, nothing otherwise.
optional_path() {
  [[ -n ${1:-} && -e $1 ]] && printf '%s' "$1"
  return 0
}

# Membership test for space-separated lists: list_contains "a b c" b
# (the same helper archinstall-bash defines; the phases must not depend on
# the library being loaded for it).
list_contains() {
  local needle=$2 item
  for item in $1; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}
