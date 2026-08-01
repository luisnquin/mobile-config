# Keeps the USB network alive after switch_root.
#
# The gadget itself survives: stage-1 builds it in configfs, and configfs is a
# kernel filesystem that stage-2 remounts (mobile-nixos/modules/usb-gadget.nix),
# so `rndis0` is still there and still bound to its UDC. What does not survive
# is everything stage-1 did in userspace -- the `ifconfig rndis0 <ip>` and the
# udhcpd that hands the build host its address, both from
# mobile-nixos/modules/stage-1/tasks/dhcpd-task.rb. Without replacing them,
# stage-2 comes up with an interface that has no address and a host that gets no
# lease, so the only way in is the panel.
#
# adb is not this module's problem: mobile.adbd.enable re-launches adbd against
# the same gadget.
{ config, lib, pkgs, ... }:

let
  cfg = config.mobile.services.usbNetwork;
in
{
  options.mobile.services.usbNetwork = {
    enable = lib.mkEnableOption "addressing and DHCP on the USB gadget's network interface";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "rndis0";
      description = "Gadget network interface. Stage-1 tries rndis0, usb0 and eth0 in that order.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "172.16.42.1";
      description = "Address given to the device. Matches the stage-1 default.";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "172.16.42.2";
      description = "The single address leased to whatever is plugged in.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.interfaces.${cfg.interface}.ipv4.addresses = [
      {
        address = cfg.address;
        prefixLength = 24;
      }
    ];

    # networking.useDHCP is on for the sake of interfaces that do not exist yet
    # (wifi), and would otherwise have dhcpcd bid for an address on the one
    # interface that is meant to be serving them.
    networking.dhcpcd.denyInterfaces = [ cfg.interface ];

    services.dnsmasq = {
      enable = true;

      # DHCP only. Left on, this would also point the device's own resolver at
      # 127.0.0.1, which is a lie on a device with no upstream DNS.
      resolveLocalQueries = false;

      # rndis0 only appears once the host enumerates the gadget, which can be
      # after dnsmasq would first try to bind. Restart=always turns that race
      # into a delay.
      alwaysKeepRunning = true;

      settings = {
        interface = cfg.interface;
        bind-interfaces = true;
        port = 0;
        dhcp-authoritative = true;
        dhcp-range = "${cfg.hostAddress},${cfg.hostAddress},255.255.255.0,12h";
      };
    };

    networking.firewall.interfaces.${cfg.interface} = {
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ 67 ];
    };
  };
}
