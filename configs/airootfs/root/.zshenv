# The autologin shell on tty1 exists to run the installer from ~/.zlogin, not
# to be used, so the global rc files are skipped there. /etc/zsh/zshrc is
# grml's: 120 KB that compiles completions and probes the system before a
# prompt nobody sees, which on the usb2 boot benchmark (40 MB/s, with the
# verify units sharing the stick fairly) stood between the login and the
# installer for 0.9 s. /etc/profile is sourced as /etc/zsh/zprofile would
# have, so the installer's environment is unchanged. Every other console
# keeps the full interactive setup.
#
# Nor does it report on the installer's job when a reboot hangs the console up
# ("/root/.zlogin:6: warning: 1 jobs SIGHUPed", "zsh: hangup"): NO_HUP and
# NO_CHECK_JOBS, and .automated_script.sh leaves quietly on the hangup.
if [[ -o login && $TTY == /dev/tty1 ]]; then
  unsetopt GLOBAL_RCS
  setopt NO_HUP NO_CHECK_JOBS
  emulate sh -c 'source /etc/profile'
fi
