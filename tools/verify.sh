# Hashes the whole rootfs partition on the device and compares it to an image.
#
#     nix run .#dandelion-verify -- result-dandelion/system.img
#
# Independent of the per-chunk verification the deploy does: caches are dropped
# first, so this reads the eMMC rather than the page cache. Worth running once
# after a deploy, because every chunk hash and the write it checked travelled
# over the same transport.
IMG=${1:?usage: dandelion-verify /path/to/system.img}

BYTES=$(stat -Lc %s "$IMG")
BLOCKS=$((BYTES / 4096))
WANT=$(sha256sum "$IMG" | cut -d' ' -f1)
echo "image  $IMG"
echo "blocks $BLOCKS"
echo "want   $WANT"

require_device
dsh 'sync; echo 3 > /proc/sys/vm/drop_caches' >/dev/null || true

for try in 1 2 3; do
  echo "hashing the partition on the device (try $try), this takes a few minutes"
  dsh "dd if=$ROOT_PART bs=4096 count=$BLOCKS 2>/dev/null | sha256sum > /run/full.sha" >/dev/null || true
  got=$(dsh 'cat /run/full.sha' | cut -d' ' -f1 || true)

  if [ -z "$got" ]; then
    echo "try $try: empty result, transport dropped"
    sleep 5
    continue
  fi
  echo "got    $got"
  if [ "$got" = "$WANT" ]; then
    echo "MATCH"
    exit 0
  fi
  echo "MISMATCH" >&2
  exit 1
done

echo "FAILED: could not read a hash off the device" >&2
exit 1
