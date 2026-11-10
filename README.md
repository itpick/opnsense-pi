# opnsense-pi

Flashable [OPNsense](https://opnsense.org/) images for the Raspberry Pi 4 and 5,
plus QEMU tests that boot them on a Pi-shaped VM.

**Download page:** https://itpick.github.io/opnsense-pi/

> Unofficial. Built from the community aarch64 images
> ([maurice-w/opnsense-vm-images](https://github.com/maurice-w/opnsense-vm-images)),
> which Deciso does not support. Use it for labs and learning. Keep a working router nearby.

## Board status

| | Raspberry Pi 4 | Raspberry Pi 5 |
|---|---|---|
| UEFI firmware | [pftf/RPi4](https://github.com/pftf/RPi4) v1.53 | [NumberOneGit/rpi5-uefi](https://github.com/NumberOneGit/rpi5-uefi) v0.1 (D0 boards; SD boot only) |
| Onboard Ethernet | `genet0` works (use as LAN) | `rp1eth0` works: RP1 driver `rp1_eth` from [aphor/FreeBSD15-RPi5-modules](https://github.com/aphor/FreeBSD15-RPi5-modules) (plus [one fix](patches/rpi5-kmods/)), loaded at boot on a Pi 5. 1 Gb/s link; received frames are polled every 5 ms (~4 ms LAN latency) |
| WAN | USB 3 NIC, RTL8153 (`ure0`) or AX88179 (`axge0`) | USB 3 NIC: an RTL8156 2.5 GbE attaches as `ue0` (`ure`); traffic over it not yet tested |
| AES in hardware | No (BCM2711 has no ARMv8 crypto), so VPNs are CPU-bound | Yes (Cortex-A76) |
| Other drivers | `os-realtek-re` preinstalled (`if_re.ko`) | `os-realtek-re` preinstalled; `rpi5` fan control |
| Verdict | Works today | Experimental: tested on one Pi 5 16 GB (D0): DHCP on `rp1eth0`, SSH, web GUI, API, reboot |

OPNsense 26.7 is FreeBSD 15.1-RELEASE (`__FreeBSD_version` 1501000).

## Flash it

```sh
# Pi 4. Replace /dev/sdX with your SD card or USB SSD. This erases it.
curl -fL https://github.com/itpick/opnsense-pi/releases/latest/download/opnsense-pi4.img.xz \
  | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Or in Raspberry Pi Imager, choose **Use custom** and pick the downloaded `.img.xz`.

Each image is one disk: the Pi firmware and UEFI sit in the FAT32 EFI partition,
and OPNsense is on the UFS partition behind it. The root filesystem grows to fill
the disk on first boot.

### Bundled drivers

Release images are customized on FreeBSD after the firmware step
([`scripts/customize.sh`](scripts/customize.sh)); [`versions.env`](versions.env) pins every input:

- **Both boards:** the `os-realtek-re` plugin (Realtek's vendor `if_re.ko`, for
  Realtek PCIe NICs), installed with the image's own `pkg` and package repo and
  loaded from the first boot. Realtek USB NICs (RTL8153) use the base `ure` driver either way.
- **Pi 5:** `bcm2712`, `bcm2712_pcie`, `rp1_eth` and `rpi5` from
  aphor/FreeBSD15-RPi5-modules, compiled against OPNsense's kernel sources
  (`opnsense/src` 26.7, kernel config `SMP-ARM`), with every symbol checked
  against the image's kernel. They map Pi 5 hardware directly when loaded, so
  the boot hook loads `rp1_eth` and `rpi5` only when SMBIOS says "Raspberry Pi 5".
  `rp1_eth` finds the hardware through the device tree, so the image's UEFI is
  preset to System Table Mode **ACPI + Device Tree** ([`uefi/pi5-vars.json`](uefi/pi5-vars.json),
  written into `RPI_EFI.fd`); FreeBSD still boots on ACPI. Fixes on top of the
  pinned module commit live in [`patches/rpi5-kmods/`](patches/rpi5-kmods/).

Each image lists what it contains in `/usr/local/etc/opnsense-pi/manifest.txt`
(also published as `opnsense-<board>.manifest.txt`).

### First-boot settings

The FAT32 partition (the one that shows up when you plug the card into any
computer) has an `opnsense-pi/` folder. A boot hook reads it at every boot,
before OPNsense configures anything:

| File | Effect |
|---|---|
| `config.xml` | Installed as `/conf/config.xml` once, then renamed to `config.xml.applied`. Start from `config.xml.default` next to it, or use a backup from another OPNsense. |
| `drivers` | `auto` (default), `force` or `off`: whether to load the board's extra drivers. |
| `reboot-after-minutes` | Reboot that many minutes after every boot: a safety net for remote installs. Delete it to stop. |

[`scripts/seed-config.py`](scripts/seed-config.py) makes a `config.xml` from the default with a
hostname, an SSH key and interface assignments:

```sh
scripts/seed-config.py opnsense-pi5.config.xml config.xml \
  --hostname fw --ssh-key ~/.ssh/id_ed25519.pub --lan rp1eth0 --wan ue0
```

The hook logs to `/var/log/opnsense-pi.log`.

### First boot

1. Update the Pi's EEPROM bootloader first (from Raspberry Pi OS: `sudo rpi-eeprom-update -a`).
2. Pi 4: press Esc at the UEFI splash. Go to **Device Manager → Raspberry Pi Configuration → Advanced Configuration**,
   set **Limit RAM to 3 GB** to *Disabled*, then save and reset.
3. On the console (HDMI), assign interfaces: LAN `genet0` (Pi 4) or `rp1eth0` (Pi 5), WAN `ue0`.
   Or skip the console: seed a `config.xml` on the FAT partition (see above).
4. Browse to https://192.168.1.1 and log in as `root` / `opnsense`. Change the password.

## Build it

```sh
make image BOARD=pi4      # -> out/opnsense-pi4.img.xz (+ .sha256), without the bundled drivers
make images               # both boards
```

Needs `curl qemu-img sfdisk unzip mtools xz python3`. With Nix: `nix develop`.
Inputs are pinned by URL and sha256 in [`versions.env`](versions.env).

A release image takes three steps, which [CI](.github/workflows/release.yml) runs on every
pull request and tag:

```sh
make raw BOARD=pi5        # Linux: out/opnsense-pi5.img with the firmware
make customize BOARD=pi5  # FreeBSD 15.1 aarch64, as root: bundled drivers + boot hook
make compress BOARD=pi5   # -> out/opnsense-pi5.img.xz, .sha256
```

`customize` has to run on FreeBSD (it writes the UFS root) on aarch64 (it runs the
image's own `pkg` in a chroot). CI uses a FreeBSD VM. It checks out the OPNsense
kernel sources at `/usr/src` and refuses to touch an existing tree there.

## Test it in a VM

QEMU's `virt` machine, shaped like the boards: Pi 5 is 4× Cortex-A76 with 16 GiB,
Pi 4 is 4× Cortex-A72 with 8 GiB.

```sh
make vm BOARD=pi5          # serial console here; Ctrl-a x quits
make test-plugin BOARD=pi5 # install os-realtek-re, reboot, check if_re.ko loads
make test-image  BOARD=pi4 # boot the built image; for a customized one also seed a
                           # config.xml, then check over SSH: seed applied, if_re.ko
                           # loaded, Pi 5 modules installed but skipped on the VM
make test-trial  BOARD=pi5 # reboot-after-minutes reboots the image by itself
make test                  # everything, both boards
```

| | Pi 5 profile | Pi 4 profile |
|---|---|---|
| Web GUI | https://127.0.0.1:8443 | https://127.0.0.1:8444 |
| SSH (enable it in the GUI first) | `ssh -p 2222 root@127.0.0.1` | `ssh -p 2223 root@127.0.0.1` |
| Serial console | `.work/vm/pi5/console.sock` | `.work/vm/pi4/console.sock` |

Every boot is logged to `.work/vm/<profile>/console.log`. Attach to a headless VM's console:
`socat -,raw,echo=0,escape=0x1d UNIX-CONNECT:.work/vm/pi5/console.sock` (Ctrl-] detaches).

What the VM can and can't tell you:

- **Shape only.** On an x86 host the ARM CPU is emulated (TCG), so throughput and latency numbers mean nothing.
  For rough Pi 5 CPU numbers, use a Neoverse N1 cloud VM (AWS Graviton2, GCP T2A).
- **No Pi NICs.** The VM uses virtio. QEMU models neither `genet`, RP1, nor Realtek PCIe,
  so `if_re.ko` loads but has nothing to attach to, and the Pi 5 modules can only be
  checked for being installed, matching the kernel's symbols, and skipped off a Pi 5.
  Whether `rp1eth0` works is only answered on a board.
- **Pi 4 crypto.** QEMU's `cortex-a72` exposes AES/SHA, but a real BCM2711 does not.
- **Boot chain.** The Pi EEPROM bootloader and the Pi UEFI builds only run on real boards.
  The VM boots the same image through QEMU's UEFI and FreeBSD's `loader.efi`.

## Licences

The scripts in this repo are BSD-2-Clause. The images contain OPNsense/FreeBSD (BSD),
TianoCore EDK2 (BSD-2-Clause-Patent), and Raspberry Pi/Broadcom firmware blobs
(redistributable; see `firmware/LICENCE.txt` in the Pi 4 ESP).
OPNsense® is a trademark of Deciso B.V. This project is not affiliated with Deciso or Raspberry Pi Ltd.
