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
#   0007  the cgroup2 option string carries nsdelegate (Linux 4.13) and
#         memory_recursiveprot (Linux 5.7), and the kernel's parser rejects the
#         whole string over one unknown element. Stage-2 attempt 2: froze at
#         38.0s in mount_setup(), 10.7s further than 0006's failure, which is
#         how 0006 was confirmed. systemd cannot probe for this either --
#         mount_option_supported() is built on fsopen(), Linux 5.2 -- so this
#         retries without options instead.
#   0008  access_fd() calls faccessat(fd, "", mode, AT_EMPTY_PATH). faccessat2()
#         is Linux 5.8, and glibc's userspace emulation of the four-argument
#         faccessat() rejects AT_EMPTY_PATH with EINVAL. Stage-2 attempt 3: PID 1
#         mounted cgroup2, printed its banner, detected first boot and set the
#         hostname, then froze at 31.0s on "Failed to allocate manager object:
#         Invalid argument" -- manager_new() pinning the executor binary. The
#         only report was a log_debug_errno(), so at the default log level the
#         freeze named no step at all.
#   0009  close_all_fds() drives close_range(), Linux 5.9, and turns its ENOSYS
#         into a hard error at all three call sites. Stage-2 attempt 4: PID 1
#         reached Multi-User System in 6min 30s -- the first full boot -- but no
#         unit ever ran, because every fork() died at step FDS. 728 of them over
#         12 minutes, getty and logind included, which is why a device that
#         finished booting still offered no way in. systemd already has the
#         fallback: close_all_fds_frugal() closes the fds in a loop and is used
#         whenever the special case reports it did not handle the request.
#   0010  close_all_fds_frugal() bounds its loop with get_max_fd(), which reports
#         RLIMIT_NOFILE, not what is open. PID 1 raises fs/nr_open to the kernel
#         max at startup and then sets its own RLIMIT_NOFILE cur and max to it,
#         and the FDS step runs before the child's rlimits are lowered, so
#         get_max_fd() answers 2147483583 against a MAX_FD_LOOP_LIMIT of
#         1048576. Stage-2 attempt 5: every fork() still died at step FDS, the
#         errno merely moved from ENOSYS to EPERM -- frugal's own refusal,
#         reported by a log_debug_errno() the cmdline's systemd.log_level=info
#         was suppressing. Sending SIGRTMIN+22 to PID 1 raised the level at
#         runtime and produced "Refusing to loop over 2147483583 potential fds."
#         once per failure, 1:1, same PID, sub-millisecond apart. Upstream's
#         comment above MAX_FD_LOOP_LIMIT names the /proc/self/fd walk as the
#         case it bounds, so this reinstates that walk for the no-close_range()
#         path and leaves frugal as the last resort.
#   0011  0002 reads the mount id out of /proc/self/fdinfo when statx() reports
#         none, but only under XSTATX_MNT_ID_BEST. fds_inode_and_mount_same()
#         names STATX_MNT_ID in its own mandatory mask instead, and fd_is_root()
#         calls it, which puts it under every chase(). Stage-2 attempt 6: the
#         first boot that reached Multi-User with units actually running --
#         adbd, tailscaled and fb-refresher up, which is what confirmed 0010 --
#         but degraded, with 23 units dead at step NAMESPACE on "Protocol driver
#         not attached". Restarting logrotate under SIGRTMIN+22 named it:
#         "statx() does not support 'STATX_MNT_ID' mask". Not 0006's
#         STATX_ATTR_MOUNT_ROOT fallback -- '/' and /etc/resolv.conf fail the
#         same way, so it does not turn on the path being a directory. Keying
#         the fallback off request_mask instead covers both callers at once.
#   0012  fsmount_credentials_fs() opens with fsopen(), Linux 5.2, and the
#         credentials mount is moved into place with move_mount(), also 5.2.
#         setup_credentials_internal() already falls back to a plain directory,
#         but only for privilege errors, and ENOSYS is not one. Same attempt 6:
#         restarting the failed units one at a time showed they do not share a
#         cause. The units carrying credentials -- journald, sysctl and the
#         tmpfiles set among them -- die at step CREDENTIALS on "Function not
#         implemented", strictly earlier than the STATX_MNT_ID units 0011 fixes,
#         which is why 23 failures looked like one bug until each was reproduced
#         on its own.
#   0013  0006 gave is_mount_point_at() an st_dev fallback for kernels that never
#         report STATX_ATTR_MOUNT_ROOT, and its own comment names the hole: that
#         test cannot see a bind mount that stays inside one file system. It also
#         opens O_DIRECTORY, so it answers -ENOTDIR on a regular file and 0006
#         then re-raises the original -EUNATCH. Stage-2 attempt 7, the first boot
#         with 0010, 0011 and 0012 all deployed rather than swapped in: steps FDS
#         and CREDENTIALS both at 0 and no STATX_MNT_ID mask errors -- all three
#         confirmed -- but 9 failed units and 20 still dying at step NAMESPACE.
#         Under SIGRTMIN+22, 15 of the 20 name a read-only bind mount of a
#         regular file, /etc/resolv.conf and /proc/sys/kernel/domainname, which
#         is both holes at once. Comparing an inode's mount id against its
#         parent's answers for any inode type and sees a same-file-system bind
#         mount; it works here only because 0002 and 0011 already recover that id
#         from /proc/self/fdinfo. That dependency is why it is layered under
#         0006's test rather than replacing it: reading the mount id reads
#         /proc, and mount_setup() -- whose failure is what froze PID 1 in
#         stage-2 attempt 1 -- asks whether /proc is a mount point before
#         mounting it. st_dev runs first and a positive from it is definitive;
#         mount ids only settle the negatives.
#   0014  mount_procfs() writes ProtectProc= and ProcSubset= into the mount
#         options symbolically, and both hidepid=<name> and subset= are Linux
#         5.8. procfs rejects the whole string over one unknown element, exactly
#         as cgroup2 does in 0007. The other 5 of attempt 7's 20. Measured in a
#         private mount namespace on the device: hidepid=invisible EINVAL,
#         subset=pid EINVAL, hidepid=1 and hidepid=2 both fine -- so the
#         capability is there under the older spelling. Retries once with the
#         numeric form, dropping subset= because there is nothing to translate it
#         to.
#   0015  SCMP_ACT_KILL_PROCESS is Linux 4.14. A unit with any SystemCall*=
#         setting got a filter this kernel refuses to load, and systemd treats
#         that as fatal to the exec: dhcpcd.service and logrotate.service both
#         died 228/SECCOMP, restarting until they burned their start limit --
#         which is also what littered /var/tmp with the
#         systemd-private-*-dhcpcd.service-* directories 0017 then choked on.
#         The gate is libseccomp's own seccomp_api_get() >= 3, not a uname
#         check: API level 3 is exactly where SECCOMP_RET_KILL_PROCESS becomes
#         usable, and it probes the running kernel rather than trusting a
#         version string. Falls back to SCMP_ACT_KILL, which kills the offending
#         thread instead of the process -- weaker, and still a kill.
#         Deployed: both units ExecMainStatus=0, NRestarts=0, no 228 anywhere.
#         Note the call site moved: systemd 254 split exec-invoke.c out into
#         /lib/systemd/systemd-executor, so that binary imports the new symbol
#         and libsystemd-core-261.so does not. Looking only at the library is
#         what makes a correctly applied patch look unwired.
#   0016  NS_GET_NSTYPE is Linux 4.11, and fd_is_namespace() had no answer
#         without it, so systemd-machine-id-commit could not confirm it was
#         looking at the right thing and failed every boot -- leaving the id
#         only in the tmpfs overlay, regenerated on each boot. nsfs names its
#         inodes `mnt:[4026531840]`, and that prefix is already in the tree as
#         namespace_info[].proc_name, so readlink on /proc/self/fd/N recovers
#         the type the ioctl would have returned. Layered under the ioctl on
#         ERRNO_IS_IOCTL_NOT_SUPPORTED, so a kernel that has it is untouched.
#         Deployed: commits once, and the same id survives a reboot -- after
#         which the unit correctly skips itself with "unmet condition check
#         ConditionPathIsMountPoint=/etc/machine-id".
#   0017  STATX_ATTR_MOUNT_ROOT is Linux 5.8, and tmpfiles asked for it as a
#         *mandatory* attribute at both statx() sites in the cleanup path.
#         xstatx_full() therefore returned EUNATCH before filling in the mode,
#         uid and timestamps that were the actual reason for the call, so every
#         entry failed and systemd-tmpfiles-clean.service exited 73. The
#         attribute only ever answers "is this the root of another mount, and
#         so not mine to clean?", so it is now requested optionally and
#         is_mount_point_at() -- taught to answer here by 0013 -- settles it
#         when the kernel stays silent. Testing stx_attributes_mask rather than
#         stx_attributes is load-bearing: an absent attribute would otherwise
#         read as a cleared one, and the failure mode flips from refusing to
#         clean to cleaning across a mount boundary.
#         Deployed: zero EUNATCH, with per-entry decisions visible in the debug
#         log. Worth recording that the obvious test of this is invalid -- a
#         stale file built with `touch -d` is not stale, because age-by
#         defaults include ctime and touch cannot backdate it.
#
# That closes the list, for now: attempt 9 reached `systemctl is-system-running`
# = running with zero failed units, across two consecutive boots. Expect more of
# these anyway, as unrelated units grow settings that reach for newer syscalls.
# The alternative is pinning nixpkgs to a systemd old enough to still support
# this kernel, which trades a small number of local patches for a very large
# version downgrade across the whole system.
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
{lib, ...}: {
  nixpkgs.overlays = [
    (final: prev:
      lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
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
        systemd = (prev.systemd.override {withLibBPF = false;}).overrideAttrs (old: {
          patches = (old.patches or []) ++ import ../patches/systemd;
        });
      })
  ];
}
