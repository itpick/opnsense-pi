OPNsense 26.7 (FreeBSD 15.1) for Raspberry Pi. Unofficial; not supported by Deciso.

| Asset | Board | Status |
|---|---|---|
| `opnsense-pi4.img.xz` | Raspberry Pi 4 (pftf/RPi4 UEFI v1.53) | Works: LAN `genet0`, WAN USB NIC (`ue0`); `os-realtek-re` preinstalled |
| `opnsense-pi5.img.xz` | Raspberry Pi 5, D0 boards (rpi5-uefi v0.1, SD boot) | Works: in daily use as a home router on one 16 GB board, about 830 Mbit/s down and 700 up on a 1 Gb/s line: WAN on onboard `rp1eth0`, LAN on RTL8156 2.5 GbE USB adapters (`ue0`, `ue1`, names pinned by MAC); `os-realtek-re` preinstalled |

Flash (erases the target):

```sh
curl -fL https://github.com/itpick/opnsense-pi/releases/latest/download/opnsense-pi4.img.xz | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Each image's contents: `opnsense-<board>.manifest.txt`. Its default config, to seed from (`opnsense-pi/config.xml` on the FAT partition): `opnsense-<board>.config.xml`.

Boot time, what the image does to shorten it (UEFI splash 1 s, boot menu 1 s), and EEPROM settings that help: [docs/boot-time.md](https://github.com/itpick/opnsense-pi/blob/main/docs/boot-time.md).

First-boot steps and VM tests: see the [README](https://github.com/itpick/opnsense-pi#readme).
