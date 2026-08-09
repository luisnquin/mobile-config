# Tailscale as a system service.
#
# tailscaled wants a real TUN device or it silently degrades to
# --tun=userspace-networking, which can reach the tailnet but cannot be reached
# from it. Verified on dandelion's running 4.9.190: CONFIG_TUN=y and
# /dev/net/tun present as crw------- 10,200.
#
# tailscaled also installs its own netfilter rules, and only the legacy path can
# carry them here: CONFIG_IP_NF_IPTABLES=y with all five tables in
# /proc/net/ip_tables_names, while CONFIG_NF_TABLES=y buys nothing because every
# expression module (NFT_COUNTER, NFT_SET_HASH, the NFT_CHAIN_* family) is
# unset. See ./iptables-linux-4.9.nix -- that module points the firewall at
# iptables-legacy, and tailscaled has to end up on the same backend.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.services.tailscale;
in {
  options.mobile.services.tailscale.enable = lib.mkEnableOption "the tailscale daemon";

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;

      # Left at "none". "client" only exists to set checkReversePath = "loose",
      # which NixOS implements as an iptables `-m rpfilter` rule -- and vendor
      # kernels tend not to build that match. dandelion's does not
      # (CONFIG_IP_NF_MATCH_RPFILTER unset, only the IPv6 one is there), and
      # net.ipv4.conf.*.rp_filter reads 0, so there is nothing to loosen. Asking
      # for it fails the firewall module's own assertion at eval time.
      #
      # Raise this to "client" only alongside CONFIG_IP_NF_MATCH_RPFILTER, and
      # only for a device that actually needs an exit node or subnet route.
      useRoutingFeatures = "none";

      # Direct connections instead of a DERP relay. Closed, this still works --
      # just slower and through Tailscale's servers.
      openFirewall = true;
    };

    # tailscaled shells out to `iptables` to install its ts-input/ts-forward
    # chains, and the upstream unit's PATH is only /run/wrappers/bin -- there is
    # no iptables in it at all. Left alone it finds nothing, or finds an nft
    # binary that cannot append a rule on this kernel. `path` is a list option,
    # so this merges with the upstream unit rather than replacing it.
    #
    # Not yet observed failing: the daemon sits in NeedsLogin until the node is
    # enrolled, and never reaches firewall setup. This is the fix landing before
    # the symptom, not after it.
    systemd.services.tailscaled.path = [pkgs.iptables-legacy];

    # No authKeyFile: this repo is public, and a key here would be a credential
    # in git. The node is enrolled by hand, once, with `doas tailscale up`.
    # State then persists in /var/lib/tailscale across reboots.
  };
}
