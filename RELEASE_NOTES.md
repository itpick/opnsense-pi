OPNsense 26.7 (FreeBSD 15.1) for Raspberry Pi. Unofficial; not supported by Deciso.

| Asset | Board | Status |
|---|---|---|
| `opnsense-pi4.img.xz` | Raspberry Pi 4 (pftf/RPi4 UEFI v1.53) | Works: LAN `genet0`, WAN USB NIC (`ue0`) |
| `opnsense-pi5.img.xz` | Raspberry Pi 5, D0 boards (rpi5-uefi v0.1, SD boot) | Experimental: no onboard Ethernet yet |

Flash (erases the target):

```sh
curl -fL https://github.com/itpick/opnsense-pi/releases/latest/download/opnsense-pi4.img.xz | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

First-boot steps and VM tests: see the [README](https://github.com/itpick/opnsense-pi#readme).
