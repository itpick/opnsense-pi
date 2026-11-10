#!/usr/bin/env bash
# Build a flashable OPNsense image for a Raspberry Pi.
#
#   scripts/build-image.sh pi4|pi5
#
# Takes the community OPNsense aarch64 EFI image, converts it to a raw disk and
# copies the board's UEFI firmware into its FAT32 EFI system partition, which
# the Pi's EEPROM bootloader reads (config.txt -> armstub=RPI_EFI.fd). UEFI then
# boots FreeBSD's loader from the same partition. One image, one disk.
#
# Output: out/opnsense-<board>.img (raw). Then, for a release image:
#   scripts/customize.sh  (FreeBSD) adds the bundled drivers and boot hook
#   scripts/compress.sh   writes out/opnsense-<board>.img.xz and its .sha256
# Needs: curl, sha256sum, bunzip2, qemu-img, sfdisk, unzip, mtools
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
source versions.env

board=${1:-}
case "$board" in
  pi4) fw_url=$RPI4_FW_URL fw_sha=$RPI4_FW_SHA256 ;;
  pi5) fw_url=$RPI5_FW_URL fw_sha=$RPI5_FW_SHA256 ;;
  *) echo "usage: $0 pi4|pi5" >&2; exit 2 ;;
esac

for tool in curl sha256sum bunzip2 qemu-img sfdisk unzip mcopy; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

cache=.work/cache
mkdir -p "$cache" out
work=$(mktemp -d .work/build-XXXXXX)
trap 'rm -rf "$work"' EXIT

# fetch URL SHA256 -> prints the cached path, verified
fetch() {
  local url=$1 sha=$2 dest="$cache/${1##*/}"
  if [[ ! -f "$dest" ]]; then
    echo ">> downloading ${url##*/}" >&2
    curl -fSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  echo "$sha  $dest" | sha256sum -c --quiet - >&2 || {
    echo "sha256 mismatch for $dest (delete it to re-download)" >&2; exit 1; }
  echo "$dest"
}

src=$(fetch "$OPNSENSE_EFI_URL" "$OPNSENSE_EFI_SHA256")
fw=$(fetch "$fw_url" "$fw_sha")

qcow=$cache/$(basename "$src" .bz2)
if [[ ! -f "$qcow" ]]; then
  echo ">> decompressing $(basename "$src")"
  bunzip2 -kc "$src" >"$qcow.part" && mv "$qcow.part" "$qcow"
fi

img=$work/opnsense-$board.img
echo ">> converting to raw"
qemu-img convert -O raw "$qcow" "$img"

# The Pi bootloader reads the first FAT partition; in these images that is the ESP.
esp_start=$(sfdisk -J "$img" | python3 -c '
import json, sys
parts = json.load(sys.stdin)["partitiontable"]["partitions"]
esp = parts[0]
assert esp["type"].upper() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "partition 1 is not an ESP"
print(esp["start"])')
esp="$img@@$((esp_start * 512))"

echo ">> adding $board UEFI firmware ($(basename "$fw")) to the ESP"
unzip -q "$fw" -d "$work/fw"
export MTOOLS_SKIP_CHECK=1
mcopy -s -o -i "$esp" "$work/fw"/* ::/
mdir -/ -b -i "$esp" :: | sed 's/^/   /'

mv "$img" "out/opnsense-$board.img"
echo ">> out/opnsense-$board.img"
