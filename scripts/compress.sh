#!/usr/bin/env bash
# Compress a built image for release.
#
#   scripts/compress.sh pi4|pi5
#
# out/opnsense-<board>.img -> out/opnsense-<board>.img.xz + .sha256
set -euo pipefail
cd "$(dirname "$0")/.."
board=${1:-}
case "$board" in pi4|pi5) ;; *) echo "usage: $0 pi4|pi5" >&2; exit 2 ;; esac
img=out/opnsense-$board.img
[[ -f "$img" ]] || { echo "missing $img (make image BOARD=$board)" >&2; exit 1; }
echo ">> compressing $img"
xz -T0 -6 -c "$img" >"$img.xz"
(cd out && sha256sum "opnsense-$board.img.xz" >"opnsense-$board.img.xz.sha256")
echo ">> $img.xz ($(du -h "$img.xz" | cut -f1))"
