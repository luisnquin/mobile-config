# Bounds on the two things that grow without one: the journal and the store.
#
# Neither is a theory. Measured on dandelion six hours after a boot, with the
# rootfs at 16 GiB and 9.8 GiB free:
#
#   journalctl --disk-usage        907.6M
#   /nix/store                     4.9G, 23 system generations, no gc timer
#
# The journal figure is not an application logging too much. 380894 of the
# 872463 lines in that boot are kernel, and the top twelve are all MediaTek
# gauge and charger debug output at ~17 lines/s -- see the FG_daemon_log_level
# note in ../devices/xiaomi-dandelion/default.nix for why this kernel logs at
# DEBUG and why no runtime knob turns it off. Until that is fixed in the kernel
# the volume is a given, so the cap is what keeps it off the rootfs.
{
  config,
  lib,
  ...
}: let
  cfg = config.mobile.services.maintenance;
in {
  options.mobile.services.maintenance = {
    enable = lib.mkEnableOption "journal and store size limits";

    journalMaxUse = lib.mkOption {
      type = lib.types.str;
      default = "256M";
      description = ''
        Ceiling for the persistent journal. journald's own default is 10% of the
        filesystem, which on a 16 GiB rootfs is 1.6 GiB.
      '';
    };

    gcOlderThan = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = ''
        Age at which the weekly collection drops a system generation. Must stay
        comfortably above the window in which a rollback is still wanted; the
        deploy guard in ./deploy-guard.nix rolls back to the immediately
        previous generation, which this never reaches.
      '';
    };

    minFree = lib.mkOption {
      type = lib.types.int;
      default = 512 * 1024 * 1024;
      description = ''
        Free space below which the daemon collects garbage mid-operation, up to
        maxFree. This is the one that matters on a deploy: `nix copy` of a large
        closure onto a nearly full p41 otherwise fails partway, leaving a
        generation that cannot be activated.
      '';
    };

    maxFree = lib.mkOption {
      type = lib.types.int;
      default = 2 * 1024 * 1024 * 1024;
      description = "Free space the mid-operation collection stops at.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.journald.extraConfig = ''
      SystemMaxUse=${cfg.journalMaxUse}
      SystemMaxFileSize=32M
      RuntimeMaxUse=32M
    '';

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than ${cfg.gcOlderThan}";
    };

    nix.settings = {
      min-free = cfg.minFree;
      max-free = cfg.maxFree;
    };

    # Deliberately not nix.optimise. Hard-linking a 4.9 GiB store means reading
    # every file in it on a device whose flash the rest of this module exists to
    # spare, to reclaim space that `nix.gc` above already reclaims by deleting
    # whole closures.
  };
}
