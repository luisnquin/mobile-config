# Bring-up for the mt6765 combo chip (Wi-Fi, Bluetooth, GPS, FM).
#
# Whichever copy of the driver is in play, it does not start itself.
# `MTK_WCN_REMOVE_KO` makes every sub-driver's init a plain exported function
# instead of a module_init, and the only thing that calls them is
# `do_connectivity_driver_init()`, reached through an ioctl on /dev/wmtdetect.
# On Android that ioctl comes from /vendor/bin/wmt_loader. Nothing on a NixOS
# rootfs issues it, so the chip stays dark and `nmcli general` reports
# `WIFI-HW missing` with no wlan0 anywhere.
#
# **This unit does not run on the kernel this port currently builds.**
# `CONFIG_WLAN_DRV_BUILD_IN` is unset -- see
# ../../devices/xiaomi-dandelion/kernel/default.nix for why: built in, the
# in-tree gen4m copy powers the chip on and the CONNSYS MCU parks in ROM at
# 0x4fd0. /dev/wmtdetect is created by that same subtree, so with the symbol off
# the node never appears and the ConditionPathExists below holds the unit off
# deliberately, permanently, and without a failed unit to show for it.
#
# It is kept because the node is expected back from the other direction: stock
# ships wmt_drv.ko, wmt_chrdev_wifi.ko and wlan_drv_gen4m.ko as vendor modules
# against this same 4.9.190 lineage, and `connadp.o` -- the kernel-side half
# they link against -- is compiled unconditionally. Loading those is the open
# work item; the userspace contract below does not change when it lands, because
# it is the same contract /vendor/bin/wmt_loader satisfies today. Not verified:
# that the out-of-tree build is what registers /dev/wmtdetect. Check before
# assuming this unit will simply start working.
#
# Two properties of that call path decide the shape of this unit.
#
# It runs exactly once per boot. `do_connectivity_driver_init()` sets its
# `init_before` flag *before* running anything and returns 0 on every later
# call, so a failed attempt is not retried -- it is permanently disabled until
# the next reboot. Restarting the unit cannot undo a failed init; only the
# power-on that follows it is repeatable, through a write to /dev/wmtWifi.
#
# MODULE_CLEANUP has to precede DO_MODULE_INIT. `sdio_detect.c` registers an
# SDIO driver named `mtk_sdio_client` at boot; `hif_sdio.c` -- the first of the
# four sub-inits -- registers a second, different `struct sdio_driver` under the
# same name. `driver_register()` refuses a duplicate name with -EBUSY, so
# without the cleanup the first sub-init fails, `do_common_drv_init()` returns
# the sum -16, and `do_connectivity_driver_init()` aborts before it ever reaches
# the wlan half:
#
#     Error: Driver 'mtk_sdio_client' is already registered, aborting...
#     [HIF-SDIO][I]hif_sdio_init:sdio_register_driver() fail, ret=-16
#     [WMT-MOD-INIT][I]do_common_drv_init:common driver init finish:-16
#     [WMT-MOD-INIT][E]do_connectivity_driver_init(43):do common driver not ready
#
# The individual sub-init results are logged at PR_DBG and `gWmtDetectDbgLvl` is
# a plain global, not a module parameter, so only that summed -16 is visible.
# The driver-core error above is what identifies which one failed.
#
# It has to keep running afterwards. The WMT core does not locate its own
# firmware: `wmt_ctrl_get_rom_patch_info()` stores a command string, wakes
# /dev/stpwmt and blocks for 6000 ms waiting for userspace to name the patches
# through WMT_IOCTL_SET_ROM_PATCH_INFO. With nothing on the other end the chip
# comes up with no firmware in EMI and the power-on write fails outright:
#
#     wmt_ctrl_ul_cmd(468): wait signal timeout
#     wmt_ctrl_get_rom_patch_info: wmt_ctrl_ul_cmd fail(-2)
#     mtk_wcn_soc_rom_patch_dwn(3585): failed to get patch (type: 0, ret: -1)
#     mtk_wcn_consys_hw_pwr_on: polling_consys_chipid fail
#     mtk_wcn_wmt_pwr_on: OPID(1) type(4) fail
#
# /dev/stpwmt is created by WMT_init(), which do_common_drv_init() calls, so it
# cannot exist before the ioctl above -- one process has to do both, in order.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.hardware.connectivity;

  loader =
    pkgs.runCommandCC "mtk-wmt-loader" {} ''
      mkdir -p $out/bin
      $CC -O2 -Wall -Wextra -std=gnu11 -o $out/bin/wmt-loader ${./wmt-loader.c}
    '';
in {
  options.mobile.hardware.connectivity.enable =
    lib.mkEnableOption "the MediaTek WMT combo-chip bring-up";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [loader];

    systemd.services.mtk-connectivity = {
      description = "Initialise the MediaTek connectivity chip";
      wantedBy = ["multi-user.target"];
      after = ["systemd-tmpfiles-setup.service"];

      # NetworkManager copes with wlan0 arriving late, but it reports
      # `WIFI-HW missing` until it does, which reads as a hardware fault.
      before = ["NetworkManager.service"];

      # The firmware is not in the kernel: gen4m calls request_firmware() for
      # WIFI_RAM_CODE_soc1_0_1_1.bin and the soc1_0_*_hdr.bin patches during
      # power-on, and those come from ../vendor-firmware.nix.
      unitConfig.ConditionPathExists = "/dev/wmtdetect";

      serviceConfig = {
        Type = "simple";
        ExecStart = "${loader}/bin/wmt-loader ${config.hardware.firmware}/lib/firmware";

        # A failed power-on does not end the process, so what is left to restart
        # splits in two, and the split is the exit status rather than a comment:
        #
        #   1  nothing was latched -- /dev/wmtdetect was absent or unopenable,
        #      or GET_SOC_CHIP_ID failed. Worth retrying; the node can appear
        #      late, and none of it has touched `init_before` yet.
        #   2  DO_MODULE_INIT has run. Retrying is worse than doing nothing:
        #      the init sets `init_before` before it does any work and returns 0
        #      forever after, so the second attempt reports success over a chip
        #      that was never initialised, and the unit goes active having done
        #      nothing. Everything downstream of that ioctl exits 2 for the same
        #      reason, including a /dev/stpwmt that never appears.
        Restart = "on-failure";
        RestartPreventExitStatus = [2];
        RestartSec = 5;
      };
    };
  };
}
