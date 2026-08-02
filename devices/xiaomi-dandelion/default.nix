# Xiaomi Redmi 9A (dandelion), M2006C3LG, MT6762G.
#
# The boot image geometry below started from Droidian's
# debian-dandelion/kernel-info.mk and was then checked against the stock
# boot.img from V12.0.22.0.QCDMIXM. Two things changed as a result:
# offset_second and the dtb section format, both annotated below.
{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/soc/mt6765.nix
    ../../modules/systemd-linux-4.9.nix
    ../../modules/stage2-build-fixes.nix
    ../../modules/stage2-bringup.nix
    ../../modules/bringup-log
    ../../modules/stage-1-ssh.nix
    ../../modules/session.nix
    ../../modules/sxmo.nix
    ../../modules/tailscale.nix
    ../../modules/usb-network.nix
    ./display.nix
  ];

  # Mode 1: stage-2 boots to an autologin shell on tty1, and `sxmo_xinit.sh`
  # from that shell starts the session by hand.
  # Mode 2, selected here: tty1's login shell execs it at boot.
  #
  # Mode 2 rather than the module default, because this unit has no keyboard.
  # Mode 1 assumes someone can type on the panel, and the only USB port is
  # occupied by the gadget that carries adb and ssh -- an OTG keyboard would
  # take the session's own lifeline. The tty1 guard in modules/sxmo.nix means
  # ssh still lands on a plain shell either way.
  mobile.session.sxmo.enable = true;
  mobile.session.graphical.autostart = true;

  # Enrolled by hand. Wi-Fi on this device is still untested, so the daemon has
  # no route out yet -- it will sit in NeedsLogin until one exists.
  mobile.services.tailscale.enable = true;

  # Until wifi works this is the only way to reach stage-2 over the network.
  mobile.services.usbNetwork.enable = true;

  # Names this physical unit, not the port. A second Redmi 9A would get its own.
  networking.hostName = "thompson";

  system.stateVersion = "26.11";

  mobile.device.name = "xiaomi-dandelion";
  mobile.device.identity = {
    name = "Redmi 9A";
    manufacturer = "Xiaomi";
  };

  # The rootfs is written and verified and stage-2 does start, but PID 1 has
  # never reached a service manager: it froze in mount_setup() (see
  # patches/systemd/0006-*.patch, which is the attempt to fix that and has not
  # been tested on hardware yet). This stays "broken" until a boot reaches a
  # login prompt.
  mobile.device.supportLevel = "broken";

  mobile.hardware = {
    soc = "mediatek-mt6765";
    ram = 1024 * 2;
    screen = {
      # CONFIG_LCM_WIDTH / CONFIG_LCM_HEIGHT in dandelion_halium_defconfig.
      width = 720;
      height = 1600;
    };
  };

  mobile.boot.stage-1.kernel = {
    package = pkgs.callPackage ./kernel { };
    # Every driver on the boot path is built in; the initrd loads nothing.
    modular = false;
  };

  mobile.system.type = "android";
  mobile.system.android = {
    device_name = "dandelion";

    # Non-A/B with a dedicated recovery partition. That partition is the early
    # test boundary: it can be written while stock `boot` stays intact, which
    # keeps Android as the fallback.
    ab_partitions = false;
    has_recovery_partition = true;

    # There is no static `system` partition on this device: Android's system
    # lives in dynamic `super` (p38), which a bootloader-fastboot `flash` cannot
    # address and which AGENTS.md puts out of bounds during bring-up. `userdata`
    # (p41) is a real GPT partition of 23782383 KiB, so it takes a plain
    # fastboot write and has room to spare. Writing it destroys Android's user
    # data, which is authorized.
    system_partition_destination = "userdata";

    flashingMethod = "fastboot";

    # All values from the kernel tree @ d31e916b,
    # debian-dandelion/kernel-info.mk, then checked against the header of the
    # stock boot.img extracted from V12.0.22.0.QCDMIXM. Every one matches except
    # offset_second — see below.
    bootimg.flash = {
      offset_base    = "0x40078000";
      offset_kernel  = "0x00008000";
      offset_ramdisk = "0x11a88000";
      # Stock's second_addr is 0x40f00000, i.e. this offset against the base
      # above. kernel-info.mk's 0x80f78000 would put it at 0xc0ff0000, which is
      # not what this bootloader was shipped with.
      #
      # Inert in practice: second_size is 0 in both images, so nothing is loaded
      # there. Corrected anyway, because gate 3 asks for stock-compatible
      # geometry and an unexplained difference is a variable that costs nothing
      # to remove before a first boot.
      offset_second  = "0x00e88000";
      offset_tags    = "0x07808000";
      pagesize       = "2048";
    };

    # Header v2 carries the base device tree inside the boot image. The
    # dandelion overlay stays in the stock `dtbo` partition and is applied by
    # the bootloader, so this port does not have to write `dtbo` at all.
    bootimg.header_version = "2";

    # Stock carries the device tree in *two* places, and the first three boot
    # attempts only reproduced one of them.
    #
    # The kernel section of stock boot.img and recovery.img is a gzip stream
    # with a bare FDT concatenated after it -- the `Image.gz-dtb` convention.
    # The vendor defconfig names it outright:
    #
    #   kernel/config.aarch64:512
    #     CONFIG_BUILD_ARM64_APPENDED_KERNEL_IMAGE_NAME="Image.gz-dtb"
    #
    # Measured in both stock images: 9953225-byte kernel section = one gzip
    # member decompressing to 28280852 bytes, then 97418 trailing bytes whose
    # SHA-256 (d7248e0c...) is byte-identical to the FDT inside the header-v2
    # dt_table below. The candidate had zero trailing bytes.
    #
    # A kernel entered without a device tree dies in early setup_arch, long
    # before any console exists, and MediaTek's LK watchdog then resets the SoC.
    # That is the observed failure exactly: Xiaomi logo held on the panel for
    # the whole window and `HWT` at ~30s, three times, unchanged by the ramdisk
    # codec. Which of the two locations LK actually reads is still unknown, so
    # both are populated, as stock does.
    appendDTB = [
      "${config.mobile.boot.stage-1.kernel.package}/dtbs/mediatek/mt6765.dtb"
    ];

    # Not the bare `mt6765.dtb`. Stock does not put a bare FDT in this section:
    # it puts a dt_table container -- magic 0xd7b7ab1e, the same format as
    # dtbo.img -- holding the tree as entry 0. Verified by reading the stock
    # boot.img extracted from V12.0.22.0.QCDMIXM:
    #
    #   dt_table_header at 10713088
    #     magic d7b7ab1e   total_size 97482   header_size 32
    #     dt_entry_size 32   dt_entry_count 1   page_size 2048   version 0
    #     entry[0] size 97418  offset 64  id 0  rev 0
    #
    # An earlier revision of this comment asserted that this section is what
    # MediaTek's LK reads to find the device tree. That was never established --
    # stock populates this section *and* appends the same FDT to the kernel (see
    # appendDTB above), so shipping only this one is not what the bootloader was
    # given. Which of the two LK consults is still unknown. The arguments below
    # reproduce the structure above; mkdtboimg's defaults give header_size 32,
    # dt_entry_size 32, page_size 2048 and version 0.
    bootimg.dtb = pkgs.runCommand "dandelion-mt6765-dt-table.img" {
      nativeBuildInputs = [ pkgs.buildPackages.android-tools ];
    } ''
      mkdtboimg create "$out" --id=0 --rev=0 \
        ${config.mobile.boot.stage-1.kernel.package}/dtbs/mediatek/mt6765.dtb
    '';
    # kernel-info.mk sets DTB_OFFSET and TAGS_OFFSET to the same value.
    bootimg.offset_dtb = "0x07808000";
  };

  # `bootopt` is read by MediaTek's preloader/LK, not by Linux, and the stock
  # boot image carries it. `buildvariant` is consumed by the Android init this
  # port replaces; it is kept because dropping arguments the bootloader chain
  # may parse is a second variable to change at once.
  boot.kernelParams = [
    "bootopt=64S3,32N2,64N2"
    "buildvariant=user"

    # `earlycon` is deliberately absent, and so is the chosen/stdout-path patch
    # that used to accompany it in the kernel derivation. Together they are why
    # this port did not boot; apart, either is harmless. Nine boot attempts
    # separated them, the last four against a repacked stock recovery image
    # known to boot:
    #
    #   dtb       cmdline                              result
    #   stock     stock                                boots
    #   stock     candidate, earlycon included         boots
    #   candidate stock                                boots
    #   candidate candidate                            HWT at ~30 s
    #   candidate stock + earlycon, nothing else       HWT at ~44 s
    #
    # A bare `earlycon` resolves its device through chosen/stdout-path. Stock's
    # tree has none, so on stock it finds nothing and does nothing -- which is
    # why it looked free. The patch supplied one pointing at /serial@11020000
    # (reg 0x11002000; the node itself is byte-identical to stock's), so the
    # kernel mapped and wrote MT6765 UART0 before the clock subsystem existed.
    # LK leaves that clock gated on a user build, and an APB access to a gated
    # block hangs the bus with no console alive to report it. LK's watchdog
    # collects it ~30 s later. That is every failed attempt in this port's
    # history, exactly.
    #
    # Do not re-add it to chase an early-boot problem. It is the early-boot
    # problem. `earlycon=mtk8250,mmio32,0x11002000,921600n1` is not an escape
    # either: that form needs EARLYCON_DECLARE, compiled only under
    # CONFIG_FPGA_EARLY_PORTING, which this defconfig does not set -- and it
    # would touch the same gated register anyway.

    # Mobile NixOS puts `loglevel=4` on the cmdline, which drops KERN_INFO and
    # below — i.e. most of what a bring-up needs to see. This overrides it for
    # every console. The screen is the only observation channel this port has
    # (CONFIG_FRAMEBUFFER_CONSOLE=y in the built kernel, `console=tty1` last on
    # this command line), and it is only useful if something is printed on it.
    # Remove once the port boots.
    "ignore_loglevel"

    # Stage-2 has no observation channel of its own. systemd's default log
    # target is the journal, and the journal is unreadable while the boot it
    # describes is still hanging. Routing PID 1 through /dev/kmsg instead puts
    # it in the kernel ring buffer, where mobile.bringup.rawLog can copy it to a
    # raw offset on p41 every two seconds.
    #
    # Not pstore: CONFIG_MTK_RAM_CONSOLE, CONFIG_PSTORE_RAM and
    # CONFIG_PSTORE_CONSOLE are all set, and after a power-off neither
    # /proc/last_kmsg nor /sys/fs/pstore had anything. The symbols being present
    # is not evidence the region is preserved, and that is why the log ring
    # writes to flash instead.
    #
    # `debug` is deliberately not used: kmsg is echoed to `console=tty1`, the
    # framebuffer, and fbcon scrolls slowly enough that debug-level output is
    # itself indistinguishable from a hang.
    "systemd.log_target=kmsg"
    "systemd.log_level=info"
    "systemd.show_status=true"
  ];

  # The one observation channel that does not depend on this port working.
  #
  # `ttyS0`, not the `ttyMT3` that CONFIG_CMDLINE in this defconfig names: that
  # string is inert here. It only applies under CONFIG_CMDLINE_FORCE/EXTEND and
  # the defconfig sets CONFIG_CMDLINE_FROM_BOOTLOADER=y, and more decisively
  # `CONFIG_MTK_SERIAL is not set`, so the driver that registers `ttyMT*` is not
  # in this build at all. What is built is CONFIG_SERIAL_8250_MT6577, which
  # registers `ttyS*`, and mt6765.dts agrees: its own chosen/bootargs asks for
  # `console=ttyS0,921600n1`. uart0 is `reg = <0 0x11002000 0 0x1000>` (the
  # `serial@11020000` node name is a typo in the vendor tree; `reg` governs).
  #
  # Going through this option rather than a raw kernelParam is what puts it
  # *before* `console=tty1` on the cmdline. Linux gives /dev/console to the last
  # `console=`, so this ordering keeps userspace on the framebuffer while the
  # UART still receives kernel printk. A raw param would land after tty1 and
  # silently move /dev/console onto a port that may not be reachable.
  #
  # Whether the pads are physically exposed on this board is unresolved. Costs
  # nothing if they are not.
  mobile.boot.serialConsole = "ttyS0,921600n1";

  # Stage-1 diagnostics. The kernel now boots and stage-1 runs, but it fails,
  # and the panel was the only channel -- which is exactly the channel the
  # failure handler paints over. mobile-nixos/boot/init/lib/system.rb:233
  # `System.failure` prints the code, title, message and Ruby backtrace to
  # $logger.fatal (STDOUT, i.e. /dev/console = tty1 here) at :240-254, and only
  # then execs the LVGL applet at :272, which repaints the framebuffer over it.
  # Two boot attempts of the same image ended in `KE at ipanic+0x28/0x100`, which
  # is that applet's deliberate exit (boot/error/main.rb: "Exit, which will crash
  # the kernel"), not a crash -- and it takes the evidence with it.
  #
  # Remove all three once stage-1 reaches stage-2.

  # `System.failure` at :268 drops to an interactive shell before the applet,
  # gated on this. The shell blocks on /dev/console forever with no keyboard
  # attached, which is the point: init stays alive, so the USB gadget below
  # stays enumerated and the fatal text stays on the panel.
  mobile.boot.stage-1.shell.shellOnFail = true;

  # Without the applet there is nothing to repaint the console, and nothing to
  # exit PID 1. `mkIf cfg.enable` in modules/initrd-boot-gui.nix is what installs
  # /applets/boot-error.mrb at all, so disabling this removes the panic path
  # rather than merely losing a race with it.
  mobile.boot.stage-1.gui.enable = false;

  # The RAM console above only survives one reset. This survives every reset,
  # for anything that gets far enough for journald to run at all -- which so far
  # nothing has, because the freeze is upstream of the service manager.
  services.journald.storage = "persistent";

  # So this is the capture that does not depend on journald, on systemd, on adb,
  # or on the rootfs being mountable: the kernel ring buffer, written every two
  # seconds to a raw offset inside p41 past the end of the filesystem.
  #
  # Reading it is one `dd` with the partition unmounted, which matters because
  # the debug window on this device is created by zeroing the ext4 magic. The
  # previous capture wrote /var/kmsg.log, and reading that meant restoring the
  # magic, mounting, copying, unmounting and re-zeroing -- five steps to read one
  # file, at the exact moment the filesystem is deliberately unmountable.
  #
  # modules/bringup-log/layout.nix documents the offsets and the constraint this
  # puts on ever resizing the rootfs.
  mobile.bringup.rawLog = {
    enable = true;
    device = "/dev/mmcblk0p41";
  };

  # Puts adbd in the initrd and adds "adb" to the gadget's function list; the
  # stage-1 gadget task spawns it (modules/stage-1/tasks/usb-gadget-task.rb:31).
  # Until now mobile.boot.stage-1.usb.features was empty, so the functions
  # declared below were never composed into a gadget and nothing enumerated --
  # which is why no 18D1:4EE7 was ever seen on the host bus.
  mobile.adbd.enable = true;

  mobile.usb = {
    mode = "gadgetfs";
    idVendor = "18D1";  # Google
    idProduct = "4EE7"; # not the fastboot/preloader IDs, so lsusb disambiguates

    gadgetfs.functions = {
      rndis = "rndis.usb0";
      adb = "ffs.adb";
    };
  };

  # gzip, on no measured difference. Kept only because it decompresses faster
  # and nothing here needs the smaller image.
  #
  # Two earlier revisions of this comment justified the choice with boot
  # results. Both were wrong:
  #
  #   - "the kernel cannot unpack xz at all" -- read out of
  #     `# CONFIG_RD_XZ is not set` in kernel/config.aarch64, which is the input
  #     to the build, not the config the kernel is built with.
  #     mobile-nixos/modules/kernel-config.nix forces `RD_XZ = yes`, and
  #     CONFIG_IKCONFIG extraction from the flashed image confirms `=y`.
  #   - "the xz image reset at ~31s, the gzip image ran eleven minutes without
  #     resetting" -- the eleven quiet minutes were USB silence, not device
  #     silence. `db.fatal.02.HWT` timestamped 09:38:01 -05 and `/proc/uptime`
  #     read afterwards prove the gzip image reset at ~31s too, identically.
  #
  # Attempts 1, 2 and 3 all reset at ~29-31s with bootreason=Watchdog. Ramdisk
  # compression changes nothing, because the failure is upstream of the
  # initramfs: see the appendDTB comment above.
  #
  # Size is not a reason to prefer xz here: `boot` and `recovery` are both
  # 67108864 bytes, measured three ways, and the gzip candidate is 27209728.
  mobile.boot.stage-1.compression = lib.mkDefault "gzip";
}
