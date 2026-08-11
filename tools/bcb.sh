# Reads and rewrites the Android boot control block in `para`.
#
#     nix run .#dandelion-bcb                      # show
#     nix run .#dandelion-bcb -- clear             # back up, then zero the command
#     nix run .#dandelion-bcb -- set boot-recovery
#
# There is no `misc` partition on this GPT. MediaTek's LK reads the BCB out of
# `para` (p3) instead, and it honours it -- which is why this port re-enters
# stage-1 after every reset without a key combination, and why an image on
# `recovery` that dies before userspace resets into itself forever instead of
# falling back. `clear` is the fallback: with the command field zeroed, the next
# reset lands on `boot` (p33), which still holds stock Android.
#
# That is the whole reason this is a tool and not a line in the README. The
# operation is three dd invocations, and it is the difference between a failed
# kernel costing one power-cycle and costing an mtkclient session over BROM --
# which on this unit does not work. See devices/xiaomi-dandelion/README.md,
# "Trying the mainline arm without losing the device".
#
# Only the first 32 bytes are ever written: `command` in
# bootable/recovery/bootloader_message. `status`, `recovery` and the stage
# fields after it are left alone, because nothing here knows what LK put in
# them.
ACTION=${1:-show}

BACKUP_DIR=${BCB_BACKUP_DIR:-$HOME/.local/state/dandelion}

require_device
echo "identity ok"

DEV=$(resolve_partition para || true)
case "$DEV" in
  /dev/block/mmcblk0p[0-9]* | /dev/mmcblk0p[0-9]*) ;;
  *)
    echo "FATAL: 'para' resolved to '${DEV:-<nothing>}', refusing to touch it" >&2
    exit 1
    ;;
esac
echo "para -> $DEV"

# The command field is NUL-padded, so the printable prefix is the command and a
# field of all zeroes is the cleared state. Both spellings are shown because a
# partially-overwritten field is neither, and that is worth seeing.
show_bcb() {
  local raw
  raw=$(adb_ exec-out "dd if=$DEV bs=32 count=1 2>/dev/null" | od -A n -t x1 | tr -s ' ')
  if [ -z "$(printf '%s' "$raw" | tr -d ' ')" ]; then
    echo "FATAL: read nothing back from $DEV" >&2
    exit 1
  fi
  echo "command bytes:$raw"
  printf 'command text: %s\n' "$(adb_ exec-out "dd if=$DEV bs=32 count=1 2>/dev/null" | tr -d '\0')"
}

# Refuses to write without a backup on disk first. The BCB is 32 bytes and the
# device cannot be asked what used to be in them.
backup_bcb() {
  local out
  mkdir -p -- "$BACKUP_DIR"
  out="$BACKUP_DIR/para-bcb-$(date -u +%Y%m%dT%H%M%SZ).bin"
  adb_ exec-out "dd if=$DEV bs=4096 count=1 2>/dev/null" > "$out"
  if [ "$(stat -Lc %s "$out")" -ne 4096 ]; then
    echo "FATAL: backup is $(stat -Lc %s "$out") bytes, not 4096. Not writing." >&2
    exit 1
  fi
  echo "backed up the first 4096 bytes of para -> $out"
}

# Read back and compare rather than trust the write: this is the one field that
# decides what the device boots next, and a silently dropped adb write here is
# indistinguishable from success until the reset.
write_bcb() {
  local want got
  want=$1
  dd bs=32 count=1 conv=sync 2>/dev/null \
    | adb_ exec-in "dd of=$DEV bs=32 count=1 conv=notrunc 2>/dev/null; sync"

  got=$(adb_ exec-out "dd if=$DEV bs=32 count=1 2>/dev/null" | tr -d '\0')
  if [ "$got" != "$want" ]; then
    echo "FATAL: read back '$got', wanted '$want'. The BCB is now unknown --" >&2
    echo "       restore the backup before rebooting." >&2
    exit 1
  fi
}

case "$ACTION" in
  show)
    show_bcb
    ;;

  clear)
    show_bcb
    backup_bcb
    printf '' | write_bcb ''
    echo "BCB CLEARED -- the next reset boots 'boot' (stock Android), not 'recovery'"
    ;;

  set)
    # Restricted to the two commands LK is known to act on here. A typo in this
    # field is not inert: LK acts on what it recognises and ignores the rest, so
    # a misspelled `boot-recovery` reads as a successful write and boots Android.
    CMD=${2:?usage: dandelion-bcb set boot-recovery|bootonce-bootloader}
    case "$CMD" in
      boot-recovery | bootonce-bootloader) ;;
      *)
        echo "FATAL: refusing to write '$CMD'. Known commands on this device are" >&2
        echo "       boot-recovery and bootonce-bootloader." >&2
        exit 1
        ;;
    esac

    show_bcb
    backup_bcb
    printf '%s' "$CMD" | write_bcb "$CMD"
    echo "BCB SET to '$CMD'"
    ;;

  *)
    echo "usage: dandelion-bcb [show|clear|set <command>]" >&2
    exit 1
    ;;
esac
