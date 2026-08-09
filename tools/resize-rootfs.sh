# Grow the rootfs to the log ring ceiling, offline, from the stage-1 latch.
#
# Online resizing does not work on this filesystem, and the reason is on-disk
# rather than a size limit. Whatever builds the image lays down a resize inode
# whose reserved-GDT list is off by one: the kernel walks it expecting `blk + i`
# and finds block 256 where offset 255 should hold 257, so EXT4_IOC_RESIZE_FS
# aborts the moment it has to write a *backup* group descriptor. Measured on the
# deployed system, growth from 1044190 blocks stopped at exactly 1605632 -- 49
# groups, and 49 = 7^2 is a backup-superblock group:
#
#   EXT4-fs warning (device mmcblk0p41): reserve_backup_gdb:971:
#     reserved block 256 not at offset 255
#   EXT4-fs warning (device mmcblk0p41): ext4_resize_fs:2051:
#     error (-22) occurred during file system resize
#
# Every retry failed identically at "add group #49", because each one has to
# cross the same structure. resize2fs rebuilds it itself when the filesystem is
# unmounted -- and unmounted is the state a deploy already requires, so this
# costs no extra window.
#
# Padding the image instead was considered and rejected in
# ../devices/xiaomi-dandelion/default.nix: the image is read back in full on
# every deploy at ~12.6 MB/s, so width is paid forever while this is paid once.

require_device
require_unmounted_root
require_power

# e2fsck and resize2fs both need a readable superblock, and the latch works by
# zeroing exactly that. Restoring it only changes what the *next* boot does, so
# the stage-1 session this runs in survives it.
MAGIC=$(magic_show | tr -d ' ')
if [ "$MAGIC" != "53ef" ]; then
  echo "FATAL: ext4 magic on $ROOT_PART reads '$MAGIC', not 53ef -- the superblock" >&2
  echo "       is zeroed and neither e2fsck nor resize2fs can read it. Restore it:" >&2
  echo "         nix run .#dandelion-unlatch" >&2
  exit 1
fi

# Stage-1 has no PATH to speak of; the binaries come from the initrd's
# extra-utils closure, which mobile-nixos/modules/rootfs.nix installs
# unconditionally rather than only when autoResize is on.
find_tool() {
  dsh "for c in \$(command -v $1 2>/dev/null) /nix/store/*extra-utils*/bin/$1; do
         [ -x \"\$c\" ] && { echo \"\$c\"; break; }
       done" | head -n 1
}

RESIZE2FS=$(find_tool resize2fs)
E2FSCK=$(find_tool e2fsck)
DUMPE2FS=$(find_tool dumpe2fs)
for t in "$RESIZE2FS" "$E2FSCK" "$DUMPE2FS"; do
  if [ -z "$t" ]; then
    echo "FATAL: e2fsprogs not found on the device -- is this the stage-1 shell?" >&2
    exit 1
  fi
done

sb_field() {
  dsh "$DUMPE2FS -h $ROOT_PART 2>/dev/null" | sed -n "s/^$1: *//p" | head -n 1
}

BLOCK_SIZE=$(sb_field 'Block size')
COUNT=$(sb_field 'Block count')
if [ -z "$COUNT" ] || [ -z "$BLOCK_SIZE" ]; then
  echo "FATAL: cannot read the superblock on $ROOT_PART" >&2
  exit 1
fi

# LOG_SLOT_A is expressed in 4096-byte blocks, and resize2fs takes a count in
# filesystem blocks. The two are only the same number while these agree.
if [ "$BLOCK_SIZE" != "4096" ]; then
  echo "FATAL: filesystem block size is $BLOCK_SIZE, not 4096 -- the slotA offset" >&2
  echo "       would not mean the same thing to resize2fs" >&2
  exit 1
fi

echo "filesystem is $COUNT blocks, ceiling is $LOG_SLOT_A"
if [ "$COUNT" -ge "$LOG_SLOT_A" ]; then
  echo "already at or past the ceiling, nothing to do"
  exit 0
fi

# `run_on_device` rather than dsh: exit status matters here and dsh discards it.
run_on_device() {
  local out rc
  out=$(adb_ exec-out "$* 2>&1; echo EXIT=\$?" | tr -d '\r')
  rc=$(printf '%s\n' "$out" | sed -n 's/^EXIT=//p' | tail -n 1)
  printf '%s\n' "$out" | grep -v '^EXIT=' >&2
  [ -n "$rc" ] || rc=1
  return "$rc"
}

# resize2fs refuses a filesystem it has not seen checked, and the one that was
# just unmounted by a latch has its journal flagged for recovery. 1 means errors
# were found and fixed, which is a pass; 4 and up are uncorrected.
set +e
run_on_device "$E2FSCK" -fp "$ROOT_PART"
rc=$?
set -e
if [ "$rc" -gt 1 ]; then
  echo "FATAL: e2fsck exited $rc -- not resizing a filesystem it could not clean" >&2
  exit 1
fi

run_on_device "$RESIZE2FS" -f "$ROOT_PART" "$LOG_SLOT_A"
dsh sync >/dev/null

FINAL=$(sb_field 'Block count')
if [ "$FINAL" != "$LOG_SLOT_A" ]; then
  echo "FATAL: filesystem reports $FINAL blocks, expected $LOG_SLOT_A" >&2
  exit 1
fi

echo "resized to $FINAL blocks ($((FINAL / 262144)) GiB), ending one block below the log ring"
