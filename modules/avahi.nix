# mDNS, so the device answers to a name instead of a hardcoded address.
#
# The USB link has no DNS on it: dnsmasq runs in ./usb-network.nix with
# `port = 0`, which is DHCP-only, and nothing on either side resolves the
# other's name. Every route in and out of this device is therefore a literal
# 172.16.42.1, including the entries in a developer's known_hosts -- and an
# address is the one thing that changes if the gadget's addressing is ever
# reworked.
#
# avahi publishes `<networking.hostName>.local` over multicast on the gadget
# interface, which the build host resolves through nss-mdns without any
# configuration beyond what a desktop already has.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.services.avahi;
  usb = config.mobile.services.usbNetwork;
in {
  options.mobile.services.avahi.enable =
    lib.mkEnableOption "mDNS publication of this device's hostname";

  config = lib.mkIf cfg.enable {
    services.avahi = {
      enable = true;

      # Bound to the gadget interface alone. This kernel exposes ifb0 and ifb1
      # -- intermediate functional block devices, which exist for traffic
      # shaping and carry nothing -- and they pick up IPv4LL addresses in the
      # same 169.254/16 range mDNS is at home in. Left unrestricted, avahi
      # announces the host on stubs no one can reach and the useful record
      # competes with two useless ones.
      allowInterfaces = [usb.interface];

      publish = {
        enable = true;
        addresses = true;
        workstation = true;
      };

      # Advertises _ssh._tcp, so `avahi-browse -rt _ssh._tcp` on the build host
      # finds the device without knowing it exists first. The file ships with
      # avahi; writing one here would only duplicate it.
      extraServiceFiles.ssh = "${pkgs.avahi}/etc/avahi/services/ssh.service";

      # Lets the device resolve .local names as well as publish them. Cheap,
      # and it makes the link symmetric for anything running on the phone.
      nssmdns4 = true;
    };

    # openFirewall on the avahi module opens 5353 globally. This device's
    # firewall is per-interface for everything else (see ./usb-network.nix), so
    # keep mDNS the same shape rather than widening the global set.
    networking.firewall.interfaces.${usb.interface}.allowedUDPPorts = [5353];
  };
}
