#!/usr/bin/env bash
# Run a shell command as root on a headless test VM's serial console.
#
#   vm/sh.sh PROFILE TIMEOUT 'command'
#
# Reads the end of the serial transcript (console.log) to see where the console
# is, and only types once it sits at the login prompt, the console menu or a
# root shell. It never sends keys while the VM is booting: first boot has
# "Press any key to start the configuration importer / interface assignment"
# prompts, and a stray key there starts an interactive wizard that hangs.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
p=$1 t=$2 cmd=$3
dir="$root/.work/vm/$p"
C() { python3 -I "$root/vm/console.py" "$dir/console.sock" "$@"; }
# Last bytes of the transcript, without CRs or ANSI escapes.
tail_log() { tail -c 300 "$dir/console.log" | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

deadline=$((SECONDS + 1800))
while :; do
  (( SECONDS < deadline )) || { echo "console on $p never reached a prompt" >&2; exit 1; }
  case "$(tail_log)" in
    *"login: ") C 30 'Password:' root >/dev/null ;;
    *"Password:") C 60 'Enter an option: $' opnsense >/dev/null ;;
    *"Enter an option: ") C 30 '# $' 8 >/dev/null ;;
    *"# ") break ;;
    *) sleep 5 ;;
  esac
done
# The marker is split in the command so the echoed input line cannot match it.
C "$t" '__END__\r?\n.*# ' "$cmd; echo __EN''D__" | tr -d '\r' | sed -n '1d; /^__END__$/q; p'
