# Downstream MediaTek 4.9.190 kernel for Xiaomi Redmi 9A (dandelion).
#
# Source: Droidian's fork of Xiaomi's `dandelion-q-oss` drop. See "Toolchain
# deviation" in ../../../README.md for why the compiler is GCC 13 rather than
# the AOSP clang 6.0 Droidian uses, and what that deviation does not prove.
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
  # `make olddefconfig` against the pinned source, and kept a faithful
  # normalization of it — no deviations.
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

  # Pinned by revision, not by branch. `halium-10.0` moves; this port was
  # developed and boot-tested against exactly this tree.
  #
  # The tarball GitHub serves for this revision was diffed against a local
  # `git clone` of the same revision and is identical: the repository's
  # .gitattributes sets only `diff=cpp`, so nothing is `export-ignore`d.
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
  patches = [ ../../../patches/kernel/0006-mtkfb-implement-fb_setcolreg.patch ];

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
  nativeBuildInputs = [ python3 ];

  # gcc10+ defaults to -fno-common; this tree relies on tentative definitions
  # being merged.
  makeFlags = [ "KCFLAGS=-fcommon" ];
}
