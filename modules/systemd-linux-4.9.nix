# systemd 261 does not run on this device's vendor kernel. Its baseline is far
# above 4.9.190, and the assumptions below are load-bearing rather than
# cosmetic. All were found by booting and reading the failure, not by reading
# release notes; each patch's header records the measurement. 0002-0005 came out
# of `systemdMinimal` in stage-1; 0006 is the first one from full systemd as PID
# 1, which is a separate set of baseline assumptions and was never exercised
# until the rootfs booted far enough to reach it.
#
#   0002  chase() asks xstatx_full() for a mount id and returns -EUNATCH when
#         statx() does not supply one. STATX_MNT_ID is Linux 5.8, statx() itself
#         4.11. Attempt 13: 1067 sd-device failures, `udevadm trigger` dead.
#   0003  sd_event_add_child() hard-requires pidfd_open(), Linux 5.3. Attempt 14:
#         udev ran, spawned 34 workers, watched none, processed no events.
#   0004  sd_device_trigger_with_uuid() writes "<action> <uuid>", which needs
#         kobject_synth_uevent(), Linux 4.13. Attempt 15: udev settled, but
#         `udevadm trigger` produced nothing and dmesg carried 1141 dropped
#         uevents. The write returns success either way, so this one cannot be
#         detected at runtime from errno -- it has to gate on the version.
#   0005  completes 0003: nothing blocked SIGCHLD, and a signalfd sees nothing
#         while its signal is unblocked. Attempt 16: 1061 devices processed but
#         14 permanent zombie workers and `udevadm settle` timing out, because
#         reaping only happened as a side effect of adding the next child.
#   0006  glibc emulates the missing statx() (Linux 4.11) from fstatat() and
#         rejects the AT_STATX_*_SYNC flags with EINVAL; separately,
#         STATX_ATTR_MOUNT_ROOT is Linux 5.8. Stage-2 attempt 1: PID 1 could not
#         decide whether /proc, /sys and /dev were mount points, and mount_setup()
#         treats that as fatal, so systemd froze at 27.0s with no service manager
#         running. Also the reason 0002 had never actually been reachable.
#
# Expect more of these. The alternative is pinning nixpkgs to a systemd old
# enough to still support this kernel, which trades a small number of local
# patches for a very large version downgrade across the whole system.
#
# Only `systemd` is overridden. `systemdMinimal` -- what Mobile NixOS puts in
# the initrd, hardcoded at mobile-nixos/modules/initrd.nix:4 -- is
# `systemd.override { ... }` against the final package set, and overrideAttrs
# survives override, so it inherits the patch. Patching it a second time here
# would make the patch fail to apply.
#
# Scoped to aarch64 on purpose. `nixpkgs.overlays` also applies to
# `pkgs.buildPackages`, so an unscoped override patches the x86_64 systemd that
# performs the cross build, invalidates everything downstream of it, and forces
# a local rebuild of native qtbase, openjdk and gtk4 instead of substituting
# them from cache.nixos.org. Nothing here is wanted on the build host: these
# work around a 4.9.190 vendor kernel, and the builder runs a current one.
{ lib, ... }:

{
  nixpkgs.overlays = [
    (final: prev: lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
      # systemd's BPF programs are compiled by `clang -target bpf` against the
      # build host's kernel headers, which a cross build does not have:
      # `linux/bpf.h` fails on a missing `linux/types.h`. Nothing is lost by
      # turning them off -- socket-bind, bind-iface and restrict-fs all need
      # BTF/CO-RE and a 5.x kernel. `systemdMinimal`, which is what stage-1
      # builds, already sets this false, which is why only stage-2 hit it.
      # The list lives in ../patches/systemd/default.nix so that the flake's
      # `checks.systemd-patches` applies exactly this set against the native
      # systemd source. A patch that stops applying after a nixpkgs bump is then
      # a failed `nix flake check` in seconds, rather than a cross-compile, a
      # 3 GB device write and a boot.
      systemd = (prev.systemd.override { withLibBPF = false; }).overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ import ../patches/systemd;
      });
    })
  ];
}
