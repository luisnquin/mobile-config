# Bring-up for the mt6765 combo chip (Wi-Fi, Bluetooth, GPS, FM).
#
# The driver is built into the kernel (CONFIG_WLAN_DRV_BUILD_IN, see
# ../../devices/xiaomi-dandelion/kernel/default.nix) but it does not start
# itself. `MTK_WCN_REMOVE_KO` makes every sub-driver's init a plain exported
# function instead of a module_init, and the only thing that calls them is
# `do_connectivity_driver_init()`, reached through an ioctl on /dev/wmtdetect.
# On Android that ioctl comes from /vendor/bin/wmt_loader. Nothing on a NixOS
# rootfs issues it, so the chip stays dark and `nmcli general` reports
# `WIFI-HW missing` with no wlan0 anywhere.
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

        # A failed power-on no longer ends the process, so this only covers a
        # crash or a genuinely absent node. Restarting on a failed bring-up
        # would spin forever: DO_MODULE_INIT is already latched, so the retry
        # repeats the same attempt against the same dead chip.
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
