# Kobo Libra Colour USB Host Mode Investigation

**Date:** 2026-05-12  
**Device:** Kobo Libra Colour (N428)  
**SoC:** MediaTek MT8110 / MT8512  
**Kernel:** Linux 4.9.77, ARMv7L (32-bit)  
**Goal:** Get wired headphones working via a USB-C to 3.5mm adapter

---

## tl;dr

I got USB host mode working in software. The kernel module loads, the xHCI controller registers, everything looks right. Then I plugged in a USB-C DAC and the device rebooted. The hardware is missing VBUS circuitry and CC pull-ups, so the port can never actually talk to USB peripherals. Bluetooth audio receiver it is.

---

## Device basics

Model N428, MediaTek MT8110/MT8512, ARMv7L. Kernel compiled by `william@MTKbuild` with GCC 4.9.1. Boot mode 11 (MediaTek thing). Rootfs is `/dev/mmcblk0p10` (1GB ext4), user data is `/dev/mmcblk0p12` mounted at `/mnt/onboard`.

Device tree says:

```
compatible: mediatek,mt8110 mediatek,mt8512
model: MediaTek MT8110 board
```

## Kernel config

Pulled `/proc/config.gz` and had a look. The interesting bits:

- `CONFIG_USB_XHCI_HCD=y` and `CONFIG_USB_XHCI_MTK=y` - xHCI host driver is there
- `CONFIG_USB_MTU3_DUAL_ROLE=y` - dual-role controller
- `CONFIG_SND_USB_AUDIO=y` - USB audio support compiled in
- `CONFIG_USB_OTG` not set - no OTG framework
- `CONFIG_MTK_USB_TYPEC` not set - no USB-C CC logic

The big discovery: `CONFIG_MODULES=y` but `CONFIG_MODULE_SIG` is not set. This means I can load unsigned kernel modules without touching the boot chain at all. That made the whole approach possible.

Also notable: `CONFIG_KALLSYMS=y` so the symbol table is exposed. `CONFIG_DM_VERITY=y` and MTK security are active, so custom kernel flashing would be a pain.

## USB controller setup

The MTU3 dual-role controller sits at `0x11211000`. Its child xHCI is at `0x11210000`. The PHY is at `0x11cc0000`.

Clocks are running at 124.8 MHz (`ssusb_xhci_sel` and `infra_usb_xhci`), so the hardware is definitely powered.

Before the module:

```
/sys/class/extcon/extcon0/state: USB=0, USB_HOST=0
/proc/asound/cards: --- no soundcards ---
/sys/bus/platform/drivers/xhci-mtk: no bound devices
```

Device tree for the USB node:

```
compatible = "mediatek,mtu3"
dr_mode = "otg"
status = "okay"
mediatek,force_vbus = <true>
extcon = <&extcon_iddig>
```

## MTU3 driver

The upstream MTU3 driver wasn't in vanilla 4.9.77; it landed in 4.10. Kobo/MediaTek backported it, and they even included `ssusb_set_force_mode` which was added in 2021. I grabbed the upstream source from torvalds/linux to understand the structures.

Key exported symbols from `/proc/kallsyms`:

| Symbol | Address | What it does |
|--------|---------|-------------|
| `ssusb_host_enable` | `c057c2cc` | Powers on host IP |
| `ssusb_host_init` | `c057c504` | Registers xHCI platform device |
| `ssusb_host_exit` | `c057c628` | Cleans up host mode |
| `ssusb_set_vbus` | `c05823dc` | Controls VBUS regulator (or tries to) |
| `ssusb_set_force_mode` | `c05827ec` | Forces host/device mode |
| `extcon_get_extcon_dev` | `c06e6e4c` | Looks up extcon by name |
| `extcon_set_state_sync` | `c06e72c0` | Sets extcon state |

The driver uses extcon for role detection. On boot, `ssusb_otg_switch_init()` schedules delayed work. After a second, `ssusb_extcon_register()` checks extcon state. If `USB_HOST=0`, it calls `ssusb_set_mailbox(MTU3_ID_FLOAT)` which puts the port in device mode.

My plan: set `EXTCON_USB_HOST = 1` on `extcon_iddig`, which fires `ssusb_id_notifier`, which calls `ssusb_set_mailbox(MTU3_ID_GROUND)`, which switches to host mode.

## The module

Built on NixOS 25.11 with `armv7l-unknown-linux-gnueabihf-gcc` (GCC 14.3.0) against the 4.9.77 kernel source.

Kernel prep:

```bash
nix-shell -p pkgsCross.armv7l-hf-multiplatform.buildPackages.gcc
mkdir -p /tmp/kobo_kernel_build
curl -L -o linux-4.9.77.tar.xz https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.9.77.tar.xz
tar xf linux-4.9.77.tar.xz
zcat /proc/config.gz > .config
make HOSTCFLAGS='-fcommon' ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf- oldconfig
make HOSTCFLAGS='-fcommon' ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf- modules_prepare
```

Source is just `kobo_usb_host.c` (see the `usb-host-module/` dir). It looks up `extcon_iddig` and calls `extcon_set_state_sync(edev, EXTCON_USB_HOST, true)`.

Compiled to a 103KB `.ko` file. ELF32, ARM.

## Loading it

```bash
insmod /mnt/onboard/.adds/kobo_usb_host.ko
```

Kernel log:

