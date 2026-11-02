#!/usr/bin/env bash
# End-to-end VM tests.
#
#   vm/test.sh plugin [pi5|pi4]   fresh serial-console VM: boot, check versions,
#                                 install os-realtek-re, reboot, check if_re.ko
#                                 loads at boot, check the web GUI answers
#   vm/test.sh image  [pi5|pi4]   boot a built out/opnsense-<board>.img and check
#                                 the web GUI answers (the Pi firmware in the ESP
#                                 is ignored by QEMU's UEFI; this proves the
#                                 OPNsense side of the image still boots)
#
# Each test starts from a clean overlay and stops its VM at the end.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test=${1:-} profile=${2:-pi5}
case "$profile" in pi5) gui=8443 ;; pi4) gui=8444 ;; *) echo "bad profile: $profile" >&2; exit 2 ;; esac
dir="$root/.work/vm/$profile"

stop() { [[ -f "$dir/qemu.pid" ]] && kill "$(cat "$dir/qemu.pid")" 2>/dev/null || true; }
vmsh() { "$root/vm/sh.sh" "$profile" "$@"; }
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; stop; exit 1; }

wait_gui() {
  for _ in $(seq 360); do
    [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://127.0.0.1:$gui/" || true)" == 200 ]] && return 0
    sleep 5
  done
  return 1
}

reboot_vm() {
  python3 -I "$root/vm/console.py" "$dir/console.sock" 5 '^$' 'shutdown -r now' >/dev/null || true
  sleep 20
}

stop
case "$test" in
  plugin)
    "$root/vm/run.sh" "--$profile" --headless --reset
    out=$(vmsh 60 'freebsd-version -k; opnsense-version; sysctl -n hw.model')
    echo "$out"
    grep -q 'OPNsense' <<<"$out" || fail "not OPNsense"
    ok "booted"
    out=$(vmsh 900 'pkg update -f >/dev/null; pkg install -y os-realtek-re >/dev/null; pkg info -E os-realtek-re realtek-re-kmod')
    echo "$out"
    grep -q realtek-re-kmod <<<"$out" || fail "plugin install"
    ok "os-realtek-re installed"
    reboot_vm
    vmsh 60 'kldstat -n if_re.ko' | grep -q if_re || fail "if_re.ko not loaded after reboot"
    ok "if_re.ko loaded at boot"
    wait_gui || fail "web GUI"
    ok "web GUI https://127.0.0.1:$gui"
    ;;
  image)
    board=$profile
    img="$root/out/opnsense-$board.img"
    if [[ ! -f "$img" ]]; then
      [[ -f "$img.xz" ]] || fail "missing out/opnsense-$board.img.xz (make image BOARD=$board)"
      xz -dkc "$img.xz" >"$img"
    fi
    "$root/vm/run.sh" "--$profile" --headless --reset --image "$img"
    wait_gui || fail "web GUI never answered"
    ok "built $board image boots to the web GUI"
    ;;
  *) echo "usage: $0 plugin|image [pi5|pi4]" >&2; exit 2 ;;
esac
stop
