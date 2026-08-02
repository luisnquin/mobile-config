# `adb reboot` does not work in stage-1 on this device -- it answers
# `reboot failed: -1`, because the stage-1 adbd has no init to hand the request
# to. sysrq goes straight to the kernel and does work.
#
# The two syncs are not superstition: the tools that precede this one write
# directly to the block device, and a sysrq reboot does not flush anything.
require_device
echo "identity ok, rebooting via sysrq"
dsh 'sync; sync; echo b > /proc/sysrq-trigger' >/dev/null || true
echo "sent -- the device should drop off the bus now"
