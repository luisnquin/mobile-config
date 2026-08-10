# Downstream MediaTek 4.9.190 kernel for Xiaomi Redmi 9A (dandelion).
#
# Source: Droidian's fork of Xiaomi's `dandelion-q-oss` drop. See "Toolchain
# deviation" in ../README.md for why the compiler is GCC 13 rather than the
# AOSP clang 6.0 Droidian uses, and what that deviation does not prove.
#
# The trailing `...` is load-bearing. `boot.kernelPackages`' apply function
# (nixos/modules/system/boot/kernel.nix:76-81) does
# `super.kernel.override (originalArgs: { randstructSeed; kernelPatches; features; })`,
# so anything that evaluates `system.build.toplevel` -- the rootfs, not the boot
# image -- calls this function with three arguments it does not declare. Every
# upstream Mobile NixOS device kernel ends its argument set the same way.
#
# The consequence is that `boot.kernelPatches` and `boot.kernel.features` are
# inert for this device. Patches go in the `patches` list below.
{
  mobile-nixos,
  overrideCC,
  stdenv,
  buildPackages,
  fetchFromGitHub,
  python3,
  ...
}:
# `stdenv` is a callPackage-injected dependency of the builder, not one of its
# user arguments: builder.nix is a two-level function and the user set ends in
# `...`, so passing `stdenv = ...` alongside `version`/`src` is silently
# accepted and ignored. It has to go through `.override`, the same way the
# overlay derives `kernel-builder-clang`. Otherwise CC stays the default
# nixpkgs GCC, which is 15.x and not the compiler this port was validated with.
(mobile-nixos.kernel-builder.override {
  # nixpkgs' default GCC rejects implicit function declarations, which a 2019
  # vendor tree cannot survive. GCC 13 is the newest release still packaged in
  # nixpkgs that only warns. `buildPackages.gcc13` is the cross compiler that
  # runs on the build machine and targets aarch64.
  stdenv = overrideCC stdenv buildPackages.gcc13;
}) {
  # `make kernelversion` in the kernel tree @ d31e916b.
  version = "4.9.190";

  # The release string is plain `4.9.190`: Mobile NixOS' structured config
  # forces CONFIG_LOCALVERSION="" and LOCALVERSION_AUTO=n
  # (modules/kernel-config.nix), which overrides the defconfig's
  # "-xiaomi-dandelion". config.aarch64 is stored already normalized to that so
  # the shipped file matches what is actually built.
  # Stock reports 4.9.190-perf-gd6489126e4e3: same base version, different
  # defconfig lineage (`perf` vs `halium`).

  # Normalized from `dandelion_halium_defconfig` by an out-of-tree
  # `make olddefconfig` against the pinned source. Two deviations from the
  # vendor defconfig, both deliberate:
  #
  #   CONFIG_USB_USBNET=y                       (vendor: not set), with
  #                                             CDCETHER, CDC_NCM, RNDIS_HOST
  #                                             and IPHETH
  #   CONFIG_FW_LOADER_USER_HELPER_FALLBACK=n   (vendor: y), and only because
  #                                             patch 0008 removes the `select`
  #                                             that pins it on
  #
  # `CONFIG_WLAN_DRV_BUILD_IN` is left at the vendor's `n`, which is not the
  # obvious choice and was wrong here for a while. It gates
  # `drivers/misc/mediatek/connectivity/Makefile`'s descent into `common/`,
  # `wlan/adaptor/`, `wlan/core/gen4m/`, `bt/`, `gps/` and `fmradio/`, so
  # turning it on does produce /dev/wmtdetect and a WMT stack -- but the copy
  # under that switch is the one MediaTek abandoned in place, as the Makefile
  # says above it: "Do Nothing, move to standalone repo". Built in, it powers
  # the chip on and the CONNSYS MCU parks in ROM at 0x4fd0 forever, never
  # reaching the 0x1D1E the driver polls for.
  #
  # What the switch leaves alone is `connadp.o`, built unconditionally from
  # `common/connectivity_build_in_adapter.o` and `common/wmt_build_in_adapter.o`.
  # That is not a leftover: it is the kernel-side half of the out-of-tree build,
  # and every symbol the stock `wmt_drv.ko` imports resolves to it or to a
  # driver outside this subtree (BTIF, EMI MPU, conn_md, aee). `gConEmiPhyBase`
  # is exported from both it and `gen4m/gl_init.c`, which is what makes the two
  # halves mutually exclusive by construction. So `n` is not "no driver", it is
  # "the driver comes from vendor" -- the same arrangement stock Android uses,
  # where /vendor/lib/modules ships wmt_drv.ko, wmt_chrdev_wifi.ko and
  # wlan_drv_gen4m.ko against a 4.9.190 kernel from this same source lineage.
  #
  # Wi-Fi is the difference between a device that can be managed remotely and one
  # tethered to the build host: without it the tailnet's only route out is the
  # HTTP CONNECT tunnel on that host, over the same USB cable.
  #
  # `FW_LOADER_USER_HELPER_FALLBACK` turns every missing firmware file into a
  # full 60 s wait on a userspace helper that no NixOS system runs. Two fire on
  # this device -- WMT_STEP.cfg and novatek_ts_djn_fw.bin -- for about 105 s of
  # boot spent blocking on nothing. `request_firmware()` still reads from
  # `firmware_class.path`; only the helper fallback goes away. The line in
  # config.aarch64 does nothing on its own: `MEDIATEK_SOLUTION` selects the
  # symbol, and `select` cannot be overridden from a config file, so the
  # `is not set` there is honoured only because patch 0008 deletes the select.
  #
  # `USB_USBNET` and its four class drivers are the host-side counterpart: a
  # phone or a modem plugged into an OTG adapter enumerates as RNDIS, CDC ECM,
  # NCM or (iOS) ipheth, and without these the device is recognised and bound to
  # nothing. Nothing else is needed for the host role -- `usb20/Makefile` builds
  # `musb_host.o` and `musb_virthub.o` unconditionally under `USB_MTK_HDRC`, and
  # `CONFIG_USB_MTK_OTG=y` already supplies IDDIG cable detection and DRVVBUS.
  # Generic `CONFIG_USB_OTG` is mainline musb's mechanism, not this tree's, and
  # is deliberately left off: it sits on the gadget path that carries rndis0 and
  # adb, which is the only way back into this device.
  #
  # The dongle drivers under `USB_NET_DRIVERS` are all pinned off rather than
  # left at their `default y`. `USB_NET_AX8817X` alone `select`s PHYLIB, which
  # drags the MDIO bus and twenty-five MII PHY drivers into a kernel with no
  # MDIO bus at all -- `select` bypasses `depends on`, so nothing warns.
  #
  # This file is the *input* to the build, not the config the kernel is built
  # with. Mobile NixOS layers its structured config on top
  # (mobile-nixos/modules/kernel-config.nix), and that layer both adds
  # and overrides symbols. Three that matter here, all `is not set` in the vendor
  # config and all forced on by Mobile NixOS:
  #
  #   RD_GZIP, RD_XZ            initramfs decompressors
  #   FRAMEBUFFER_CONSOLE       what `console=tty1` actually binds to
  #
  # Do not reason about this port's runtime behaviour by reading this file. On
  # 2026-07-31 that mistake produced two confident and wrong root causes for a
  # failed boot. Read the config out of the built image instead; this config
  # enables CONFIG_IKCONFIG, so `/proc/config.gz` on the running device is
  # authoritative.
  configfile = ./config.aarch64;

  # Pinned by revision, not by branch: `halium-10.0` moves.
  src = fetchFromGitHub {
    name = "kernel-droidian-mt6765";
    owner = "droidian-mt6765";
    repo = "kernel-xiaomi-mt6765";
    rev = "d31e916b28ccf4419c00e6e774841e7d65df06c5";
    hash = "sha256-csijacVuv9IfHAGOR5SAeZ5alWPzuwZmzrNbFvIPGW8=";
  };

  # A removed patch is recorded here as well as the applied one:
  # 0001-dts-mt6765-add-stdout-path.patch added chosen/stdout-path so that a
  # bare `earlycon` could resolve a device. It was the reason this port did not
  # boot, and it is deleted rather than disabled; see boot.kernelParams in
  # ../default.nix for the bisect that established it.
  patches = [
    ../../../patches/linux/mt6765/0006-mtkfb-implement-fb_setcolreg.patch
    ../../../patches/linux/mt6765/0007-mtk-battery-keep-log-level-when-booted-from-recovery.patch
    ../../../patches/linux/mt6765/0008-mediatek-drop-firmware-user-helper-fallback-select.patch
  ];

  # A 2024 compiler emits diagnostics this tree predates (-Warray-compare,
  # -Wbuiltin-declaration-mismatch, ...). A blanket -Wno-error does not cancel
  # an explicit -Werror=<name>, so the flags have to come out of the makefiles.
  enableRemovingWerror = true;

  # KERNEL_BUILD_TARGET = Image.gz in debian-dandelion/kernel-info.mk.
  isCompressed = "gz";

  # The defconfig is effectively monolithic: every driver that matters is built
  # in. Five symbols are `=m` (wireguard, two TCP congestion controls, two DVB
  # tuners) and none of them is on the boot path, but they are built and
  # installed anyway so the shipped config stays honest about what it declares.
  isModular = true;

  # The tree has no in-tree logo replacement path that survives this vintage,
  # and the boot logo is drawn by the bootloader on this device anyway.
  enableLinuxLogoReplacement = false;
  enableCenteredLinuxLogo = false;

  # `scripts/drvgen/drvgen.mk` runs `tools/dct/DrvGen.py` to generate
  # `arch/arm64/boot/dts/dandelion/cust.dtsi`, so this is a device-tree
  # dependency, not a helper. Its shebang is `#! /usr/bin/python3`, and the
  # builder's `patchShebangs tools` silently leaves a shebang alone when the
  # interpreter is not on PATH — python3 has to be here for the rewrite to
  # happen at all.
  nativeBuildInputs = [python3];

  # gcc10+ defaults to -fno-common; this tree relies on tentative definitions
  # being merged.
  makeFlags = ["KCFLAGS=-fcommon"];
}
