#!/usr/bin/env bash
# End-to-end VM tests.
#
#   vm/test.sh plugin [pi5|pi4]   fresh serial-console VM: boot, check versions,
#                                 install os-realtek-re, reboot, check if_re.ko
#                                 loads at boot, check the web GUI answers
#   vm/test.sh image  [pi5|pi4]   boot a built out/opnsense-<board>.img and check
#                                 the web GUI answers (the Pi firmware in the ESP
#                                 is ignored by QEMU's UEFI; this proves the
#                                 OPNsense side of the image still boots).
#                                 For a customized image (scripts/customize.sh)
#                                 it also seeds a config.xml through the ESP
#                                 (hostname, SSH key) and checks over SSH: the
#                                 seed was applied, os-realtek-re is installed
#                                 and if_re.ko loaded at boot, and on pi5 the
#                                 RP1 modules are installed but, this not being
#                                 a Pi 5, not loaded
#   vm/test.sh trial  [pi5|pi4]   customized image with reboot-after-minutes=3:
#                                 check it reboots by itself
#
# Each test starts from a clean overlay and stops its VM at the end.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test=${1:-} profile=${2:-pi5}
case "$profile" in pi5) gui=8443 ssh=2222 ;; pi4) gui=8444 ssh=2223 ;; *) echo "bad profile: $profile" >&2; exit 2 ;; esac
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

# A copy of out/opnsense-<board>.img with ESP files added: test_image NAME=FILE...
test_image() {
  local src="$root/out/opnsense-$profile.img" t="$dir/test.img"
  if [[ ! -f "$src" ]]; then
    [[ -f "$src.xz" ]] || fail "missing out/opnsense-$profile.img.xz (make image BOARD=$profile)"
    xz -dkc "$src.xz" >"$src"
  fi
  mkdir -p "$dir"
  cp --sparse=always "$src" "$t"
  local off
  off=$(sfdisk -J "$t" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"] * 512)')
  for kv in "$@"; do
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$t@@$off" "${kv#*=}" "::/opnsense-pi/${kv%%=*}"
  done
  echo "$t"
}

# Seed config (hostname + SSH key) for a customized image.
seed() {
  [[ -f "$dir/id_test" ]] || ssh-keygen -q -t ed25519 -N '' -f "$dir/id_test"
  python3 "$root/scripts/seed-config.py" "$root/out/opnsense-$profile.config.xml" "$dir/seed.xml" \
    --hostname opnsense-pi-test --ssh-key "$dir/id_test.pub"
}

# Run a sh script as root over SSH (stdin, so root's login shell does not matter).
vssh() {
  ssh -q -i "$dir/id_test" -p "$ssh" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@127.0.0.1 /bin/sh -s <<<"$1"
}

wait_ssh() {
  for _ in $(seq 120); do vssh true 2>/dev/null && return 0; sleep 5; done
  return 1
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
    mkdir -p "$dir"
    customized=
    [[ -f "$root/out/opnsense-$profile.config.xml" ]] && customized=1
    if [[ -n "$customized" ]]; then
      seed
      img=$(test_image "config.xml=$dir/seed.xml")
    else
      img=$(test_image)
    fi
    "$root/vm/run.sh" "--$profile" --headless --reset --image "$img"
    wait_gui || fail "web GUI never answered"
    ok "built $profile image boots to the web GUI"
    if [[ -n "$customized" ]]; then
      wait_ssh || fail "SSH with the seeded key never worked (seed not applied?)"
      ok "SSH with the key from the seeded config.xml"
      [[ "$(vssh hostname)" == opnsense-pi-test* ]] || fail "hostname is $(vssh hostname), not the seeded one"
      ok "seeded hostname"
      vssh 'grep -q "installed config.xml" /var/log/opnsense-pi.log' || fail "boot hook did not log the seed"
      vssh 'pkg info -e os-realtek-re && kldstat -n if_re.ko >/dev/null' || fail "os-realtek-re not installed or if_re.ko not loaded"
      ok "os-realtek-re installed, if_re.ko loaded at first boot"
      if [[ $profile == pi5 ]]; then
        vssh 'for k in bcm2712 bcm2712_pcie rp1_eth rpi5; do test -f /boot/modules/$k.ko || exit 1; done' || fail "Pi 5 modules missing from /boot/modules"
        vssh 'grep -q "not loading pi5 modules" /var/log/opnsense-pi.log && ! kldstat -n rp1_eth.ko >/dev/null 2>&1' \
          || fail "boot hook should have skipped the Pi 5 modules on a VM"
        ok "Pi 5 modules installed; boot hook skipped them (not a Pi 5)"
      fi
      vssh 'cat /usr/local/etc/opnsense-pi/manifest.txt'
    fi
    ;;
  trial)
    [[ -f "$root/out/opnsense-$profile.config.xml" ]] || fail "trial needs a customized image"
    seed
    echo 3 >"$dir/reboot-after-minutes"
    img=$(test_image "config.xml=$dir/seed.xml" "reboot-after-minutes=$dir/reboot-after-minutes")
    "$root/vm/run.sh" "--$profile" --headless --reset --image "$img"
    wait_ssh || fail "SSH never worked"
    vssh 'grep -q "rebooting in 3 minutes" /var/log/opnsense-pi.log' || fail "boot hook did not schedule the reboot"
    ok "reboot scheduled"
    for _ in $(seq 120); do
      [[ "$(vssh 'grep -c "rebooting in 3 minutes" /var/log/opnsense-pi.log' 2>/dev/null || true)" -ge 2 ]] && break
      sleep 10
    done
    [[ "$(vssh 'grep -c "rebooting in 3 minutes" /var/log/opnsense-pi.log')" -ge 2 ]] || fail "it never rebooted by itself"
    ok "rebooted by itself and scheduled the next one"
    vssh 'grep -q "stage boot" /boot/efi/opnsense-pi/diag-boot.txt && grep -q "stage reboot" /boot/efi/opnsense-pi/diag-reboot.txt && grep -q "^### ifconfig -a" /boot/efi/opnsense-pi/diag-reboot.txt' \
      || fail "diagnostics snapshots missing from the ESP"
    ok "diagnostics saved to the ESP (diag-boot.txt, diag-reboot.txt)"
    ;;
  *) echo "usage: $0 plugin|image|trial [pi5|pi4]" >&2; exit 2 ;;
esac
stop
