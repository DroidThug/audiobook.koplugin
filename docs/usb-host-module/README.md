# kobo_usb_host

Tiny kernel module that tricks the Kobo Libra Colour's MediaTek MTU3 USB controller into host mode. Works on firmware 4.44.23552, Linux 4.9.77.

## What it actually does

The MTU3 driver watches an extcon device called `extcon_iddig` to decide whether to be a USB host or gadget. This module just sets `EXTCON_USB_HOST = 1` on that extcon, which makes the driver switch to host mode and register the xHCI controller.

When loaded you get:

- `11210000.xhci` showing up as a host controller
- USB 2.0 root hub with 2 ports
- USB 3.0 root hub (no actual ports wired, I think)

## But it won't charge your DAC

The Libra Colour's USB-C port is missing the hardware to actually *be* a host:

- No VBUS sourcing (can't power anything)
- No CC pull-up resistors (can't negotiate host mode on the wire)

So the kernel side works, but physically nothing can talk to the port. I found this out the hard way when plugging in a USB-C to AUX adapter crashed the device.

Still, the module itself is solid. If Kobo ever makes a device with the same MTU3 setup but proper host hardware, this should work as-is.

## Build

You need the matching kernel source (4.9.77) and an ARM cross-compiler.

On NixOS:

```bash
nix-shell -p pkgsCross.armv7l-hf-multiplatform.buildPackages.gcc gnumake bc perl
make ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf-
```

## Load / unload

```bash
insmod /mnt/onboard/.adds/kobo_usb_host.ko
rmmod kobo_usb_host
```

## License

GPL v2 (same as the kernel)
