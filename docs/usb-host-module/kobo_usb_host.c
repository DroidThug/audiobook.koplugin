/*
 * kobo_usb_host.c
 *
 * Force the Kobo Libra Colour's MTU3 controller into host mode.
 *
 * The MTU3 driver watches extcon_iddig to decide host vs device.
 * We just poke EXTCON_USB_HOST = 1 and the driver does the rest.
 * Tested on firmware 4.44.23552, Linux 4.9.77.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/extcon.h>

#define DRV_NAME "kobo_usb_host"
#define EXTCON_NAME "extcon_iddig"

static struct extcon_dev *edev;

static int __init kobo_usb_host_init(void)
{
	int ret;

	pr_info("%s: loading\n", DRV_NAME);

	edev = extcon_get_extcon_dev(EXTCON_NAME);
	if (IS_ERR_OR_NULL(edev)) {
		pr_err("%s: can't find extcon '%s'\n", DRV_NAME, EXTCON_NAME);
		return -ENODEV;
	}

	pr_info("%s: found extcon '%s'\n", DRV_NAME, EXTCON_NAME);

	ret = extcon_set_state_sync(edev, EXTCON_USB_HOST, true);
	if (ret < 0) {
		pr_err("%s: extcon_set_state_sync failed: %d\n", DRV_NAME, ret);
		return ret;
	}

	pr_info("%s: host mode enabled\n", DRV_NAME);
	return 0;
}

static void __exit kobo_usb_host_exit(void)
{
	int ret;

	pr_info("%s: unloading\n", DRV_NAME);

	if (!IS_ERR_OR_NULL(edev)) {
		ret = extcon_set_state_sync(edev, EXTCON_USB_HOST, false);
		if (ret < 0)
			pr_err("%s: failed to disable host mode: %d\n", DRV_NAME, ret);
		else
			pr_info("%s: host mode disabled\n", DRV_NAME);
	}
}

module_init(kobo_usb_host_init);
module_exit(kobo_usb_host_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Force USB host mode on Kobo Libra Colour");
