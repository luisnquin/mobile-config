# Read-only fastboot probe for huawei-marie.
#
# It reboots the unit into its bootloader, dumps every variable the locked
# Huawei fastboot will disclose, and reboots back. getvar and reboot are the
# only fastboot verbs it runs -- it never flashes, boots an image, erases, or
# touches the unlock state, so a locked device ends exactly as locked as it
# started. The point of it is the two facts read-only adb cannot reach:
# `version-bootloader` (adb reports `ro.bootloader = unknown`) and whether the
# bootloader accepts anything at all while locked.
#
# Identity is pinned on both sides of the reboot: the model is checked over adb
# first, then the bootloader serial is required to equal the adb serial, so the
# probe cannot retarget a different phone that happens to be on the bus. There
# are two phones in this setup and only marie is in scope.

EXPECT_MODEL="MAR-LX3Bm"

stay=0
case "${1:-}" in
"") ;;
--stay) stay=1 ;;
*)
  echo "usage: marie-fastboot-probe [--stay]" >&2
  echo "  --stay  leave the device in fastboot instead of rebooting to android" >&2
  exit 2
  ;;
esac

# --- guard in adb: exactly one device, and it is marie ---
mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
if [ "${#devs[@]}" -ne 1 ]; then
  echo "need exactly one adb device in 'device' state, found ${#devs[@]}" >&2
  exit 1
fi
serial="${devs[0]}"
model="$(adb -s "$serial" shell getprop ro.product.model | tr -d '\r')"
if [ "$model" != "$EXPECT_MODEL" ]; then
  echo "connected device is '$model', not $EXPECT_MODEL -- refusing" >&2
  exit 1
fi
echo "adb: $serial is $model"

# --- reboot to bootloader ---
echo "rebooting into the bootloader..."
adb -s "$serial" reboot bootloader

# --- wait for the same serial to reappear in fastboot ---
for _ in $(seq 1 30); do
  if fastboot devices | grep -q "^${serial}[[:space:]]"; then break; fi
  sleep 1
done
if ! fastboot devices | grep -q "^${serial}[[:space:]]"; then
  echo "device ${serial} did not reappear in fastboot within 30s" >&2
  echo "it may need a manual power-cycle back to android" >&2
  exit 1
fi
echo "fastboot: ${serial} present"

# --- read-only getvar dump ---
echo "=== fastboot getvar all ==="
fastboot -s "$serial" getvar all 2>&1 || true

# A curated set as well: Huawei bootloaders filter `getvar all`, so the fields
# that matter are queried by name in case the bulk dump omitted them.
echo "=== curated getvar ==="
for v in product version-bootloader version-baseband unlocked secure \
  off-mode-charge battery-voltage partition-type:kernel partition-size:kernel; do
  printf '%s: ' "$v"
  fastboot -s "$serial" getvar "$v" 2>&1 | head -n1 || true
done

# --- back to android, unless asked to stay ---
if [ "$stay" -eq 1 ]; then
  echo "leaving device in fastboot (--stay); run 'fastboot reboot' to return"
else
  echo "rebooting back to android..."
  fastboot -s "$serial" reboot
fi
