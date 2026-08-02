# Bring-up instrumentation for stage-2. Both entries here exist because the
# first boot that reached stage-2 froze in PID 1 (see
# patches/systemd/0006-*.patch) and left no way to find out why: stage-2 kills
# adbd before starting systemd, so the gadget is gone, and journald never runs.
# Remove this module once the device reaches a session reliably.
{ lib, pkgs, ... }:

{
  # `pkill -x adbd` in mobile-nixos/modules/adb.nix runs from
  # boot.postBootCommands, so by the time systemd starts there is no USB and no
  # console reader. systemd.log_target=kmsg puts PID 1's own output in the ring
  # buffer, which is volatile: pstore and /proc/last_kmsg do not survive a power
  # cut on this SoC, despite CONFIG_MTK_RAM_CONSOLE/PSTORE_RAM being set. So
  # snapshot the buffer to the rootfs and sync, which bounds what a hard
  # power-cycle can lose to one interval.
  #
  # mkAfter so this lands after adb.nix's pkill rather than racing it.
  #
  # The loop is bounded: it costs a flash write every 2s, which is acceptable
  # while bringing the port up and not acceptable to leave running.
  boot.postBootCommands = lib.mkAfter ''
    ${pkgs.coreutils}/bin/echo "kmsg-capture starting at $(${pkgs.coreutils}/bin/cat /proc/uptime)" > /var/kmsg-capture.marker
    ${pkgs.coreutils}/bin/sync
    (
      i=0
      while [ $i -lt 180 ]; do
        ${pkgs.util-linux}/bin/dmesg > /var/kmsg.log.new 2>/dev/null
        ${pkgs.coreutils}/bin/mv -f /var/kmsg.log.new /var/kmsg.log
        ${pkgs.coreutils}/bin/cat /proc/uptime > /var/kmsg.uptime
        ${pkgs.coreutils}/bin/sync
        ${pkgs.coreutils}/bin/sleep 2
        i=$((i + 1))
      done
    ) </dev/null >/dev/null 2>&1 &
  '';

  # NixOS runs `script` under `set -e`. mobile-nixos/modules/adb.nix:64 calls
  # `gt enable $gadget` and then `wait`s on adbd, so any refusal from the UDC
  # write -- EBUSY if something re-bound the gadget, ENODEV if functionfs is not
  # ready yet -- exits before the `wait` and makes systemd tear down the cgroup,
  # taking adbd with it. Losing adb is losing the only access channel, so the
  # enable is allowed to fail and say so.
  #
  # The unquoted `test -n $gadget/UDC` upstream is always true, so the enable is
  # unconditional. That is kept, deliberately: adbd's exit unbinds the gadget
  # (`configfs_composite_unbind` in dmesg), so re-enabling on every start is the
  # wanted behaviour. Only the fatality changes, not the logic.
  systemd.services.adbd.script = lib.mkForce ''
    ${pkgs.adbd}/bin/adbd &

    # functionfs must already be serviced when the gadget is enabled, or the
    # UDC write returns ENODEV.
    sleep 1

    if [ -e /sys/kernel/config/usb_gadget ]; then
      cd /sys/kernel/config/usb_gadget
      for gadget in * ; do
        if ! ${pkgs.gadget-tool}/bin/gt enable "$gadget"; then
          echo "gt enable $gadget failed, leaving adbd running anyway" >&2
        fi
      done
    fi

    wait
  '';
}
