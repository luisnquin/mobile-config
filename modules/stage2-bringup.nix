# Keeps adb alive across the stage-1 to stage-2 handoff.
#
# This exists because the first boot that reached stage-2 froze in PID 1 (see
# patches/systemd/0006-*.patch) and left no way to find out why: stage-2 kills
# adbd before starting systemd, so the gadget is gone, and journald never runs.
#
# The other half of that problem -- capturing the kernel log somewhere readable
# afterwards -- is modules/bringup-log, which does not depend on this module
# working, on adb, or on the rootfs being mountable.
#
# Remove this module once the device reaches a session reliably.
{ lib, pkgs, ... }:

{
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
