#!/usr/bin/env bash
# OPNsense aarch64 test VM on QEMU "virt", shaped like a Raspberry Pi.
# Shape only: under TCG on an x86 host, CPU speed is not comparable, and the
# NICs are virtio rather than the Pi's genet / RP1 / USB.
#
#   vm/run.sh [--pi5|--pi4] [--headless] [--reset] [--image FILE]
#     --pi5         Pi 5 16GB: 4x Cortex-A76, 16 GiB (default)
#     --pi4         Pi 4 8GB:  4x Cortex-A72, 8 GiB. A real BCM2711 lacks the
#                   ARMv8 crypto extensions; QEMU's cortex-a72 still exposes AES/SHA.
#     --headless    run in the background; console on .work/vm/<profile>/console.sock
#     --reset       discard the profile's overlay and start from the base image
#     --image FILE  base image (qcow2 or raw); default is the serial-console VM
#                   image from versions.env. Use out/*.img to boot a built Pi image.
#
# Each profile has its own overlay disk and ports, so both can run at once.
# NICs (virtio): vtnet0 = LAN, isolated 192.168.1.0/24, OPNsense at 192.168.1.1
#                vtnet1 = WAN, QEMU user-mode NAT (DHCP 10.0.2.15, gw 10.0.2.2)
# Host forwards (pi5 / pi4):
#   web GUI  https://127.0.0.1:8443 / :8444
#   ssh      ssh -p 2222 / -p 2223 root@127.0.0.1 (once SSH is enabled)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$root/versions.env"

profile=pi5 headless=0 reset=0 base=""
while (( $# )); do
  case "$1" in
    --pi5) profile=pi5 ;;
    --pi4) profile=pi4 ;;
    --reset) reset=1 ;;
    --headless) headless=1 ;;
    --image) base=$(realpath "$2"); shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$profile" in
  pi5) cpu=cortex-a76 mem=16384 gui=8443 ssh=2222 mac=01 ;;
  pi4) cpu=cortex-a72 mem=8192 gui=8444 ssh=2223 mac=02 ;;
esac

if [[ -z "$base" ]]; then
  bz2="$root/.work/cache/${OPNSENSE_SERIAL_URL##*/}"
  base="${bz2%.bz2}"
  if [[ ! -f "$base" ]]; then
    mkdir -p "$root/.work/cache"
    [[ -f "$bz2" ]] || curl -fSL --retry 3 -o "$bz2" "$OPNSENSE_SERIAL_URL"
    echo "$OPNSENSE_SERIAL_SHA256  $bz2" | sha256sum -c --quiet -
    bunzip2 -kc "$bz2" >"$base.part" && mv "$base.part" "$base"
  fi
fi
fmt=$(qemu-img info --output=json "$base" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')

QEMU_SHARE="$(dirname "$(dirname "$(readlink -f "$(command -v qemu-system-aarch64)")")")/share/qemu"
fw="$QEMU_SHARE/edk2-aarch64-code.fd"
[[ -f "$fw" ]] || fw=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd   # Debian/Ubuntu qemu-efi-aarch64

dir="$root/.work/vm/$profile"
mkdir -p "$dir"
cd "$dir"
if [[ -f qemu.pid ]] && kill -0 "$(cat qemu.pid)" 2>/dev/null; then
  echo "$profile VM already running (pid $(cat qemu.pid)); stop it first: kill \$(cat $dir/qemu.pid)" >&2
  exit 1
fi
DISK=opnsense.qcow2
# A new base image means a new overlay.
if [[ -f "$DISK" ]] && [[ "$(cat base 2>/dev/null)" != "$base" ]]; then reset=1; fi
(( reset )) && rm -f "$DISK"
if [[ ! -f "$DISK" ]]; then
  qemu-img create -q -f qcow2 -b "$base" -F "$fmt" "$DISK" 32G
  echo "$base" >base
fi

# shellcheck disable=SC2054 # commas are QEMU option syntax
args=(
  -name "opnsense-$profile"
  -machine virt -cpu "$cpu" -smp 4 -m "$mem"
  -accel tcg,thread=multi,tb-size=512
  -bios "$fw"
  -drive if=virtio,file="$DISK",cache=writeback,discard=unmap
  # LAN: restrict=on keeps the LAN segment from reaching the outside via slirp
  -netdev "user,id=lan,net=192.168.1.0/24,host=192.168.1.2,dhcpstart=192.168.1.200,restrict=on,hostfwd=tcp:127.0.0.1:$gui-192.168.1.1:443,hostfwd=tcp:127.0.0.1:$ssh-192.168.1.1:22"
  -device "virtio-net-pci,netdev=lan,mac=52:54:00:4c:41:$mac"
  -netdev user,id=wan
  -device "virtio-net-pci,netdev=wan,mac=52:54:00:57:41:$mac"
  -device virtio-rng-pci
  -display none
)

if (( headless )); then
  rm -f console.sock monitor.sock
  # console.log keeps the whole serial transcript for debugging.
  exec qemu-system-aarch64 "${args[@]}" \
    -chardev socket,id=ser0,path=console.sock,server=on,wait=off,logfile=console.log \
    -serial chardev:ser0 \
    -monitor unix:monitor.sock,server=on,wait=off \
    -daemonize -pidfile qemu.pid
else
  exec qemu-system-aarch64 "${args[@]}" -serial mon:stdio
fi
