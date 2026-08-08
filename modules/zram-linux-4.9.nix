# Compressed swap, with the algorithm pinned to one a 4.9 zram actually has.
#
# The device has 1875 MB of RAM and no swap at all, which is the binding
# constraint on running anything on it -- there is disk to spare and no headroom
# to build, back up or restart a database in.
#
# `zramSwap.algorithm` defaults to zstd, and zstd support in zram is Linux 4.18.
# On dandelion's 4.9.190 the kernel advertises what it has, and zstd is not in
# the list:
#
#   # cat /sys/block/zram0/comp_algorithm
#   [lzo] lz4 deflate
#
# Writing an unsupported name to that attribute returns EINVAL, so the default
# turns into systemd-zram-setup@zram0.service failing at boot -- with the swap
# silently absent rather than the system refusing to come up. lz4 over lzo
# because this is swap on a 4-core A53: the compression ratio matters less than
# not stalling a fault, and lzo is the slow one of the two.
#
# CONFIG_ZRAM=y, CONFIG_CRYPTO_LZ4=y and CONFIG_CRYPTO_LZO=y are all set in the
# vendor config; zram0 exists on a stock boot and is simply never used.
#
# swappiness follows from what the swap device is. The default of 60 is tuned
# for a disk that costs milliseconds per page; here a page-out is a memcpy and a
# compression, so pushing cold anonymous pages out is cheaper than dropping page
# cache the vendor threads keep touching.
{ ... }:

{
  zramSwap = {
    enable = true;
    algorithm = "lz4";
    memoryPercent = 50;
  };

  boot.kernel.sysctl."vm.swappiness" = 100;
}
