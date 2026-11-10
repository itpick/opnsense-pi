#!/bin/sh
# Build the Raspberry Pi 5 kernel modules for the image's kernel.
#
#   scripts/build-kmods.sh ROOT     (FreeBSD 15.1 aarch64, as root)
#
# ROOT is the mounted image. Compiles RPI5_KMODS_BUILD from RPI5_KMODS_REPO
# against OPNsense's kernel sources (OPNSENSE_SRC_REF) with the image's kernel
# config (OPNSENSE_KERNCONF), checks every undefined symbol resolves against
# the image's kernel, and installs them into ROOT/boot/modules.
#
# The module Makefile reads headers from /usr/src/sys, so the OPNsense sources
# are checked out there. That only happens if /usr/src is absent (as on a CI
# VM) or is a checkout this script made; it never replaces another tree.
set -eu
cd "$(dirname "$0")/.."
. ./versions.env
root=$1
work=$(pwd)/.work/kmods
src=/usr/src
mkdir -p "$work"

# 1. OPNsense kernel sources (sys/ only) at the image's version.
if [ "$(cat $src/.opnsense-pi 2>/dev/null)" != "$OPNSENSE_SRC_REF" ]; then
	if [ -e $src ] && [ ! -f $src/.opnsense-pi ]; then
		echo "$src exists and is not an opnsense-pi checkout; refusing to replace it" >&2
		exit 1
	fi
	rm -rf $src
	echo ">> fetching $OPNSENSE_SRC_REPO $OPNSENSE_SRC_REF (sys/)"
	git clone -q --depth 1 --filter=blob:none --sparse -b "$OPNSENSE_SRC_REF" "$OPNSENSE_SRC_REPO" $src
	git -C $src sparse-checkout set sys
	echo "$OPNSENSE_SRC_REF" > $src/.opnsense-pi
fi

# 2. Kernel option headers for the image's kernel config. SMP-ARM lives in
#    opnsense/tools; %%DEBUG%% is filled from kernel.default as the build does.
kb=$work/kernel-$OPNSENSE_KERNCONF
rm -rf "$kb"
conf=$src/sys/arm64/conf/$OPNSENSE_KERNCONF
tools=https://raw.githubusercontent.com/opnsense/tools/$OPNSENSE_TOOLS_REF/config/$OPNSENSE_SRC_REF
fetch -q -o "$work/kernel.default" "$tools/kernel.default"
fetch -q -o "$work/$OPNSENSE_KERNCONF.in" "$tools/$OPNSENSE_KERNCONF"
awk -v dbg="$work/kernel.default" '
	/%%DEBUG%%/ { while ((getline l < dbg) > 0) print l; next } { print }' \
	"$work/$OPNSENSE_KERNCONF.in" > "$conf"
(cd $src/sys/arm64/conf && config -d "$kb" "$OPNSENSE_KERNCONF")
make -s -C "$kb" vnode_if.h vnode_if_newproto.h vnode_if_typedef.h

# 3. The modules, pinned. Their checked-in opt_*.h are hand-written stand-ins;
#    remove them so bsd.kmod.mk uses the kernel config's (KERNBUILDDIR).
m=$work/rpi5-modules
rm -rf "$m"
git clone -q "$RPI5_KMODS_REPO" "$m"
git -C "$m" checkout -q "$RPI5_KMODS_REV"
rm -f "$m"/opt_*.h
for k in $RPI5_KMODS_BUILD; do
	echo ">> building $k"
	make -s -C "$m" MODULE="$k" SYSDIR=$src/sys KERNBUILDDIR="$kb" DEBUG_FLAGS= WITHOUT_DEBUG_FILES=yes
	[ -f "$m/$k.ko" ] || { echo "no $k.ko produced" >&2; exit 1; }
done

# 4. Every undefined symbol must come from the image's kernel or another of
#    these modules; otherwise kldload would fail on the Pi.
nm -g --defined-only "$root/boot/kernel/kernel" | awk '{ print $NF }' > "$work/defined"
for k in $RPI5_KMODS_BUILD; do nm -g --defined-only "$m/$k.ko" | awk '{ print $NF }'; done >> "$work/defined"
sort -u -o "$work/defined" "$work/defined"
bad=0
for k in $RPI5_KMODS_BUILD; do
	nm -u "$m/$k.ko" | awk '{ print $NF }' | sort -u > "$work/undef-$k"
	missing=$(comm -23 "$work/undef-$k" "$work/defined")
	if [ -n "$missing" ]; then
		echo "$k.ko: symbols the image's kernel does not provide:" >&2
		echo "$missing" | sed 's/^/   /' >&2
		bad=1
	fi
done
[ $bad = 0 ] || exit 1

mkdir -p "$root/boot/modules"
for k in $RPI5_KMODS_BUILD; do
	install -m 555 "$m/$k.ko" "$root/boot/modules/$k.ko"
	echo ">> installed /boot/modules/$k.ko ($(stat -f %z "$m/$k.ko") bytes)"
done
kldxref "$root/boot/modules"
