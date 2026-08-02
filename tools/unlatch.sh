require_device
echo "identity ok"

magic_restore
echo "magic now:$(magic_show)"
echo "disarmed -- the next boot will try to mount root and continue to stage-2"
