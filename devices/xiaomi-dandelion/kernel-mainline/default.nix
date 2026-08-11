# Mainline Linux 6.18 LTS for Xiaomi Redmi 9A (dandelion).
#
# The alternative to ../kernel, which is the vendor 4.9.190 tree. Both are kept
# buildable: this one is the upgrade path, that one is what is known to boot.
# Selected by `mobile.hardware.socs.mediatek-mt6765.kernelTree`, declared in
# ../../../modules/soc/mt6765.nix because the SoC-level Kconfig assertions have
# to know which lineage they are talking about.
#
# Upstream 6.18 already carries the MT6765 pinctrl driver, all seven
# clk-mt6765* drivers, PMIC wrap support, the mt6765 clock and power
# dt-bindings headers and mt6357.dtsi. What it does not carry is any MT6765
# device tree, or MT6765 support in mtk-sd, i2c-mt65xx, mtk_iommu, mtk-smi,
# mtk-mutex, pwm-mtk-disp, mtk_wdt, auxadc_thermal, mtk-efuse,
# mtk-cmdq-mailbox, mtk-pm-domains, drm/mediatek or phy-mtk-mipi-dsi. That gap
# is what ../../../patches/linux/mt6765-mainline closes.
#
# The trailing `...` is load-bearing for the same reason as in ../kernel: see
# the comment there.
{
  mobile-nixos,
  fetchurl,
  ...
}:
mobile-nixos.kernel-builder {
  version = "6.18";

  # kernel.release is `6.18.0`: the tarball drops SUBLEVEL from its name, the
  # Makefile does not. Without this the builder's version check fails after the
  # whole kernel has already compiled.
  modDirVersion = "6.18.0";

  src = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.tar.xz";
    hash = "sha256-kQakYF2p4x/xdlnZWHgrgV+VkaswjQOw7iGq1sfc7Us=";
  };

  # 92 patches, applied in filename order. 89 of them are Arseniy Velikanov's
  # and Brandon Boese's MT6765 series from dandelion64-Archives/linux-mt6762-garden,
  # rebased from 6.5-rc3 onto v6.18; the remaining three are ours:
  #
  #   0090  the pm-domains bus-protection API moved from separate
  #         .bp_infracfg/.bp_smi arrays to a single .bp_cfg whose entries name
  #         their block, and BUS_PROT_WR() gained a leading _hwip argument.
  #   0091  mmc0 is `status = "disabled"` in mt6765.dtsi and the garden device
  #         trees only ever enabled mmc1 (the SD slot). The rootfs is on the
  #         eMMC, so without this the kernel boots and finds no root device.
  #   0092  the lk framebuffer the series hands to simplefb was never carved out
  #         of /memory, and arm64 `ioremap_prot()` refuses to map anything in
  #         the linear map. Without the reservation the probe returns -ENOMEM
  #         and `console=tty1` has no framebuffer behind it -- on a board whose
  #         UART is `status = "disabled"` in this tree and forbidden on the
  #         cmdline besides, that is every console the device has. See
  #         ../README.md, "What the mainline arm can and cannot report".
  #
  # Two commits from the garden series are deliberately absent: the Samsung
  # Galaxy Tab A7 Lite device tree and its fixup. Different device, and its
  # .dts pulls headers this tree does not have.
  # `builtins.attrNames` returns names sorted lexicographically, and the
  # sequence numbers are zero-padded to four digits, so that is also patch
  # order.
  patches = let
    dir = ../../../patches/linux/mt6765-mainline;
  in
    map (name: dir + "/${name}") (builtins.attrNames (builtins.readDir dir));

  # Same as the vendor kernel: KERNEL_BUILD_TARGET is Image.gz, and the boot
  # image appends the FDT to it.
  isCompressed = "gz";

  isModular = true;

  enableLinuxLogoReplacement = false;
  enableCenteredLinuxLogo = false;

  # Seeded from postmarketOS' config-postmarketos-mediatek-mt6762.aarch64
  # (pmaports-mt6762, written against the 6.5-era garden tree), then run
  # through `make olddefconfig` against this source so the file matches what
  # is actually built. Every MT6765 symbol survived the migration.
  #
  # As in ../kernel, this is the *input* to the build. Mobile NixOS layers its
  # structured config on top and both adds and overrides symbols. Read
  # /proc/config.gz on the running device to know what was really built.
  configfile = ./config.aarch64;
}
