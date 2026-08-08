# Writes a boot image from the stage-1 shell, where fastboot is not reachable.
#
#     nix run .#dandelion-flash-bootimg -- result-dandelion/boot.img
#
# The generated flash-critical.sh does this with `fastboot flash boot`, which
# needs the bootloader. Once the device is parked in stage-1 the equivalent is a
# dd onto the block device carrying that GPT label.
#
# THE DEFAULT TARGET IS `recovery`, NOT `boot`. This port boots from the recovery
# partition deliberately: `boot` (p33) still holds stock Android and has never
# been written, which is what makes every experiment here reversible. LK reads
# the Android boot control block out of `para` (p3) and honours `boot-recovery`,
# so stage-1 is re-entered without a key combination. Passing `boot` as the
# second argument overwrites the only way back to a working Android. See
# devices/xiaomi-dandelion/README.md, "Where the rootfs lives, and how to get
# back".
#
# The partition is resolved by name rather than by index -- see resolve_partition
# in lib.sh. The mmcblk index is not stable across MTK layouts, and a wrong index
# here writes 25 MB over lk or nvram, partitions AGENTS.md puts out of bounds
# precisely because they are the ones that are not recoverable over USB.
#
# The write is verified BEFORE anything reboots, because this is the one step in
# the whole pipeline whose failure is not recoverable over adb: a truncated image
# means no stage-1, no gadget, and fastboot as the only way back.
IMG=${1:?usage: dandelion-flash-bootimg /path/to/boot.img [partition]}
PART=${2:-recovery}

# mkbootimg pads its output to --pagesize, and this device's is 2048, so a boot
# image is a multiple of 2048 and only lands on a 4096 boundary by luck. This one
# did not: 26572800 bytes, 2048 past the last whole block. Everything below moves
# 4096-byte blocks -- that is the granularity the adb transport is driven at, and
# it has to match on both sides for the read-back hash to mean anything -- so a
# short tail is zero-padded rather than refused. Nothing reads what the padding
# covers: LK takes the kernel and ramdisk extents from the boot header, never
# from the length of the partition.
RAW=$(stat -Lc %s "$IMG")
BLOCKS=$(((RAW + 4095) / 4096))
BYTES=$((BLOCKS * 4096))

# Hashed and written from the padded copy, so WANT describes the same bytes the
# device is asked to read back.
PADDED=$(mktemp)
trap 'rm -f "$PADDED"' EXIT
cp -- "$IMG" "$PADDED"
truncate -s "$BYTES" "$PADDED"

WANT=$(sha256sum "$PADDED" | cut -d' ' -f1)
echo "image $IMG -> $RAW bytes, padded to $BYTES ($BLOCKS blocks)"
echo "want  $WANT"

require_device
echo "identity ok"

# A lower bar than the deploy's: this writes 25 MB rather than 3 GB. It is still
# guarded, because losing power midway is what leaves the device with no stage-1
# to come back to.
require_power 20

DEV=$(resolve_partition "$PART" || true)
case "$DEV" in
  /dev/block/mmcblk0p[0-9]*|/dev/mmcblk0p[0-9]*) ;;
  *)
    echo "FATAL: partition '$PART' resolved to '${DEV:-<nothing>}', refusing to write" >&2
    exit 1
    ;;
esac
echo "TARGET PARTITION: $PART -> $DEV"
if [ "$PART" = "boot" ]; then
  echo "note: writing 'boot' replaces stock Android, this port normally targets 'recovery'" >&2
fi

SECTORS=$(dsh "cat /sys/class/block/$(basename "$DEV")/size" || true)
if [ -z "$SECTORS" ]; then
  echo "FATAL: could not read the size of $DEV" >&2
  exit 1
fi
echo "partition holds $((SECTORS * 512)) bytes"
if [ $((SECTORS * 512)) -lt "$BYTES" ]; then
  echo "FATAL: image is larger than the partition" >&2
  exit 1
fi

for try in 1 2 3; do
  dd if="$PADDED" bs=4096 2>/dev/null \
    | adb_ exec-in "dd of=$DEV bs=4096 conv=notrunc 2>/dev/null; sync" || true

  got=$(dsh "dd if=$DEV bs=4096 count=$BLOCKS 2>/dev/null | sha256sum > /run/b.sha; cat /run/b.sha" \
    | cut -d' ' -f1 || true)

  if [ -z "$got" ]; then
    echo "try $try: verify returned nothing, transport dropped"
    sleep 5
    continue
  fi
  if [ "$got" = "$WANT" ]; then
    echo "BOOT WRITE OK (try $try)"
    exit 0
  fi
  echo "try $try: MISMATCH got=${got:0:12}"
done

echo "FAILED after 3 tries" >&2
exit 1
