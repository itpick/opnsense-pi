#!/bin/sh
# Add the bundled drivers to a built image.
#
#   scripts/customize.sh pi4|pi5 out/opnsense-<board>.img   (FreeBSD 15.1 aarch64, as root)
#
# Runs between scripts/build-image.sh (Linux: firmware into the ESP) and
# scripts/compress.sh. It needs FreeBSD to write the image's UFS root, and
# aarch64 to run the image's own pkg in a chroot. CI runs it in a FreeBSD VM.
#
#   both boards  PLUGINS installed with the image's pkg and package repo; the
#                loader.conf chunks they add (rc.loader.d) are appended to
#                /boot/loader.conf, so their kernel modules (if_re) load on the
#                first boot
#   pi5          RPI5_KMODS_BUILD built and installed (scripts/build-kmods.sh);
#                the boot hook loads RPI5_KMODS_LOAD on a Raspberry Pi 5
#   both boards  the boot hook (overlay/): config.xml seeding from the ESP,
#                driver loading, reboot-after-minutes
#
# Also writes out/opnsense-<board>.manifest.txt and out/opnsense-<board>.config.xml
# (the image's default config, a starting point for seeding).
set -eu
cd "$(dirname "$0")/.."
. ./versions.env
board=${1:-} img=${2:-}
case "$board" in pi4|pi5) ;; *) echo "usage: $0 pi4|pi5 IMAGE" >&2; exit 2 ;; esac
[ -f "$img" ] || { echo "no image $img" >&2; exit 1; }
[ "$(uname -s)/$(uname -m)" = FreeBSD/arm64 ] || { echo "needs FreeBSD on aarch64" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }

md='' root='' esp_mnt=''
cleanup() {
	set +e
	[ -n "$root" ] && { umount "$root/dev" 2>/dev/null; umount "$root"; rmdir "$root"; }
	[ -n "$esp_mnt" ] && { umount "$esp_mnt" 2>/dev/null; rmdir "$esp_mnt"; }
	[ -n "$md" ] && mdconfig -d -u "$md"
}
trap cleanup EXIT

md=$(mdconfig -a -t vnode -f "$img")
part() { gpart show -p "$md" | awk -v t="$1" '$4 == t { print "/dev/" $3; exit }'; }
ufs=$(part freebsd-ufs) esp=$(part efi)
[ -n "$ufs" ] && [ -n "$esp" ] || { gpart show -p "$md"; echo "expected an efi and a freebsd-ufs partition" >&2; exit 1; }
fsck_ffs -p "$ufs" >/dev/null
root=$(mktemp -d /tmp/opnsense-pi-root.XXXXXX)
mount "$ufs" "$root"

# The image must be what this script was written for.
kernel=$(strings "$root/boot/kernel/kernel" | grep -m1 '^@(#)FreeBSD' | sed 's/^@(#)//')
version=$(chroot "$root" /usr/local/sbin/opnsense-version)
echo ">> $board image: $version, kernel $kernel"
# e.g. "FreeBSD 15.1-RELEASE-p1 stable/26.7-n283674-12334a596709 SMP": the
# kernel config's ident is last, the source commit before it.
case "$kernel" in *" SMP") ;; *) echo "kernel was not built from the SMP config the modules are built for" >&2; exit 1 ;; esac
KERNEL_SRC_COMMIT=$(echo "$kernel" | sed -nE 's/.*-n[0-9]+-([0-9a-f]+) .*/\1/p')
[ -n "$KERNEL_SRC_COMMIT" ] || { echo "cannot find the source commit in the kernel version" >&2; exit 1; }
export KERNEL_SRC_COMMIT
grep -q 'rc.syshook import' "$root/etc/rc" || { echo "/etc/rc has no import syshook; the boot hook would never run" >&2; exit 1; }

# Plugins, with the image's own pkg (a newer host pkg could upgrade its database).
# The chroot gets the build host's DNS; the image's own resolv.conf (file,
# symlink or none) is put back afterwards.
mount -t devfs devfs "$root/dev"
had_resolv=
if [ -e "$root/etc/resolv.conf" ] || [ -L "$root/etc/resolv.conf" ]; then
	mv "$root/etc/resolv.conf" "$root/etc/resolv.conf.opnsense-pi"; had_resolv=1
fi
cp /etc/resolv.conf "$root/etc/resolv.conf"
ls "$root/usr/local/etc/rc.loader.d" 2>/dev/null | sort > /tmp/opnsense-pi-loader.before || :
for p in $PLUGINS; do
	echo ">> installing $p"
	chroot "$root" env ASSUME_ALWAYS_YES=yes pkg install -y "$p"
