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

      # The backend has to be chosen inside the package, not around it.
      #
      # nixpkgs wraps tailscaled with `--prefix PATH` over its own closure, and a
      # prefix outranks whatever the unit's `path` puts after it. So the unit
      # ended up holding both: the legacy iptables this port needs, behind the
      # nft-backed one the wrapper injects. tailscaled ran the wrapper's, and the
      # observed failure named the store path:
      #
      #     adding [-j ts-input] in filter/INPUT: running [/nix/store/wqvi174y...
      #     -iptables-1.8.13/bin/iptables -t filter -I INPUT 1 -j ts-input --wait]:
      #     exit status 4: iptables v1.8.13 (nf_tables):  RULE_INSERT failed
      #     (No such file or directory): rule in chain INPUT
      #
      # while the same insert, and the `-m mark` and MASQUERADE rules that follow
      # it, all return 0 when run by hand with the legacy binary. `iptables -S |
      # grep -c ts-` was 0, so the tailnet address answered nothing: the node was
      # up, enrolled and reachable by DERP, and every inbound connection to it
      # hung with no rule to accept it.
      package = pkgs.tailscale.override {iptables = pkgs.iptables-legacy;};

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

    # No authKeyFile: this repo is public, and a key here would be a credential
    # in git. The node is enrolled by hand, once, with `doas tailscale up`.
    # State then persists in /var/lib/tailscale across reboots.
  };
}
