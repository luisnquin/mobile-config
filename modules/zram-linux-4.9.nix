# Compressed swap, set up without udev and with the algorithm pinned to one a
# 4.9 zram actually has.
#
# The device has 1875 MB of RAM and no swap at all, which is the binding
# constraint on running anything on it -- there is disk to spare and no headroom
# to build, back up or restart a database in.
#
# `zramSwap.enable` is not used, because the units it pulls in cannot start
# here. zram-generator orders `systemd-zram-setup@zram0.service` after
# `dev-zram0.device`, and that unit never becomes active: the udev worker
# rejects this device outright, so PID 1 never learns it is ready.
#
#   (udev-worker)[1431943]: zram0: Failed to process device, ignoring:
#     Invalid argument
#   systemd[1]: zram0: systemd-udevd failed to process the device, ignoring:
#     Invalid argument
#   systemd[1]: Timed out waiting for device /dev/zram0.
#   systemd[1]: Dependency failed for Create swap on /dev/zram0.
#
# `udevadm test --action=add /devices/virtual/block/zram0` applies the same
# rules and produces `TAGS=:systemd:` cleanly, so the rules are not the problem;
# something in the worker's apply step is. zram0 is not alone -- 170 of the 1072
# records under /run/udev/data carry an uncleared ID_PROCESSING, and only 116
# devices ever reach the systemd tag. mkswap and swapon do not need any of it.
#
# `zramSwap.algorithm` would default to zstd, and zstd support in zram is Linux
# 4.18. On dandelion's 4.9.190 the kernel advertises what it has:
#
#   # cat /sys/block/zram0/comp_algorithm
#   [lzo] lz4 deflate
#
# lz4 over lzo because this is swap on a 4-core A53: the compression ratio
# matters less than not stalling a fault, and lzo is the slow one of the two.
#
# CONFIG_ZRAM=y, CONFIG_CRYPTO_LZ4=y and CONFIG_CRYPTO_LZO=y are all set in the
# vendor config; zram0 exists on a stock boot and is simply never used.
#
# swappiness follows from what the swap device is. The default of 60 is tuned
# for a disk that costs milliseconds per page; here a page-out is a memcpy and a
# compression, so pushing cold anonymous pages out is cheaper than dropping page
# cache the vendor threads keep touching.
{ pkgs, ... }:

let
  algorithm = "lz4";
  memoryPercent = 50;
  priority = 5;

  sysfs = "/sys/block/zram0";
  node = "/dev/zram0";

  # `reset` is refused while the device is in use and clears disksize, which is
  # itself the precondition for writing comp_algorithm. Hence this order, and
  # hence a start that tolerates a previous one having left swap on.
  start = pkgs.writeShellScript "zram-swap-start" ''
    set -eu
    swapoff ${node} 2>/dev/null || true
    echo 1 > ${sysfs}/reset 2>/dev/null || true

    echo ${algorithm} > ${sysfs}/comp_algorithm

    total_kb=$(sed -n 's/^MemTotal: *\([0-9]*\) kB$/\1/p' /proc/meminfo)
    size=$(( total_kb * 1024 * ${toString memoryPercent} / 100 ))
    echo $(( size - size % 4096 )) > ${sysfs}/disksize

    mkswap -U clear ${node}
    swapon -p ${toString priority} --discard ${node}
  '';

  stop = pkgs.writeShellScript "zram-swap-stop" ''
    swapoff ${node} 2>/dev/null || true
    echo 1 > ${sysfs}/reset 2>/dev/null || true
  '';
in
{
  systemd.services.zram-swap = {
    description = "Compressed swap on ${node}";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.util-linux
      pkgs.gnused
    ];
    unitConfig.ConditionPathIsDirectory = sysfs;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = start;
      ExecStop = stop;
    };
  };

  boot.kernel.sysctl."vm.swappiness" = 100;
}