done
chroot "$root" pkg clean -ay -q
rm -f "$root/etc/resolv.conf"
[ -n "$had_resolv" ] && mv "$root/etc/resolv.conf.opnsense-pi" "$root/etc/resolv.conf"
umount "$root/dev"
# OPNsense assembles /boot/loader.conf from rc.loader.d on its own later; until
# then, append the new chunks to the image's loader.conf (running rc.loader here
# would drop lines the image build wrote directly, such as console="efi").
ls "$root/usr/local/etc/rc.loader.d" 2>/dev/null | sort | comm -13 /tmp/opnsense-pi-loader.before - |
while read -r chunk; do
	echo ">> loader.conf: adding $chunk"
	{ echo; echo "# opnsense-pi: from /usr/local/etc/rc.loader.d/$chunk"; cat "$root/usr/local/etc/rc.loader.d/$chunk"; } >> "$root/boot/loader.conf"
done
rm -f /tmp/opnsense-pi-loader.before

# Pi 5 kernel modules.
mkdir -p "$root/usr/local/etc/opnsense-pi"
if [ "$board" = pi5 ]; then
	sh scripts/build-kmods.sh "$root"
	cat > "$root/usr/local/etc/opnsense-pi/board.conf" <<EOF
# Written by opnsense-pi scripts/customize.sh; read by the boot hook
# /usr/local/etc/rc.syshook.d/import/10-opnsense-pi
BOARD=pi5
BOARD_MATCH="Raspberry Pi 5"
KMODS_LOAD="$RPI5_KMODS_LOAD"
EOF
else
	echo "BOARD=$board" > "$root/usr/local/etc/opnsense-pi/board.conf"
fi

# Boot hook and the rest of the overlay.
(cd overlay && find . -type f) | while read -r f; do
	mkdir -p "$(dirname "$root/$f")"
	install -m "$(stat -f %Lp "overlay/$f")" "overlay/$f" "$root/$f"
done

manifest=$root/usr/local/etc/opnsense-pi/manifest.txt
{
	echo "opnsense-pi $board image"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) from $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
	echo "opnsense: $version"
	echo "kernel: $kernel"
	echo "plugins:"
	chroot "$root" pkg query '  %n %v' | grep -E "$(echo "$PLUGINS" | tr ' ' '|')|realtek" || true
	if [ "$board" = pi5 ]; then
		echo "rpi5 modules: $RPI5_KMODS_REPO @ $RPI5_KMODS_REV"
		echo "  built against $OPNSENSE_SRC_REPO $OPNSENSE_SRC_REF, $OPNSENSE_KERNCONF"
		for k in $RPI5_KMODS_BUILD; do echo "  /boot/modules/$k.ko"; done
		echo "  loaded at boot on a Pi 5: $RPI5_KMODS_LOAD"
	fi
	echo "loader.conf:"
	sed 's/^/  /' "$root/boot/loader.conf"
} > "$manifest"
cp "$manifest" "out/opnsense-$board.manifest.txt"
cp "$root/conf/config.xml" "out/opnsense-$board.config.xml"

# ESP: a README and the default config next to where a seed goes.
esp_mnt=$(mktemp -d /tmp/opnsense-pi-esp.XXXXXX)
mount_msdosfs "$esp" "$esp_mnt"
mkdir -p "$esp_mnt/opnsense-pi"
cp "$root/conf/config.xml" "$esp_mnt/opnsense-pi/config.xml.default"
cat > "$esp_mnt/opnsense-pi/README.txt" <<'EOF'
opnsense-pi first-boot settings (read at every boot, before anything starts)

config.xml            Put an OPNsense config.xml here (for example an edited
                      copy of config.xml.default, or a backup from another
                      OPNsense) and it is installed on the next boot, once.
                      It is then renamed to config.xml.applied.
drivers               "auto" (default): load this board's extra drivers only on
                      the board. "force" or "off" to override.
reboot-after-minutes  A number of minutes: reboot that long after every boot.
                      A safety net for remote installs. Delete it to stop.

The boot hook logs to /var/log/opnsense-pi.log.
EOF
umount "$esp_mnt"; rmdir "$esp_mnt"; esp_mnt=

umount "$root"; rmdir "$root"; root=
fsck_ffs -p "$ufs" >/dev/null
echo ">> customized $img"
cat "out/opnsense-$board.manifest.txt"
