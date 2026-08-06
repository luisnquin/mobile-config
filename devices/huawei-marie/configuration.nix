{ ... }:

let
  profile = import ./profile.nix;
in
{
  imports = [
    ../../modules/soc/kirin710.nix
    ../../modules/stage2-bringup.nix
    ../../modules/stage-1-ssh.nix
    ../../modules/session.nix
    ../../modules/usb-network.nix
  ];

  networking.hostName = "marie";
  system.stateVersion = "26.11";

  mobile.device.name = "huawei-marie";
  mobile.device.identity = {
    name = "P30 Lite (${profile.identity.model})";
    manufacturer = profile.identity.manufacturer;
  };
  mobile.device.supportLevel = "broken";

  mobile.system.type = "android";

  mobile.hardware = {
    soc = "hisilicon-${profile.identity.soc}";
    ram = 1024 * 6;
    screen = {
      inherit (profile.hardware.screen) width height;
    };
  };

  mobile.services.usbNetwork.enable = true;
}
