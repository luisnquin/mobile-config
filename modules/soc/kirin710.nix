{ config, lib, ... }:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.mobile.hardware.socs;
in
{
  options.mobile.hardware.socs.hisilicon-kirin710.enable = mkOption {
    type = types.bool;
    default = false;
    description = "enable for HiSilicon Kirin 710 devices";
  };

  config = mkIf cfg.hisilicon-kirin710.enable {
    mobile.system.system = "aarch64-linux";
  };
}
