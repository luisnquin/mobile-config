# Reads the newer of the two raw log slots. The payload goes to stdout and
# everything else to stderr, so this composes:
#
#     nix run .#dandelion-log > stage2.log
#
# No mount, no filesystem, no journal replay. Works with the latch armed, which
# is the only state in which there is unlimited time to read anything.
require_device

best_slot=""
best_seq=-1
best_bytes=0

for slot in "$LOG_SLOT_A" "$LOG_SLOT_B"; do
  header=$(log_header "$slot" || true)

  case "$header" in
    "$LOG_MAGIC "*) ;;
    *)
      echo "slot $slot: no valid header" >&2
      continue
      ;;
  esac

  seq=$(log_field "$header" seq || true)
  bytes=$(log_field "$header" bytes || true)
  uptime=$(log_field "$header" uptime || true)
  echo "slot $slot: seq=${seq:-?} uptime=${uptime:-?}s bytes=${bytes:-?}" >&2

  if [ "${seq:-0}" -gt "$best_seq" ]; then
    best_seq=${seq:-0}
    best_slot=$slot
    best_bytes=${bytes:-0}
  fi
done

if [ -z "$best_slot" ]; then
  echo "no readable log slot -- stage-2 never got far enough to write one" >&2
  exit 1
fi

if [ "$best_bytes" -le 0 ]; then
  echo "slot $best_slot is the newest but carries no payload" >&2
  exit 1
fi

echo "reading slot $best_slot (seq $best_seq, $best_bytes bytes)" >&2

blocks=$(( (best_bytes + 4095) / 4096 ))
adb_ exec-out "dd if=$ROOT_PART bs=4096 skip=$((best_slot + 1)) count=$blocks 2>/dev/null" \
  | head -c "$best_bytes"
