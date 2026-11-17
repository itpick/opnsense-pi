#!/usr/bin/env bash
# shellcheck disable=SC2015 # a || exit after a && chain
# Boot-time benchmark of a built image in the QEMU VM of vm/run.sh, timed from
# the serial console (vm/console-stamp.py stamps every line with the host
# clock) and over SSH.
#
#   vm/boot-bench.sh seed [pi5|pi4]           a fresh VM from out/opnsense-<board>.img
#                                             with the test seed (hostname, SSH key,
#                                             as vm/test.sh image), booted once
#   vm/boot-bench.sh run LABEL [RUNS] [pi5|pi4]
#                                             RUNS (default 5) cold starts of QEMU;
#                                             each boots, reboots from inside
#                                             (timing the shutdown) and boots again
#
# Env: BENCH_GUEST_PREP  a sh script run as root in the guest before run 1 is
#                        measured; the guest then reboots once (to try a change)
#
# Prints one line per boot and appends it to <vmdir>/bench.tsv:
#   label run boot loader_s menu_s kernel_lan_s kernel_ssh_s kernel_gui_s kernel_ready_s shutdown_s
# loader_s = loader banner to the kernel's first line (menu countdown and
# loading kernel + modules); menu_s = the countdown alone (autoboot_delay; the
# loader's clock has 1 s steps, so N waits N-1 to N s); kernel_* = from the
# kernel's first line to "Configuring LAN interface", "Configuring OpenSSH",
# "Starting web GUI" and the last start script (">>> Invoking start script
# 'beep'"); shutdown_s = "shutdown -r now"
# to the kernel's last line ("Uptime: ..."), for the second boot of each run.
#
# TCG on an x86 host: the times are not a Pi's. Compare variants run the same
# way on the same host, one at a time.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cmd=${1:-}
case "$cmd" in
  seed) profile=${2:-pi5} ;;
  run) label=${2:-} runs=${3:-5} profile=${4:-pi5} ;;
  *) sed -n '2,27p' "$0"; exit 2 ;;
esac
case "$profile" in pi5) ssh=2222 mac=01 ;; pi4) ssh=2223 mac=02 ;; *) echo "bad profile" >&2; exit 2 ;; esac
dir="$root/.work/vm/$profile"
mkdir -p "$dir"

vssh() {
  ssh -q -i "$dir/id_test" -p "$ssh" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@127.0.0.1 /bin/sh -s <<<"$1"
}
stamp_pid=
stop_vm() {
  [[ -f "$dir/qemu.pid" ]] && kill "$(cat "$dir/qemu.pid")" 2>/dev/null || true
  for _ in $(seq 60); do [[ -f "$dir/qemu.pid" ]] && kill -0 "$(cat "$dir/qemu.pid")" 2>/dev/null || break; sleep 1; done
  [[ -n $stamp_pid ]] && wait "$stamp_pid" 2>/dev/null || true
  stamp_pid=
}
start_vm() {  # args for vm/run.sh; console transcript to $dir/stamp.log
  : >"$dir/stamp.log"
  "$root/vm/run.sh" "--$profile" --headless "$@" >/dev/null
  python3 -I "$root/vm/console-stamp.py" "$dir/console.sock" "$dir/stamp.log" &
  stamp_pid=$!
}
# Wait until boot N has finished: rc's last start script ("beep", the
# milestone the live boards' logs are read by too). The Pi images' console is
# "efi", so the serial line never shows a login prompt.
READY="Invoking start script 'beep'"
wait_login() {
  for _ in $(seq 1800); do
    (( $(grep -cF "$READY" "$dir/stamp.log" || true) >= $1 )) && return 0
    sleep 1
  done
  return 1
}
wait_ssh() { for _ in $(seq 120); do vssh true 2>/dev/null && return 0; sleep 2; done; return 1; }

