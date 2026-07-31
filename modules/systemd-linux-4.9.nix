# systemd 261 does not run on this device's vendor kernel. Its baseline is far
# above 4.9.190, and the assumptions below are load-bearing rather than
# cosmetic. All were found by booting stage-1 and reading the failure, not by
# reading release notes; each patch's header records the measurement.
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
{ ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      systemd = prev.systemd.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/systemd/0002-systemd-mnt-id-fdinfo-fallback.patch
          ../patches/systemd/0003-systemd-pidfd-sigchld-fallback.patch
          ../patches/systemd/0004-systemd-uevent-no-synthetic-uuid.patch
          ../patches/systemd/0005-systemd-block-sigchld-without-pidfd.patch
        ];
      });
    })
  ];
}
