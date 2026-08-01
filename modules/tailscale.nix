# Tailscale as a system service.
#
# tailscaled wants a real TUN device or it silently degrades to
# --tun=userspace-networking, which can reach the tailnet but cannot be reached
# from it. Verified on dandelion's running 4.9.190: CONFIG_TUN=y and
# /dev/net/tun present as crw------- 10,200. CONFIG_NF_TABLES and
# CONFIG_IP_NF_IPTABLES are also set, which is what tailscaled's own
# firewall rules need.
{ config, lib, ... }:

let
  cfg = config.mobile.services.tailscale;
in
{
  options.mobile.services.tailscale.enable = lib.mkEnableOption "the tailscale daemon";

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;

      # Sets checkReversePath to "loose". Without it the kernel drops replies
      # arriving on tailscale0 for traffic that left another interface, which is
      # exactly what using an exit node looks like.
      useRoutingFeatures = "client";

      # Direct connections instead of a DERP relay. Closed, this still works --
      # just slower and through Tailscale's servers.
      openFirewall = true;
    };

    # No authKeyFile: this repo is public, and a key here would be a credential
    # in git. The node is enrolled by hand, once, with `doas tailscale up`.
    # State then persists in /var/lib/tailscale across reboots.
  };
}
