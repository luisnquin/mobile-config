# Shared plumbing for the dandelion bring-up tools.
#
# Concatenated ahead of each tool's own text by ./default.nix, so these are
# plain definitions rather than a sourced file -- the tools stay single-file,
# and shellcheck still analyses this code instead of skipping over a `source`.
#
# The cost of that choice is the SC2329/SC2034 directives below: every tool gets
# the whole set, so each one leaves most of it unused. Suppressing them per
# definition keeps the linting on everything else.
#
# The @placeholders@ are substituted from ../modules/bringup-log/layout.nix, so
# the offsets here cannot drift from the ones the device writes.

# The adb transport id, which is not the device's identity. This unit answers to
# 0123456789 on the bus while /proc/cmdline carries HADAHAORHAV8YHB6; only the
# latter identifies the hardware, and only the latter is safe to gate writes on.
: "${ADB_SERIAL:=0123456789}"
: "${DEVICE_ID:=HADAHAORHAV8YHB6}"
: "${ROOT_PART:=/dev/mmcblk0p41}"

# shellcheck disable=SC2034
{
  # ext4 superblock magic 0xEF53, stored little-endian at 1024 + 56.
  MAGIC_OFFSET=1080

  LOG_SLOT_A=@slotA@
  LOG_SLOT_B=@slotB@
  LOG_MAGIC=@magic@
}

# shellcheck disable=SC2329
adb_() { adb -s "$ADB_SERIAL" "$@"; }

# Device-side shell with the CR stripped. Failures are swallowed on purpose:
# every caller distinguishes "said nothing" from "said the wrong thing", and an
# adb transport death shows up as the former.
# shellcheck disable=SC2329
dsh() { adb_ shell "$@" 2>/dev/null | tr -d '\r'; }

# Never write to the wrong phone. Called before every destructive operation
# rather than once at startup, because the device can drop off the bus and come
# back between two steps of the same script.
# shellcheck disable=SC2329
require_device() {
  if ! dsh "grep -q $DEVICE_ID /proc/cmdline && echo OK" | grep -q OK; then
    echo "FATAL: identity check failed, expected $DEVICE_ID in /proc/cmdline" >&2
    exit 1
  fi
}

# shellcheck disable=SC2329
wait_device() {
  local tries="${1:-60}" i=0
  while [ "$i" -lt "$tries" ]; do
    if adb_ exec-out 'echo up' 2>/dev/null | grep -q up; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

# Zeroing the magic makes stage-1 fail to mount root, which drops it into the
# shellOnFail shell. That shell blocks on /dev/console forever, so adbd stays up
# indefinitely -- the only reliable debug window this device has. Without it
# there is a ~16s window per boot and nothing else.
# shellcheck disable=SC2329
magic_zero() {
  printf '\0\0' \
    | adb_ exec-in "dd of=$ROOT_PART bs=1 seek=$MAGIC_OFFSET conv=notrunc 2>/dev/null; sync"
}

# shellcheck disable=SC2329
magic_restore() {
  printf '\123\357' \
    | adb_ exec-in "dd of=$ROOT_PART bs=1 seek=$MAGIC_OFFSET conv=notrunc 2>/dev/null; sync"
}

# shellcheck disable=SC2329
magic_show() {
  adb_ exec-out "dd if=$ROOT_PART bs=1 skip=$MAGIC_OFFSET count=2 2>/dev/null" \
    | od -A n -t x1 | tr -s ' '
}

# Reads a log slot's header block. Empty output means either an unwritten slot
# or a dead transport; callers treat both as "no candidate here".
# shellcheck disable=SC2329
log_header() {
  adb_ exec-out "dd if=$ROOT_PART bs=4096 skip=$1 count=1 2>/dev/null" | tr -d '\0' | head -n 1
}

# shellcheck disable=SC2329
log_field() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}
