# Force the firewall onto the legacy iptables backend.
#
# iptables 1.8.13 is built with nftables support and installs `iptables` as a
# symlink to `xtables-nft-multi`, so every rule the NixOS firewall module writes
# goes through nf_tables. On dandelion's 4.9.190 that fails:
#
#   iptables v1.8.13 (nf_tables): RULE_APPEND failed (No such file or directory)
#
# The kernel config is misleading here. `CONFIG_NF_TABLES=y` is set, so the
# nf_tables core is present and `iptables-nft -L` lists chains happily. What is
# missing is every *expression* module the rules are built out of --
# CONFIG_NFT_COUNTER, CONFIG_NFT_SET_HASH, CONFIG_NFT_SET_RBTREE and the whole
# NFT_CHAIN_* family are all unset. A rule referencing an expression the kernel
# never registered comes back from nfnetlink as ENOENT, which iptables reports
# as the "No such file or directory" above. Reading it as a missing file, or as
# nf_tables being absent, both send you looking in the wrong place.
#
# Measured on the device, same rule, both backends:
#
#   iptables-nft    -A INPUT -p tcp --dport 65000 -j ACCEPT  -> rc=4, RULE_APPEND failed
#   iptables-legacy -A INPUT -p tcp --dport 65000 -j ACCEPT  -> rc=0, rule present in -S
#
# CONFIG_IP_NF_IPTABLES=y and /proc/net/ip_tables_names lists all five tables,
# so the legacy path is fully built out. This is the backend the vendor shipped
# for and the only one that works.
#
# `networking.firewall.package` rather than an overlay: it is exactly what the
# option is for -- its own documented example is `pkgs.iptables-legacy` -- and
# it keeps the swap on the target's firewall instead of leaking through
# `pkgs.buildPackages` into the cross toolchain. The module also puts this
# package in `environment.systemPackages`, so an interactive `iptables` on the
# device speaks to the same tables the firewall wrote.
{ pkgs, ... }:

{
  networking.firewall.package = pkgs.iptables-legacy;
}
