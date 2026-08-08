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

# Refuses to write $ROOT_PART while something has it mounted.
#
# The raw write is only safe from the stage-1 latch. Until patch 0010 landed this
# needed no check, because stage-2 could not exec anything and therefore had no
# adbd: "adb answers" and "the device is in stage-1" were the same statement. They
# stopped being the same statement the moment stage-2 started working, and a
# deploy run against a booted system rewrites the filesystem under it.
#
# Compared on major:minor rather than on device paths, because stage-2 mounts "/"
# through /dev/disk/by-label and stage-1 by node -- the same partition spelled two
# ways. Unreadable inputs abort rather than warn: the whole point is that the
# unsafe case is indistinguishable from the safe one at the adb level.
# shellcheck disable=SC2329
require_unmounted_root() {
  local want mounted
  want=$(dsh "cat /sys/class/block/${ROOT_PART##*/}/dev")
  if [ -z "$want" ]; then
    echo "FATAL: cannot read major:minor for $ROOT_PART, refusing to write blind" >&2
    exit 1
  fi

  # One partition can carry several mounts -- stage-2 has p41 on both / and
  # /nix/store -- so the list is flattened onto one line for the message.
  mounted=$(dsh "cut -d' ' -f3,5 /proc/self/mountinfo" | sed -n "s/^$want //p" | tr '\n' ' ')
  if [ -n "$mounted" ]; then
    echo "FATAL: $ROOT_PART is mounted on ${mounted% }. Writing it raw would rewrite" >&2
    echo "       the filesystem under the running system. Park the device first:" >&2
    echo "         nix run .#dandelion-latch" >&2
    exit 1
  fi
}

# Refuses to start a write the battery cannot finish.
#
# Stage-1 has no charger userspace: nothing negotiates USB current, so the phone
# sits at the 500 mA default while idling on more than that. The battery reports
# status=Charging and drains anyway -- measured at -226 mA with 9% left, and two
# bring-up runs died that way, one of them from 18% after an hour in the latch.
# Charging has to happen from a wall charger, and never by booting Android, which
# would meet the deliberately zeroed superblock on p41 and may reformat it.
#
# A device that does not expose capacity is warned about rather than blocked. The
# check exists to catch a known failure, not to become a new one.
# shellcheck disable=SC2329
require_power() {
  local min=${1:-${MIN_BATTERY:-40}} cap
  cap=$(dsh 'cat /sys/class/power_supply/battery/capacity' | tr -dc '0-9')
  if [ -z "$cap" ]; then
    echo "warning: battery capacity unreadable, proceeding without the power check" >&2
    return 0
  fi

  echo "battery at ${cap}%"
  if [ "$cap" -lt "$min" ]; then
    echo "FATAL: ${cap}% is under the ${min}% this step needs. Charge from a wall" >&2
    echo "       charger -- the latch drains on a PC port. MIN_BATTERY overrides." >&2
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

# Resolves a GPT partition name to its block device node.
#
# /dev/block/by-name is built by udev or Android init, and the stage-1 shell runs
# neither -- so on the device this port actually writes from, the symlink farm is
# absent entirely. The kernel still publishes the GPT label as PARTNAME in each
# partition's sysfs uevent, and that is the same string the symlink would have
# been named after, so it is the authoritative source rather than a workaround.
#
# Resolution is by name in both paths and never by index: the mmcblk index is not
# stable across MTK layouts, and a wrong index writes over lk or nvram, which are
# the partitions that cannot be recovered over USB. More than one match means the
# label is ambiguous and the caller gets nothing rather than a guess.
# shellcheck disable=SC2329
resolve_partition() {
  local want=$1 dev hits
  dev=$(dsh "readlink -f /dev/block/by-name/$want" || true)
  case "$dev" in
    /dev/block/mmcblk0p[0-9]* | /dev/mmcblk0p[0-9]*)
      printf '%s\n' "$dev"
      return 0
      ;;
  esac

  hits=$(dsh "grep -l '^PARTNAME=$want\$' /sys/class/block/mmcblk0p*/uevent 2>/dev/null" || true)
  [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] || return 1
  printf '%s\n' "$hits" | sed -n 's#^/sys/class/block/\([^/]*\)/uevent$#/dev/\1#p'
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
