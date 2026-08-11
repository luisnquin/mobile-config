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
{pkgs}: let
  layout = import ../modules/bringup-log/layout.nix;

  preamble =
    builtins.replaceStrings
    ["@slotA@" "@slotB@" "@magic@"]
    [(toString layout.slotA) (toString layout.slotB) layout.magic]
    (builtins.readFile ./lib.sh);

  # `extraInputs` rather than one shared list with openssh in it: exactly one of
  # these tools speaks ssh, and the other six would carry the dependency for
  # nothing.
  mkTool' = extraInputs: name: description: script:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs =
        [
          pkgs.android-tools
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
        ]
        ++ extraInputs;
      text = preamble + "\n" + builtins.readFile script;
      meta = {inherit description;};
    };

  mkTool = mkTool' [];

  # No preamble. lib.sh carries dandelion's serial, root partition and log-ring
  # offsets, none of which are marie's; a marie tool that inherited them would
  # guard on the wrong identity. So this builder ships the tool text alone.
  mkBareTool = extraInputs: name: description: script:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs =
        [
          pkgs.android-tools
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
        ]
        ++ extraInputs;
      text = builtins.readFile script;
      meta = {inherit description;};
    };
in {
  dandelion-latch =
    mkTool "dandelion-latch"
    "Catch the stage-1 adb window and park the device there indefinitely"
    ./latch.sh;

  dandelion-unlatch =
    mkTool "dandelion-unlatch"
    "Restore the ext4 magic so the next boot proceeds to stage-2"
    ./unlatch.sh;

  dandelion-log =
    mkTool "dandelion-log"
    "Read the raw bring-up log off the device without mounting anything"
    ./read-log.sh;

  dandelion-deploy =
    mkTool "dandelion-deploy"
    "Write a rootfs image in verified chunks, superblock last"
    ./deploy.sh;

  # The same write over the other transport on the gadget. Kept as a separate
  # tool rather than a flag on dandelion-deploy because the two do not share a
  # failure model: the adb path exists to survive silent truncation, this one
  # exists because adbd can wedge outright with the gadget still CONFIGURED.
  dandelion-deploy-ssh =
    mkTool' [pkgs.openssh] "dandelion-deploy-ssh"
    "Write a rootfs image over ssh, for when adbd has wedged mid-transfer"
    ./deploy-ssh.sh;

  # Separate from dandelion-deploy because it is not part of writing an image:
  # the image is deliberately narrow, and this widens the filesystem afterwards.
  dandelion-resize-rootfs =
    mkTool "dandelion-resize-rootfs"
    "Grow the rootfs offline to the block below the log ring"
    ./resize-rootfs.sh;

  dandelion-verify =
    mkTool "dandelion-verify"
    "Hash the whole rootfs partition on the device and compare it to an image"
    ./verify.sh;

  # Named for the image, not the partition: the default target is `recovery`,
  # because this port boots from there and `boot` is the way back to Android.
  dandelion-flash-bootimg =
    mkTool "dandelion-flash-bootimg"
    "Write a boot image to recovery from the stage-1 shell, where fastboot is unreachable"
    ./flash-bootimg.sh;

  dandelion-reboot =
    mkTool "dandelion-reboot"
    "Reboot via sysrq, which works in stage-1 where adb reboot does not"
    ./reboot.sh;

  # Deliberately separate from dandelion-flash-bootimg, which writes the image
  # but never the thing that decides whether the image is entered: what LK boots
  # next lives in `para`, and clearing it is what makes an untested kernel on
  # `recovery` a single power-cycle away from stock Android instead of a reset
  # loop with no channel.
  dandelion-bcb =
    mkTool "dandelion-bcb"
    "Show, clear or set the boot control block in para, which is what LK boots next"
    ./bcb.sh;

  # The only marie tool, and the only one here that uses fastboot: it reaches
  # the two facts read-only adb cannot -- the bootloader revision, which the OS
  # reports as `unknown`, and whether a locked Huawei bootloader answers at all.
  # gawk for the adb-device parse; strictly getvar and reboot, never a write.
  marie-fastboot-probe =
    mkBareTool [pkgs.gawk] "marie-fastboot-probe"
    "Reboot huawei-marie into its bootloader, dump every getvar it discloses, and reboot back -- read-only, no flash"
    ./marie-fastboot-probe.sh;

  # The only tool here that talks to a booted system rather than to the stage-1
  # latch, and the only one that needs nix on the host side.
  dandelion-switch =
    mkTool' [pkgs.nix pkgs.openssh] "dandelion-switch"
    "Activate a system generation and roll it back unless the device answers afterwards"
    ./switch.sh;
}
