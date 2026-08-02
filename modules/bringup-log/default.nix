# Writes the kernel ring buffer to a raw offset inside the rootfs partition, so
# a stage-2 that never reaches a shell can still be read afterwards.
#
# This replaces an earlier capture that wrote /var/kmsg.log. That one needed the
# rootfs mounted to be read, and reading it meant restoring the ext4 magic,
# mounting, copying, unmounting and re-zeroing the magic -- five steps, each of
# which can fail, to read one file. Writing past the end of the filesystem makes
# the read a single `dd` that works with the partition unmountable, which is the
# state the device is normally in when there is time to look.
#
# See ./layout.nix for where it lands and why, including the constraint it puts
# on ever resizing the rootfs.
{ config, lib, pkgs, ... }:

let
  cfg = config.mobile.bringup.rawLog;
  layout = import ./layout.nix;
in
{
  options.mobile.bringup.rawLog = {
    enable = lib.mkEnableOption "raw-offset kernel log capture for bring-up";

    device = lib.mkOption {
      type = lib.types.str;
      description = ''
        Block device holding the log slots. This is the rootfs partition
        itself: the slots sit past the end of its filesystem.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Seconds between snapshots.";
    };

    iterations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Number of snapshots before the writer exits. Bounded on purpose: this
        costs a flash write per interval, which is acceptable while bringing a
        port up and not acceptable to leave running forever.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Not a systemd service, deliberately. The failure this exists to diagnose
    # is PID 1 freezing in mount_setup() before any unit runs, so anything
    # systemd owns is unable to observe it. boot.postBootCommands is the last
    # code that runs from stage-2 init before `exec systemd`, which makes it the
    # only place a capture can start and still survive into a systemd that never
    # starts anything.
    #
    # mkAfter so it lands after mobile-nixos/modules/adb.nix's `pkill -x adbd`
    # rather than racing it.
    boot.postBootCommands = lib.mkAfter ''
      (
        dev=${cfg.device}
        tmp=/run/bringup-log.payload
        seq=0
        i=0

        # Invalidate both headers before writing anything. `seq` restarts at 1
        # every boot, so without this the reader compares this boot's seq=1
        # against the previous boot's seq=300 and returns the previous boot's
        # log as the newer one -- silently, and with a plausible-looking uptime.
        # A slot with no valid header reads as "stage-2 never got this far",
        # which is the true statement.
        for slot in ${toString layout.slotA} ${toString layout.slotB}; do
          ${pkgs.coreutils}/bin/head -c 4096 /dev/zero \
            | ${pkgs.coreutils}/bin/dd of="$dev" bs=4096 seek="$slot" \
                conv=notrunc,fsync 2>/dev/null || true
        done

        while [ $i -lt ${toString cfg.iterations} ]; do
          seq=$((seq + 1))
          if [ $((seq % 2)) -eq 1 ]; then
            slot=${toString layout.slotA}
          else
            slot=${toString layout.slotB}
          fi

          ${pkgs.util-linux}/bin/dmesg 2>/dev/null \
            | ${pkgs.coreutils}/bin/head -c ${toString (layout.payloadBlocks * 4096)} > "$tmp" || true
          bytes=$(${pkgs.coreutils}/bin/stat -c %s "$tmp" 2>/dev/null || echo 0)
          uptime=$(${pkgs.coreutils}/bin/cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)

          # Payload before header, for the same reason tools/deploy.sh writes
          # chunk 0 last: the header is what makes a slot readable, so it must
          # not become valid until what it describes is already on flash. A
          # power cut between the two writes leaves a stale-but-consistent slot
          # rather than a header pointing at a half-written snapshot.
          ${pkgs.coreutils}/bin/dd if="$tmp" of="$dev" bs=4096 \
            seek=$((slot + 1)) conv=notrunc,fsync 2>/dev/null || true
          ${pkgs.coreutils}/bin/printf '${layout.magic} seq=%d uptime=%s bytes=%d\n' \
            "$seq" "$uptime" "$bytes" \
            | ${pkgs.coreutils}/bin/dd of="$dev" bs=4096 \
                seek="$slot" conv=notrunc,fsync 2>/dev/null || true

          ${pkgs.coreutils}/bin/sleep ${toString cfg.interval}
          i=$((i + 1))
        done
      ) </dev/null >/dev/null 2>&1 &
    '';
  };
}
