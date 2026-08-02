# Writes a rootfs image to the device in verified chunks.
#
#     nix run .#dandelion-deploy -- result-dandelion/system.img
#
# Two properties are load-bearing and neither is obvious:
#
# 1. `adb exec-in` silently truncates bulk streams, so every chunk is hashed on
#    the device after writing. The two failure modes must not be conflated: a
#    wrong hash means truncation and the chunk is rewritten, while EMPTY output
#    means adbd dropped the transport and the data is not known to be bad. 64 MiB
#    chunks killed adbd partway through; 32 MiB has run clean.
#
# 2. The ext4 magic is zeroed first and chunk 0 is written LAST. The superblock
#    lives at byte 1080, inside chunk 0, so writing that chunk first would hand
#    stage-1 a valid superblock describing a half-written filesystem -- and an
#    interrupted run is the expected case, not the exceptional one. That happened
#    once: the device booted the corpse and froze. With the magic held at zero
#    until everything else verifies, an interruption re-parks the device in
#    stage-1 and this command can simply be run again.
#
# Chunks are hashed before writing, so a re-run only pays for what is still
# wrong. After a rebuild that shifts filesystem layout that may be most of the
# image; after an interrupted write it is usually very little.
IMG=${1:?usage: dandelion-deploy /path/to/system.img}
CHUNK=8192

BYTES=$(stat -Lc %s "$IMG")
if [ $((BYTES % 4096)) -ne 0 ]; then
  echo "FATAL: $IMG is not a whole number of 4096-byte blocks" >&2
  exit 1
fi
TOTAL=$((BYTES / 4096))
echo "image $IMG -> $BYTES bytes, $TOTAL blocks"

dev_hash() {
  # Written to /run and read back separately: a hash that arrives truncated over
  # the same transport that just truncated a write is not evidence of anything.
  dsh "dd if=$ROOT_PART bs=4096 skip=$1 count=$2 2>/dev/null | sha256sum > /run/c.sha; cat /run/c.sha" \
    | cut -d' ' -f1
}

do_chunk() {
  local blk=$1 cnt=$2 tag=$3
  local want got try

  want=$(dd if="$IMG" bs=4096 skip="$blk" count="$cnt" 2>/dev/null | sha256sum | cut -d' ' -f1)

  wait_device || { echo "$tag: device gone" >&2; return 1; }
  got=$(dev_hash "$blk" "$cnt" || true)
  if [ -n "$got" ] && [ "$got" = "$want" ]; then
    echo "$tag blk=$blk cnt=$cnt already correct, skipped"
    return 0
  fi

  for try in 1 2 3 4 5; do
    wait_device || { echo "$tag: device gone" >&2; return 1; }
    dd if="$IMG" bs=4096 skip="$blk" count="$cnt" 2>/dev/null \
      | adb_ exec-in "dd of=$ROOT_PART bs=4096 seek=$blk conv=notrunc 2>/dev/null" || true

    wait_device || { echo "$tag: device gone before verify" >&2; return 1; }
    got=$(dev_hash "$blk" "$cnt" || true)

    if [ -z "$got" ]; then
      echo "$tag blk=$blk try=$try verify returned nothing, transport dropped"
      continue
    fi
    if [ "$got" = "$want" ]; then
      echo "$tag blk=$blk cnt=$cnt OK (try $try)"
      return 0
    fi
    echo "$tag blk=$blk cnt=$cnt MISMATCH try=$try want=${want:0:12} got=${got:0:12}"
  done

  echo "$tag FAILED after 5 tries" >&2
  return 1
}

require_device
echo "identity ok"

magic_zero
echo "magic zeroed for the duration of the write"

blk=$CHUNK
n=1
fail=0
while [ "$blk" -lt "$TOTAL" ]; do
  cnt=$CHUNK
  rem=$((TOTAL - blk))
  [ "$rem" -lt "$CHUNK" ] && cnt=$rem

  if ! do_chunk "$blk" "$cnt" "chunk $n"; then
    fail=1
    break
  fi

  blk=$((blk + cnt))
  n=$((n + 1))
done

if [ "$fail" -eq 0 ]; then
  echo "trailing chunks done, writing chunk 0 -- this restores the superblock"
  do_chunk 0 "$CHUNK" "chunk 0" || fail=1
fi

if [ "$fail" -eq 0 ]; then
  dsh 'sync' >/dev/null || true
  echo "WRITE COMPLETE, magic restored"
else
  echo "INCOMPLETE -- magic left at zero, the device will re-park in stage-1; re-run to resume" >&2
fi

exit "$fail"
