# Boot time on a Raspberry Pi 5

Where an opnsense-pi reboot goes, what the image changes to shorten it, and
what is left. Measured on 2026-11-16.

## Where the time goes (before these changes)

From the system log of the live Pi 5 router on 26.7.9_1 (7 typical reboots on
2026-11-15 and 16; data in
[itpick/vyos-pi docs/comparison/data/boot](https://github.com/itpick/vyos-pi/tree/main/docs/comparison/data/boot)).
`rc` prints the uptime in front of each boot message, so everything after the
kernel starts is exact to 1 s. Before the kernel, the log only has the total
(wall clock, to 1 s); its parts are from the firmware's settings and the QEMU
runs below.

| Stage | Pi 5 | What it is |
|---|---:|---|
| Shutdown, Pi firmware, UEFI, loader | **36–38 s** | everything from the first stop script to the kernel |
| of which: UEFI splash | **5 s** | the UEFI waits `Timeout` seconds for Esc. The image's variable store was empty, so the firmware's default applied: `PcdPlatformBootTimeOut` = 5 in rpi5-uefi's `RPi5.dsc` (and in pftf's `RPi4.dsc`) |
| of which: loader menu | **2–3 s** | `autoboot_delay="3"` (OPNsense's `rc.loader.d/20-misc`); the loader's clock has 1 s steps, so it waits 2 to 3 s (QEMU: 2.0–2.8 s) |
| of which: shutdown | a few s | `rc.shutdown`: the stop scripts take 3 s on the Pi (first stop script to syslog-ng's exit), then the kernel syncs the disks and resets |
| kernel → LAN configured | 28–29 s | device probe and root mount, then `rc`: config import, `configd`, templates, devd, `rc.bootup` |
| LAN → SSH and web GUI | 1 s | |
| web GUI → boot finished | 15–18 s | routes, Dnsmasq, Unbound, NTP, then FreeBSD's and the plugins' start scripts (`>>> Invoking start script 'beep'` is the last) |
| **reboot → ready** | **81–85 s** | |

The same boot in QEMU (TCG, everything about 4 to 5 times slower than a Pi;
6 boots, median seconds after each message, kernel to ready): `Initializing`
(`rc.bootup` loading the config and plugins) 27 s, `Starting device manager`
(devd) 20 s, `Starting Cron` 10 s, `Generating configuration` (configd
templates) 9 s, the `freebsd` start scripts 7.5 s, `Starting configd` 7 s,
Unbound 6 s (twice), system logging 5 s. All of those are OPNsense's own boot
sequence.

## What changed

| Change | Where | Saves on a Pi | Measured in QEMU |
|---|---|---:|---|
| UEFI `Timeout` 5 → 1 s | `uefi/pi5-vars.json`, new `uefi/pi4-vars.json` | **4 s** | can't be measured there: QEMU runs its own UEFI, not the Pi's. Checked that the variable lands in `RPI_EFI.fd` as the UINT16 edk2 reads (`virt-fw-vars -p`: `Timeout : word: 0x0001`) |
| Loader `autoboot_delay` 3 → 1 s | `overlay/usr/local/etc/rc.loader.d/30-opnsense-pi` | **2–2.5 s** | countdown 2.0–2.8 s (median 2.45) → 0.0–0.6 s (median 0.0); loader banner to kernel, median 4.3 s → 1.8 s (4 boots each) |
| No firmware UART log, no rainbow splash | `scripts/build-image.sh` (the firmware's `config.txt`) | Pi 4: up to ~0.5 s (pftf turns on `uart_2ndstage=1`); Pi 5: ~0 | can't be measured there (Pi firmware) |
| **Total** | | **about 6–6.5 s of 81–85 s** | |

Expected on the Pi 5 after this: reboot → ready about 75–79 s (reboot →
kernel 30–32 s; everything after the kernel unchanged).

Both waits are still there, only shorter: Esc in the UEFI's 1 s still opens its
setup, which can set the timeout back (Boot Maintenance Manager → Auto Boot
Time-out), and a key during the loader's 1 s countdown stops it at the menu
(single user, kernel.old, ...). An `autoboot_delay` set under System: Settings:
Tunables comes later in `/boot/loader.conf` than the image's chunk and wins.

### On a board that is already installed

The image changes only reach a fresh flash. On a running opnsense-pi:

- UEFI: at the splash press Esc, then Boot Maintenance Manager → Auto Boot
  Time-out: 1, and save.
- Loader: System: Settings: Tunables, add `autoboot_delay` with value `1`
  (OPNsense writes it into `/boot/loader.conf`; it applies from the next boot).

## Board settings (EEPROM)

The Pi 5's EEPROM bootloader belongs to the board, not the image, so the image
does not change it. From Raspberry Pi OS (`sudo rpi-eeprom-config --edit`);
what helps a router that boots from one disk
([the options](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader-configuration)):

| Setting | Recommended | Why |
|---|---|---|
| `BOOT_ORDER` | the boot disk first: `0xf461` SD, `0xf416` NVMe first, `0xf14` USB first | each mode before the right one is tried first; USB mass storage waits up to `USB_MSD_DISCOVER_TIMEOUT` (20 s) when nothing is plugged in |
| `NET_INSTALL_ENABLED` | `0` | network install looks for a keyboard on every boot, "approximately 1 second" (the bootloader documentation) |
| `BOOT_UART` | `0` (the default) | `1` logs the bootloader on the debug UART at 115200 baud, which the boot waits for |
| `DISABLE_HDMI` | `1` if no screen is used | no HDMI diagnostics screen (`HDMI_DELAY`, 5 s, already keeps it from showing on a normal boot) |
| `PCIE_PROBE` | leave unset | only for NVMe adapters that are not HAT+ |

## Not changed, and why

- **The rest of the UEFI wait** (1 s) and the loader's 1 s: shorter would make
  setup and the boot menu impractical to reach from a keyboard, which is how
  a router without its web GUI gets recovered.
- **The loader's 14 modules** (`carp`, `if_bridge`, `pf`, ... in
  `rc.loader.d/20-modules`): OPNsense loads them in the loader on purpose
  ("makes races with individual module's settings impossible"). Loading the
  kernel and all modules takes about 1.5 s in QEMU.
- **Everything after the kernel** (kernel → ready, 45–48 s): it is OPNsense's
  own boot (`rc`, `rc.bootup`, configd, devd, the services the config
  enables), not an image default. What a user can change: services they do
  not use (Unbound and Dnsmasq both start on a default config), and plugins.
- **Shutdown**: `rc.freebsd stop` and the services' own stop scripts, then
  the kernel's sync; nothing image-level.
- The Pi firmware (EEPROM start, SDRAM, `config.txt`, loading
  `RPI_EFI.fd`): see the EEPROM settings above.

## How it was measured

`vm/boot-bench.sh` boots the built image in QEMU (`vm/run.sh`) and
`vm/console-stamp.py` stamps every serial console line with the host's clock,
so each loader, kernel and `rc` message gets a time. Each run boots, applies a
variant in the guest and reboots, then measures that boot and one more after
`shutdown -r now`, alternating the variants. QEMU's TCG on an x86 host is several
times slower than a Pi and was shared with other jobs, so only the fixed waits
(the loader countdown) compare directly; the UEFI timeout and the Pi firmware
only run on a board.
