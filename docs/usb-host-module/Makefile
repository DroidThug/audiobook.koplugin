# Makefile for kobo_usb_host kernel module
#
# Build instructions:
# 1. Install ARM cross-compiler (e.g., armv7l-unknown-linux-gnueabihf-gcc)
# 2. Download Linux 4.9.77 kernel source
# 3. Run: make HOSTCFLAGS='-fcommon' ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf- modules_prepare
# 4. Build this module: make ARCH=arm CROSS_COMPILE=armv7l-unknown-linux-gnueabihf-
# 5. Transfer .ko to device: scp kobo_usb_host.ko root@kobo:/mnt/onboard/.adds/
# 6. Load: insmod /mnt/onboard/.adds/kobo_usb_host.ko
# 7. Unload: rmmod kobo_usb_host

KDIR ?= /tmp/kobo_kernel_build/linux-4.9.77
ARCH ?= arm
CROSS_COMPILE ?= armv7l-unknown-linux-gnueabihf-

obj-m += kobo_usb_host.o

all:
	$(MAKE) -C $(KDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) M=$(PWD) clean
