# deploy.sh with the transport swapped from adb to ssh over the USB gadget.
#
#     nix run .#dandelion-deploy-ssh -- result-dandelion/system.img
#
# Every invariant of ./deploy.sh is preserved deliberately: chunks are hashed
# before writing so a re-run only pays for what is still wrong, the ext4 magic is
# held at zero for the duration, and chunk 0 -- which carries the superblock -- is
# written last, so an interrupted run re-parks the device in stage-1 rather than
# handing it a valid superblock over a half-written filesystem.
#
# What changes is the reason for existing. adbd wedged mid-deploy with a thread
# stuck in ffs_epfile_io: the gadget stayed CONFIGURED, the host logged no
# disconnect, and one bulk request simply never completed. The RNDIS function on
# the same gadget was unaffected, so dropbear stayed reachable while adbd was
# not. ssh is also the better transport on its own merits -- it reports a real
# exit status, where `adb exec-in` truncates silently, which is the entire reason
# the adb path needs a read-back hash to be trustworthy at all. The hash is kept
# here anyway, because it is what makes a re-run cheap.
#
# The guards below duplicate require_device / require_unmounted_root /
# require_power from ./lib.sh rather than calling them, because those are written
# against `dsh` and there is no transport switch yet. Constants are NOT
# duplicated: DEVICE_ID, ROOT_PART, MAGIC_OFFSET and LOG_SLOT_A all come from the
# preamble, so the one thing that would be dangerous to let drift cannot.
IMG=${1:?usage: dandelion-deploy-ssh /path/to/system.img}
HOST=${HOST:-172.16.42.1}
KEY=${KEY:-$HOME/.ssh/id_ed25519}
CHUNK=8192

# The stage-1 dropbear this talks to is started by the boot image currently
# flashed to the device, not by the one being deployed. Initrds up to the one in
# p2 today bind 22; from the next flash onward stage-1 moves to 2222 so it stops
# starving stage-2's sshd (see ../modules/stage-1-ssh.nix). A deploy that
# straddles that change needs a different port on either side of it, which is why
# this is a knob rather than a constant.
PORT=${PORT:-22}

# One ControlMaster for the whole run: dropbear's handshake costs about a second
# on this A53 and each chunk needs two or three round trips, so without
# multiplexing the handshakes alone outweigh the transfer.
CTL=$(mktemp -u /tmp/dandelion-ssh-XXXXXX)
SSH_OPTS=(
  -p "$PORT"
  -i "$KEY"
  -o IdentitiesOnly=yes
  -o PubkeyAcceptedAlgorithms=+ssh-ed25519
  -o ConnectTimeout=8
  -o Compression=no
  -o ControlMaster=auto
  -o "ControlPath=$CTL"
  -o ControlPersist=600
  # The device regenerates its host key on every stage-1 boot -- dropbear is
  # started with -R precisely so no private key is baked into a world-readable
  # store path -- so a pinned known_hosts entry would be wrong by design here.
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
# SC2029: client-side expansion is the intent, not an accident. Every caller
# builds its command out of host-side values -- the block offset being written,
# $ROOT_PART, $MAGIC_OFFSET -- and the device shell must receive them already
# substituted. Nothing here interpolates a device-side variable, so there is
# nothing that needs to survive to the far end unexpanded.
# shellcheck disable=SC2029
dssh() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }

# SC2329: invoked by the EXIT trap below, which shellcheck does not follow.
# shellcheck disable=SC2329
cleanup() { ssh "${SSH_OPTS[@]}" -O exit "root@$HOST" 2>/dev/null || true; }
trap cleanup EXIT

BYTES=$(stat -Lc %s "$IMG")
if [ $((BYTES % 4096)) -ne 0 ]; then
  echo "FATAL: $IMG is not a whole number of 4096-byte blocks" >&2
  exit 1
fi
TOTAL=$((BYTES / 4096))
echo "image $IMG -> $BYTES bytes, $TOTAL blocks"

# The rootfs and the raw bring-up log share the partition: the log ring starts at
# LOG_SLOT_A, and a filesystem wide enough to reach it destroys the record of the
# boot that is being debugged. autoResize is forced off for the same reason, but
# that only stops the device from growing the filesystem -- it does nothing about
# an image that arrives too wide to begin with.
if [ "$TOTAL" -gt "$LOG_SLOT_A" ]; then
  echo "FATAL: image is $TOTAL blocks, past slotA ($LOG_SLOT_A) -- it would overwrite the log ring" >&2
  exit 1