```
[42664.577143] kobo_usb_host: found extcon device 'extcon_iddig'
[42664.577156] mtu3 11211000.usb: mailbox state(2)
[42664.578157] 11210000.xhci supply vusb33 not found, using dummy regulator
[42664.579484] xhci-mtk 11210000.xhci: xHCI Host Controller
[42664.579520] xhci-mtk 11210000.xhci: new USB bus registered, assigned bus number 1
[42664.584683] hub 1-0:1.0: USB hub found
[42664.584772] hub 1-0:1.0: 2 ports detected
[42664.585251] xhci-mtk 11210000.xhci: xHCI Host Controller
[42664.585267] xhci-mtk 11210000.xhci: new USB bus registered, assigned bus number 2
[42664.588387] kobo_usb_host: set EXTCON_USB_HOST = 1
[42664.593730] mtu3 11211000.usb: xHCI platform device register success...
```

Post-load:

```
/sys/class/extcon/extcon0/state: USB=0, USB_HOST=1
```

USB buses 1 and 2 both registered. Looks great.

## Then reality hits

Plugged in a USB-C to AUX adapter. Device **immediately rebooted**.

After reboot, no module, no xHCI. Adapter not enumerated. Not a good sign.

### VBUS

Checked the regulator:

```
/sys/kernel/debug/regulator/vbus/11211000.usb-vbus/min_uV: 0
/sys/kernel/debug/regulator/vbus/11211000.usb-vbus/max_uV: 0
/sys/kernel/debug/regulator/vbus/11211000.usb-vbus/uA_load: 0
```

VBUS stayed at 0V even after loading the module. Looking at the upstream `ssusb_set_vbus()` source:

```c
int ssusb_set_vbus(struct otg_switch_mtk *otg_sx, int is_on)
{
    struct regulator *vbus = otg_sx->vbus;
    if (!vbus)
        return 0;  /* success, but did nothing */
    ...
}
```

If `vbus` is NULL, it returns success without powering anything. That's exactly what's happening.

There's a `vbus` GPIO (`gpio-423 (|vbus) out hi`) but it doesn't seem wired to the actual USB-C connector VBUS pin.

### CC pins

USB-C host mode needs a pull-up resistor (Rp) on the CC line to advertise itself as a host. The Libra Colour only has the device pull-down (Rd) because it's meant to connect to PCs as a device.

When I plug in a USB-C DAC adapter (which also has Rd), both sides see Rd-Rd. No host is detected. The adapter never turns on its USB device side. The electrical mismatch probably caused the reboot.

So the hardware is missing three things:

1. VBUS sourcing - no 5V to power peripherals
2. CC pull-ups - can't negotiate host mode electrically
3. Type-C controller - `CONFIG_MTK_USB_TYPEC` isn't even set

The `mediatek,force_vbus = true` device tree property probably means "assume an external PHY handles VBUS" rather than "output VBUS."

## Partition layout (for reference)

| Device | Size | What |
|--------|------|------|
| `/dev/mmcblk0p1` | 512KB | Preloader / GPT MBR |
| `/dev/mmcblk0p2` | 1MB | Device tree blob |
| `/dev/mmcblk0p3` | 1MB | Secondary DTB |
| `/dev/mmcblk0p4` | 48MB | Kernel / recovery |
| `/dev/mmcblk0p5` | 4MB | DTBO / misc |
| `/dev/mmcblk0p8` | 10MB | `/data/init_bin` (ext4, waveforms) |
| `/dev/mmcblk0p9` | 48MB | Recovery partition (FAT) |
| `/dev/mmcblk0p10` | 1GB | Root filesystem (ext4) |
| `/dev/mmcblk0p11` | 1GB | Secondary system |
| `/dev/mmcblk0p12` | 27GB | User data (`/mnt/onboard`, vfat) |
| `/dev/mmcblk0boot0` | 4MB | eMMC boot |
| `/dev/mmcblk0boot1` | 4MB | eMMC boot mirror |
| `/dev/mmcblk0rpmb` | 4MB | RPMB |

No secure boot, but dm-verity and MTK security are active. Custom kernel flashing would be risky.

## What to do with this

The module is tested and works for what it does (forcing host mode). It might be useful for:

- Other MT8110/MT8512 devices with proper host hardware
- Future Kobo devices that reuse this USB setup
- Anyone doing kernel module dev on locked-down Kobo firmware (since unsigned modules load fine)

For the Libra Colour specifically, forget USB audio. Use a Bluetooth audio receiver. Way easier.

## Quick reference

```bash
# Check config
zcat /proc/config.gz

# Find symbols
cat /proc/kallsyms | grep -iE 'ssusb|mtu3|extcon|xhci'

# Load module
insmod /mnt/onboard/.adds/kobo_usb_host.ko

# Check state
cat /sys/class/extcon/extcon0/state
cat /sys/kernel/debug/usb/devices
cat /proc/asound/cards

# Build (NixOS)
nix-shell -p pkgsCross.armv7l-hf-multiplatform.buildPackages.gcc gnumake bc perl
make HOSTCFLAGS='-fcommon' ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf- oldconfig
make HOSTCFLAGS='-fcommon' ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf- modules_prepare
make ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf-

# Transfer to device
cat kobo_usb_host.ko | ssh -p 2222 root@<DEVICE_IP> "cat > /mnt/onboard/.adds/kobo_usb_host.ko"
```
