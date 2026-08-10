# Firmware blobs lifted out of the stock `vendor` partition.
#
# The mt6765 connectivity driver ships no firmware of its own: `wlanProbe`
# registers the chip and then asks the firmware loader for
# `WIFI_RAM_CODE_soc1_0_1_1.bin` and the `soc1_0_*_hdr.bin` patches when the
# interface is first brought up. Without them a built-in driver is a driver that
# fails at `ip link set wlan0 up`, which looks exactly like not having built it.
#
# The blobs are proprietary and this repository is public, so they are not in it.
# `requireFile` is the nixpkgs mechanism for exactly that: evaluation fails with
# the message below until the tarball is in the store, and once it is, the build
# is as reproducible as any other.
#
# Extracting them touches nothing. `vendor` lives inside the stock `super`
# (mmcblk0p38) as a dynamic partition, its first extent starts at byte
# 1167609856, and the ext4 filesystem there is 433831936 bytes -- it ends inside
# that first extent, so the other five need not be reassembled. Mounted
# `ro,noload` over a read-only loop device, no journal is replayed and no write
# reaches the partition:
#
#     losetup -r -o 1167609856 --sizelimit 433831936 -f --show /dev/mmcblk0p38
#     mount -o ro,noload /dev/loop0 /run/vendor-ro
#     tar -C /run/vendor-ro -cf - firmware etc/wifi
#     umount /run/vendor-ro && losetup -d /dev/loop0
#
# The offsets come from the LP metadata at the head of `super`: geometry magic
# `gDla` at 4096, the metadata header at 12288, and the partition and extent
# tables after it. They are specific to this unit's flash and should be re-read
# rather than trusted if the device is ever repartitioned.
#
# Repack deterministically before hashing, or the hash below tracks readdir
# order rather than content:
#
#     tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
#         --format=gnu -C <extracted> -cf dandelion-vendor-firmware.tar firmware etc
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.hardware.vendorFirmware;

  blob = pkgs.requireFile {
    name = "dandelion-vendor-firmware.tar";
    sha256 = "5b01816a6c3a04eb9f805025aa1720f57cfde4d385eca4f7b1319a19fe28b8a9";
    message = ''
      Firmware from the stock `vendor` partition of a Xiaomi Redmi 9A
      (dandelion) is required and cannot be redistributed here.

      Extract it from the device itself, as documented at the top of
      modules/vendor-firmware.nix -- the procedure is read-only -- then:

          nix-store --add-fixed sha256 dandelion-vendor-firmware.tar
    '';
  };

  # stdenvNoCC: nothing here is compiled, and the cross toolchain would
  # otherwise be dragged in to run `tar`.
  firmware = pkgs.stdenvNoCC.mkDerivation {
    name = "dandelion-vendor-firmware";
    src = blob;
    dontUnpack = true;

    # Flattened out of `firmware/`, because that is how the driver asks for them:
    # request_firmware() takes a bare name and the loader prefixes its own search
    # path. The `etc/wifi/` entries in the tarball are Android supplicant
    # overlays and are deliberately not installed.
    # WMT_STEP.cfg is not on the stock vendor partition either, but asking for a
    # file that is not there is not free: this kernel sets
    # CONFIG_FW_LOADER_USER_HELPER_FALLBACK, so request_firmware() falls back to
    # a userspace helper that nothing answers and blocks for its full 60 s
    # timeout. Measured on a clean boot: the direct load fails at t=32.8 and
    # `wmt_step_read_file` reports the miss at t=93.2, delaying the entire
    # connectivity bring-up by that gap.
    #
    # STEP is a debug facility -- register pokes at named power-on trigger
    # points -- so the correct content is none. `wmt_step_parse_data()` splits on
    # "\r\n" and hands each line to a parser that ignores anything without a
    # known keyword, so one newline is a valid file describing zero actions.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/firmware
      tar -C $out/lib/firmware --strip-components=1 -xf $src firmware
      printf '\n' > $out/lib/firmware/WMT_STEP.cfg
      runHook postInstall
    '';

    meta.license = lib.licenses.unfree;
  };
in {
  options.mobile.hardware.vendorFirmware.enable =
    lib.mkEnableOption "firmware extracted from the stock vendor partition";

  config = lib.mkIf cfg.enable {
    # Narrower than `allowUnfree`: these blobs came off the device's own flash,
    # and nothing else in the closure gets a pass because of them. Two names,
    # because `requireFile` marks the tarball unfree in its own right and the
    # check runs on it before the derivation that unpacks it.
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [
        "dandelion-vendor-firmware"
        "dandelion-vendor-firmware.tar"
      ];

    hardware.firmware = [firmware];

    # The kernel's `firmware_class.path` is pointed at the store by NixOS and
    # covers request_firmware(). Parts of this vendor tree do not use it -- they
    # filp_open("/vendor/firmware/<name>") directly, and the boot command line
    # still carries `firmware_class.path=/vendor/firmware` from the stock
    # lineage. A symlink satisfies both readings for the cost of one inode.
    systemd.tmpfiles.rules = [
      "d /vendor 0755 root root -"
      "L+ /vendor/firmware - - - - ${firmware}/lib/firmware"
    ];
  };
}