fi

# The transport identifies nothing: anything answering on $HOST would do, and the
# address is a private one that any other gadget could also claim. The hardware
# serial in /proc/cmdline is the only thing that identifies this phone.
if ! dssh "grep -q $DEVICE_ID /proc/cmdline && echo OK" 2>/dev/null | grep -q OK; then
  echo "FATAL: identity check failed, expected $DEVICE_ID in /proc/cmdline" >&2
  exit 1
fi
echo "identity ok"

# Compared on major:minor rather than on device paths, because stage-2 mounts "/"
# through /dev/disk/by-label and stage-1 by node -- the same partition spelled two
# ways. See require_unmounted_root in ./lib.sh.
want_dev=$(dssh "cat /sys/class/block/${ROOT_PART##*/}/dev" 2>/dev/null | tr -d '\r\n' || true)
if [ -z "$want_dev" ]; then
  echo "FATAL: cannot read major:minor for $ROOT_PART, refusing to write blind" >&2
  exit 1
fi

mounted=$(dssh "cut -d' ' -f3,5 /proc/self/mountinfo" 2>/dev/null | tr -d '\r' | sed -n "s/^$want_dev //p" | tr '\n' ' ' || true)
if [ -n "$mounted" ]; then
  echo "FATAL: $ROOT_PART is mounted on ${mounted% }. Writing it raw would rewrite" >&2
  echo "       the filesystem under the running system. Park the device first:" >&2
  echo "         nix run .#dandelion-latch" >&2
  exit 1
fi
echo "root partition unmounted"

cap=$(dssh 'cat /sys/class/power_supply/battery/capacity' 2>/dev/null | tr -dc '0-9' || true)
if [ -z "$cap" ]; then
  echo "warning: battery capacity unreadable, proceeding without the power check" >&2
else
  echo "battery at ${cap}%"
  if [ "$cap" -lt "${MIN_BATTERY:-40}" ]; then
    echo "FATAL: ${cap}% is under the ${MIN_BATTERY:-40}% this step needs. Charge from a wall" >&2
    echo "       charger -- the latch drains on a PC port. MIN_BATTERY overrides." >&2
    exit 1
  fi
fi

# No /run round trip, unlike deploy.sh's dev_hash: that exists because a hash
# arriving over a transport that just truncated a write proves nothing. ssh does
# not truncate, and a dropped connection is an exit status rather than a short
# read.
dev_hash() {
  dssh "dd if=$ROOT_PART bs=4096 skip=$1 count=$2 2>/dev/null | sha256sum" 2>/dev/null \
    | tr -d '\r' | cut -d' ' -f1
}

do_chunk() {
  local blk=$1 cnt=$2 tag=$3
  local want got try

  want=$(dd if="$IMG" bs=4096 skip="$blk" count="$cnt" 2>/dev/null | sha256sum | cut -d' ' -f1)

  got=$(dev_hash "$blk" "$cnt" || true)
  if [ -n "$got" ] && [ "$got" = "$want" ]; then
    echo "$tag blk=$blk cnt=$cnt already correct, skipped"
    return 0
  fi

  for try in 1 2 3 4 5; do
    if ! dd if="$IMG" bs=4096 skip="$blk" count="$cnt" 2>/dev/null \
      | dssh "dd of=$ROOT_PART bs=4096 seek=$blk conv=notrunc 2>/dev/null"; then
      echo "$tag blk=$blk try=$try transport error during write"
      sleep 3
      continue
    fi

    got=$(dev_hash "$blk" "$cnt" || true)
    if [ -z "$got" ]; then
      echo "$tag blk=$blk try=$try verify returned nothing"
      sleep 3
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

printf '\0\0' | dssh "dd of=$ROOT_PART bs=1 seek=$MAGIC_OFFSET conv=notrunc 2>/dev/null; sync"
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
  dssh 'sync' >/dev/null 2>&1 || true
  echo "magic now: $(dssh "dd if=$ROOT_PART bs=1 skip=$MAGIC_OFFSET count=2 2>/dev/null" 2>/dev/null | od -A n -t x1 | tr -s ' ')"
  echo "WRITE COMPLETE, magic restored"
else
  echo "INCOMPLETE -- magic left at zero, the device will re-park in stage-1; re-run to resume" >&2
fi

exit "$fail"
