# The 4.9 compatibility set, in apply order.
#
# One list, two consumers: ../../modules/systemd-linux-4.9.nix applies it to the
# aarch64 systemd that ships, and the flake's `checks` applies it to the native
# systemd source to prove the patches still apply after a nixpkgs bump. Keeping
# the list here means the check can never be testing a different set than the
# one that gets built.
#
# What each one is for is documented in ../../modules/systemd-linux-4.9.nix,
# next to the attempt number that produced it.
[
  ./0002-systemd-mnt-id-fdinfo-fallback.patch
  ./0003-systemd-pidfd-sigchld-fallback.patch
  ./0004-systemd-uevent-no-synthetic-uuid.patch
  ./0005-systemd-block-sigchld-without-pidfd.patch
  ./0006-systemd-statx-sync-flags-and-mount-root.patch
  ./0007-systemd-cgroup2-mount-option-fallback.patch
]
