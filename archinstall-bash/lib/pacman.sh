# shellcheck shell=bash
# Port of lib/pacman/pacman.py (Pacman) and lib/pacman/config.py (PacmanConfig).

PACMAN_CONF=/etc/pacman.conf
PACMAN_SYNCED=0
PACMAN_OPTIONAL_REPOS=()
# Set to 1 to strap only packages the target does not already hold
# (what Omarchy's root-image install needs; pacstrap --needed still has to
# resolve every target otherwise).
INSTALLER_STRAP_ONLY_MISSING=${INSTALLER_STRAP_ONLY_MISSING:-0}

# Pacman.run(): wait for a foreign pacman to release the db lock first.
pacman_run() {
  local lock=/var/lib/pacman/db.lck started
  [[ -e $lock ]] && warn 'Pacman is already running, waiting maximum 10 minutes for it to terminate.'
  started=$SECONDS
  while [[ -e $lock ]]; do
    sleep 0.25
    if ((SECONDS - started > 600)); then
      die 'Pre-existing pacman lock never exited. Please clean up any existing pacman sessions before using archinstall.'
    fi
  done
  sys_cmd pacman "$@"
}

pacman_reinit_keyring() {
  pgrep -x gpg-agent >/dev/null 2>&1 && sys_cmd killall gpg-agent
  sys_cmd pacman-key --init && sys_cmd pacman-key --populate archlinux && debug 'Keyring reinitialized successfully' ||
    debug "Keyring reinit failed: $SYS_CMD_OUTPUT"
}

# Pacman.sync()
pacman_sync() {
  ((PACMAN_SYNCED)) && return 0
  if ! pacman_run -Syy; then
    if [[ ${SYS_CMD_OUTPUT,,} == *gpgme* || ${SYS_CMD_OUTPUT,,} == *keyring* ]]; then
      warn 'Pacman sync failed with keyring error, attempting keyring reinit'
      pacman_reinit_keyring
    fi
    pacman_run -Syy || die "Could not sync a new package database: $SYS_CMD_OUTPUT"
  fi
  PACMAN_SYNCED=1
}

# Whether pacman's local db in the target records $2 as installed.
target_has_package() {
  local target=$1 name=$2 desc
  for desc in "$target"/var/lib/pacman/local/"$name"-*/desc; do
    [[ -f $desc ]] || continue
    [[ $(sed -n '/^%NAME%$/{n;p;q}' "$desc") == "$name" ]] && return 0
  done
  return 1
}

# Pacman.strap(): pacstrap into the target.
pacman_strap() {
  local -a packages=("$@") missing=()
  ((${#packages[@]})) || return 0
  pacman_sync
  if ((INSTALLER_STRAP_ONLY_MISSING)); then
    local p
    for p in "${packages[@]}"; do
      target_has_package "$INST_TARGET" "$p" || missing+=("$p")
    done
    packages=("${missing[@]}")
    ((${#packages[@]})) || { debug 'all packages already present in target'; return 0; }
  fi
  info "Installing packages: ${packages[*]}"
  sys_cmd_peek pacstrap -C "$PACMAN_CONF" -K "$INST_TARGET" "${packages[@]}" --noconfirm --needed ||
    die 'Pacstrap failed. See /var/log/archinstall/install.log or above message for error details'
}

# PacmanConfig.enable()
pacman_config_enable() {
  PACMAN_OPTIONAL_REPOS+=("$@")
}

# PacmanConfig.apply(): uncomment optional repositories in the LIVE
# pacman.conf (pacstrap reads the host configuration).
pacman_config_apply() {
  ((${#PACMAN_OPTIONAL_REPOS[@]})) || return 0
  local -a repos=()
  local r
  for r in "${PACMAN_OPTIONAL_REPOS[@]}"; do
    case $r in
      testing) repos+=(core-testing extra-testing multilib-testing) ;;
      *) repos+=("$r") ;;
    esac
  done
  local tmp
  tmp=$(mktemp)
  awk -v repos="${repos[*]}" '
    BEGIN { n = split(repos, want, " "); for (i = 1; i <= n; i++) w[want[i]] = 1 }
    uncomment_next && /^[[:space:]]*#/ { sub(/^[[:space:]]*#[[:space:]]*/, ""); uncomment_next = 0; print; next }
    { uncomment_next = 0 }
    match($0, /^#[[:space:]]*\[([^]]+)\]/, m) && (m[1] in w) { sub(/^#[[:space:]]*/, ""); uncomment_next = 1 }
    { print }
  ' "$PACMAN_CONF" >"$tmp" && cat "$tmp" >"$PACMAN_CONF"
  rm -f "$tmp"
}

# PacmanConfig.persist(): the live pacman.conf becomes the target's.
pacman_config_persist() {
  cp -p "$PACMAN_CONF" "$INST_TARGET$PACMAN_CONF"
}

# PacmanConfig.configure(): ParallelDownloads / Color on the target.
pacman_config_configure() {
  local parallel=$1 color=$2 conf="$INST_TARGET$PACMAN_CONF"
  [[ -f $conf ]] || return 0
  local tmp
  tmp=$(mktemp)
  awk -v parallel="$parallel" -v color="$color" '
    /^#?[[:space:]]*ParallelDownloads/ { print "ParallelDownloads = " parallel; next }
    /^#?[[:space:]]*Color[[:space:]]*$/ { print (color == "true" ? "Color" : "#Color"); next }
    { print }
  ' "$conf" >"$tmp" && cat "$tmp" >"$conf"
  rm -f "$tmp"
}
