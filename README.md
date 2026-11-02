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
| Onboard Ethernet | `genet0` works (use as LAN) | **No.** RP1 Ethernet needs out-of-tree drivers ([aphor/FreeBSD15-RPi5-modules](https://github.com/aphor/FreeBSD15-RPi5-modules)) |
| WAN | USB 3 NIC, RTL8153 (`ure0`) or AX88179 (`axge0`) | USB NIC, unverified |
| AES in hardware | No (BCM2711 has no ARMv8 crypto), so VPNs are CPU-bound | Yes (Cortex-A76) |
| Verdict | Works today | Experimental: boot only |

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

### First boot

1. Update the Pi's EEPROM bootloader first (from Raspberry Pi OS: `sudo rpi-eeprom-update -a`).
2. Pi 4: press Esc at the UEFI splash. Go to **Device Manager → Raspberry Pi Configuration → Advanced Configuration**,
   set **Limit RAM to 3 GB** to *Disabled*, then save and reset.
3. On the console (HDMI), assign interfaces: LAN `genet0`, WAN `ue0`.
4. Browse to https://192.168.1.1 and log in as `root` / `opnsense`. Change the password.

## Build it

```sh
make image BOARD=pi4      # -> out/opnsense-pi4.img.xz (+ .sha256)
make images               # both boards
```

Needs `curl qemu-img sfdisk unzip mtools xz python3`. With Nix: `nix develop`.
Inputs are pinned by URL and sha256 in [`versions.env`](versions.env).

## Test it in a VM

QEMU's `virt` machine, shaped like the boards: Pi 5 is 4× Cortex-A76 with 16 GiB,
Pi 4 is 4× Cortex-A72 with 8 GiB.

```sh
make vm BOARD=pi5          # serial console here; Ctrl-a x quits
make test-plugin BOARD=pi5 # install os-realtek-re, reboot, check if_re.ko loads
make test-image  BOARD=pi4 # boot the built image to the web GUI
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
  so `if_re.ko` loads but has nothing to attach to.
- **Pi 4 crypto.** QEMU's `cortex-a72` exposes AES/SHA, but a real BCM2711 does not.
- **Boot chain.** The Pi EEPROM bootloader and the Pi UEFI builds only run on real boards.
  The VM boots the same image through QEMU's UEFI and FreeBSD's `loader.efi`.

## Licences

The scripts in this repo are BSD-2-Clause. The images contain OPNsense/FreeBSD (BSD),
TianoCore EDK2 (BSD-2-Clause-Patent), and Raspberry Pi/Broadcom firmware blobs
(redistributable; see `firmware/LICENCE.txt` in the Pi 4 ESP).
OPNsense® is a trademark of Deciso B.V. This project is not affiliated with Deciso or Raspberry Pi Ltd.
