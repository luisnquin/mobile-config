echo "waiting for the stage-1 adb window -- power-cycle the device now"

# Busy poll with no sleep, on purpose. A boot that mounts root successfully
# exposes adb for roughly 16 seconds before stage-2 tears the gadget down, and a
# 1-2s poll interval loses that window often enough to cost several power-cycles
# per attempt.
while ! adb_ exec-out 'echo up' 2>/dev/null | grep -q up; do :; done
echo "device on the bus"

require_device
echo "identity ok"

magic_zero
echo "magic now:$(magic_show)"
echo "armed -- the device parks in stage-1 with adb alive, indefinitely"
