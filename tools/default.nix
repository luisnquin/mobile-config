# Host-side device operations, as flake apps.
#
# These were shell scripts in /tmp for most of this port's life, which cost
# real work twice: nix-gc wipes /tmp on the same run that collects the store, so
# the scripts and the image they existed to write disappeared together. More
# importantly they carry the operational knowledge that is expensive to
# rediscover -- chunk 0 written last, truncation versus transport death, the
# by-name guard on the boot partition -- and that belongs under review like any
# other part of the port.
#
# The log offsets come from ../modules/bringup-log/layout.nix, the same file the
# device-side writer uses, so the reader cannot drift from the writer.
{ pkgs }:

let
  layout = import ../modules/bringup-log/layout.nix;

  preamble = builtins.replaceStrings
    [ "@slotA@" "@slotB@" "@magic@" ]
    [ (toString layout.slotA) (toString layout.slotB) layout.magic ]
    (builtins.readFile ./lib.sh);

  mkTool = name: description: script: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [
      pkgs.android-tools
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = preamble + "\n" + builtins.readFile script;
    meta = { inherit description; };
  };
in
{
  dandelion-latch = mkTool "dandelion-latch"
    "Catch the stage-1 adb window and park the device there indefinitely"
    ./latch.sh;

  dandelion-unlatch = mkTool "dandelion-unlatch"
    "Restore the ext4 magic so the next boot proceeds to stage-2"
    ./unlatch.sh;

  dandelion-log = mkTool "dandelion-log"
    "Read the raw bring-up log off the device without mounting anything"
    ./read-log.sh;

  dandelion-deploy = mkTool "dandelion-deploy"
    "Write a rootfs image in verified chunks, superblock last"
    ./deploy.sh;

  dandelion-verify = mkTool "dandelion-verify"
    "Hash the whole rootfs partition on the device and compare it to an image"
    ./verify.sh;

  # Named for the image, not the partition: the default target is `recovery`,
  # because this port boots from there and `boot` is the way back to Android.
  dandelion-flash-bootimg = mkTool "dandelion-flash-bootimg"
    "Write a boot image to recovery from the stage-1 shell, where fastboot is unreachable"
    ./flash-bootimg.sh;

  dandelion-reboot = mkTool "dandelion-reboot"
    "Reboot via sysrq, which works in stage-1 where adb reboot does not"
    ./reboot.sh;
}
