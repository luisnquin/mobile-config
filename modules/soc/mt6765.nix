# MediaTek MT6765 platform definition, kept out of tree.
#
# Mobile NixOS' modules/hardware-mediatek.nix hardcodes a list of MediaTek SoCs.
# Declaring the option here instead of patching that file is enough: the
# assertion in modules/hardware-soc.nix only checks that
# `mobile.hardware.socs ? ${mobile.hardware.soc}` holds, and it does once this
# module is imported. That keeps mobile-nixos free of another patch.
#
# MT6762G (Helio G25) is a bin of the MT6765 family. The kernel, the device
# tree, and every MediaTek driver in the downstream tree use MT6765; only the
# marketing name and the clock bins differ. `ro.boot.hardware` on the target
# reads `mt6762`.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types;
  cfg = config.mobile.hardware.socs;
in {
  options.mobile.hardware.socs.mediatek-mt6765 = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "enable when SOC is Mediatek MT6765 / MT6762 (Helio P35, G25, G35)";
    };
  };

  config = mkIf cfg.mediatek-mt6765.enable {
    mobile.system.system = "aarch64-linux";

    # The downstream 4.9 tree has no DRM driver and no atomic modesetting. The
    # panel is driven by MediaTek's own LCM framework behind a legacy fbdev, and
    # that fbdev does not repaint on its own after userspace writes.
    mobile.quirks.fb-refresher.enable = true;

    mobile.kernel.structuredConfig = [
      (helpers:
        with helpers; {
          # ARCH_MEDIATEK is the *mainline* MT65xx/MT81xx platform in this tree and
          # is mutually exclusive with the vendor stack. Kconfig says so directly:
          # PINCTRL_MT6765 depends on `PINCTRL && !ARCH_MEDIATEK && MACH_MT6765`.
          # Enabling it also `select`s the mainline MTK_TIMER, which collides with
          # the vendor mtk_apxgpt.c over `mtk_timer_clkevt_aee_dump`, and flips
          # COMMON_CLK_MT8173 on by `default ARCH_MEDIATEK`, whose clkdbg_mt8173.c
          # this fork deleted. Both are link/build failures, not warnings.
          ARCH_MEDIATEK = no;

          # Set by dandelion_halium_defconfig; asserted here so a config
          # regression fails evaluation instead of failing on the device.
          MACH_MT6765 = yes;
          MTK_LCM = yes;
        })
    ];
  };
}