# Milestones of boot N (1-based) in the transcript.
metrics() {
  python3 - "$dir/stamp.log" "$1" "${2:-}" <<'EOF'
import re, sys
log, n, shut_t = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lines = [(float(l.split(' ', 1)[0]), l.split(' ', 1)[1].rstrip('\n')) for l in open(log, errors='replace') if ' ' in l]
# boots start at the loader banner
starts = [i for i, (_, t) in enumerate(lines) if re.search(r'FreeBSD/\w+ EFI loader', t)]
i0 = starts[n - 1]
i1 = starts[n] if len(starts) > n else len(lines)
seg = lines[i0:i1]
def first(rx, after=0.0):
    for t, s in seg:
        if t >= after and re.search(rx, s):
            return t
    return None
def f(x):
    return f'{x:.1f}' if x is not None else '-'
loader = seg[0][0]
# the menu's countdown: from the menu (its logo line, which carries the first
# "Autoboot in N") to "Autoboot in 0"
menu = first(r':::::::::::|Autoboot in [1-9]')
go = first(r'Autoboot in 0 seconds')
kernel = first(r'---<<BOOT>>---|Copyright \(c\) 1992')
def rel(rx):
    t = first(rx, kernel or 0)
    return t - kernel if t and kernel else None
shutdown = None
if shut_t:
    up = [t for t, s in lines[:i0] if t >= float(shut_t) and s.startswith('Uptime: ')]
    shutdown = up[0] - float(shut_t) if up else None
print('\t'.join([f(kernel - loader if kernel else None), f(go - menu if go and menu else None),
                 f(rel(r'Configuring LAN interface')), f(rel(r'Configuring OpenSSH')),
                 f(rel(r'Starting web GUI')), f(rel(r"Invoking start script 'beep'")), f(shutdown)]))
EOF
}
record() {  # run boot [shutdown start epoch]
  local line
  line=$(printf '%s\t%s\t%s\t%s' "$label" "$1" "$2" "$(metrics "$2" "${3:-}")")
  echo "$line" | tee -a "$dir/bench.tsv"
  cp "$dir/stamp.log" "$dir/stamp-$label-$1.log"
}

case "$cmd" in
  seed)
    stop_vm
    [[ -f "$dir/id_test" ]] || ssh-keygen -q -t ed25519 -N '' -f "$dir/id_test"
    python3 "$root/scripts/seed-config.py" "$root/out/opnsense-$profile.config.xml" "$dir/seed.xml" \
      --hostname opnsense-pi-test --ssh-key "$dir/id_test.pub" --lan vtnet1 --wan vtnet0
    # as vm/test.sh image: the boot hook swaps the NIC names by MAC
    printf '52:54:00:4c:41:%s vtnet1\n52:54:00:57:41:%s vtnet0\n' "$mac" "$mac" >"$dir/ifnames"
    img=$dir/bench.img
    cp --sparse=always "$root/out/opnsense-$profile.img" "$img"
    off=$(sfdisk -J "$img" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"] * 512)')
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$img@@$off" "$dir/seed.xml" ::/opnsense-pi/config.xml
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$img@@$off" "$dir/ifnames" ::/opnsense-pi/ifnames
    start_vm --reset --image "$img"
    wait_login 1 || { echo "seed: no login prompt" >&2; exit 1; }
    wait_ssh || { echo "seed: no SSH" >&2; exit 1; }
    label=first-boot record 0 1
    stop_vm
    ;;
  run)
    [[ -n $label ]] || { echo "usage: $0 run LABEL [RUNS]" >&2; exit 2; }
    [[ -f "$dir/opnsense.qcow2" ]] || { echo "no VM in $dir: $0 seed first" >&2; exit 1; }
    for r in $(seq "$runs"); do
      stop_vm
      start_vm --image "$(cat "$dir/base")"
      n=1
      wait_login $n && wait_ssh || { echo "run $r: boot never finished" >&2; exit 1; }
      if [[ -n "${BENCH_GUEST_PREP:-}" && $r == 1 ]]; then
        vssh "$BENCH_GUEST_PREP"
        vssh '(sleep 1; shutdown -r now) >/dev/null 2>&1 &' || true
        n=$((n + 1))
        wait_login $n && wait_ssh || { echo "run $r: boot after prep never finished" >&2; exit 1; }
      fi
      record "$r" "$n"
      sleep 20   # let the last start scripts settle before the reboot
      t0=$(date +%s.%N)
      vssh '(shutdown -r now) >/dev/null 2>&1 &' || true
      n=$((n + 1))
      wait_login $n && wait_ssh || { echo "run $r: boot 2 never finished" >&2; exit 1; }
      record "$r" "$n" "$t0"
    done
    stop_vm
    ;;
esac
