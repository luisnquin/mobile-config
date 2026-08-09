# Key-authenticated root SSH over the USB gadget during stage-1.
#
# Deliberately not `mobile.boot.stage-1.ssh.enable`: that option runs
# `passwd -d root` and starts dropbear with `-B`, which upstream documents as
# "OPENS ACCESS TO ALL WITHOUT A PASSWORD NOR SSH KEY".
#
# The device needs a USB network function declared for this to be reachable.
# `mobile.usb.gadgetfs.functions` composes, so adb stays up alongside it.
{pkgs, ...}: let
  authorizedKeys = import ../authorized-keys.nix;

  authorizedKeysFile = pkgs.writeText "authorized-keys" (
    builtins.concatStringsSep "\n" authorizedKeys + "\n"
  );
in {
  mobile.boot.stage-1.networking.enable = true;

  # dropbear resolves the account through NSS, and the initrd's glibc has no
  # compiled-in files backend.
  mobile.boot.stage-1.extraUtils = [
    {
      package = pkgs.dropbear;
      extraCommand = ''cp -fpv "${pkgs.glibc.out}"/lib/libnss_files.so.* "$out"/lib/'';
    }
  ];

  mobile.boot.stage-1.contents = [
    {
      object = authorizedKeysFile;
      symlink = "/etc/authorized_keys";
    }
  ];

  # This listener stops authenticating once stage-2 takes over, and that is not
  # fixable from stage-2's side. The process survives switch_root, but its root
  # directory keeps pointing at the initramfs, which stage-1 then empties:
  #
  #   # cat /proc/360/mountinfo | head -1
  #   0 0 0:1 / / rw - rootfs rootfs rw          <- not the ext4 root PID 1 uses
  #   # ls -la /proc/360/root/root/.ssh/
  #   total 0                                     <- the keys written below, gone
  #   # ls /proc/360/root/etc/passwd
  #   No such file or directory
  #
  # So it offers publickey, rejects the correct key, and logs nothing: with no
  # /etc/passwd, getpwnam("root") fails and there is no home directory left to
  # search for authorized_keys. Writing keys into stage-2's /root/.ssh does not
  # help, because that filesystem is not one this process can see.
  #
  # Port 2222 is therefore a stage-1 channel, and only that. Which port answers
  # identifies the stage: 2222 alone means stage-1, both open means stage-2 is
  # up and 22 is the one to use. Keeping the process alive is still worth it --
  # it holds the gadget's network function open across the handover -- it just
  # is not a rescue shell once stage-2 has its own sshd.
  mobile.boot.stage-1.tasks = [
    (pkgs.writeText "dropbear-pubkey-sshd-task.rb" ''
      class Tasks::DropbearPubkeySSHD < SingletonTask
        AUTHORIZED_KEYS = "/etc/authorized_keys"

        def initialize()
          add_dependency(:Target, :Networking)
          Targets[:SwitchRoot].add_dependency(:Task, self)
        end

        def run()
          install_authorized_keys()
          FileUtils.mkdir_p("/etc/dropbear")

          # -s  no password auth at all; the key is the only way in.
          # -R  generate host keys on demand. Baking one into the image would
          #     put a host private key in a world-readable /nix/store path.
          # -E  log to stderr, which is /dev/console, so failures land on the
          #     panel next to everything else.
          # -p  NOT 22. Nothing stops this process at switch_root, so it keeps
          #     running under stage-2 and holds whatever port it bound. On 22 it
          #     starves the real sshd, which then dies on "Address already in
          #     use" and burns through its start limit. Surviving is worth
          #     keeping -- it leaves a rescue channel that does not depend on
          #     adbd, which has wedged in ffs_epfile_io mid-transfer -- so move
          #     it aside instead of killing it.
          System.spawn("dropbear", "-R", "-s", "-E", "-p", "2222")
        end

        private

        # Copied rather than symlinked to /nix/store: dropbear rejects an
        # authorized_keys file it considers group- or world-writable, and
        # resolving the link would hand it a path it does not own.
        def install_authorized_keys()
          unless File.exist?(AUTHORIZED_KEYS)
            log("dropbear: no #{AUTHORIZED_KEYS}; refusing to start an sshd nobody can log into")
            return
          end

          FileUtils.mkdir_p("/root/.ssh")
          System.run("chmod", "700", "/root/.ssh")
          File.write("/root/.ssh/authorized_keys", File.read(AUTHORIZED_KEYS))
          System.run("chmod", "600", "/root/.ssh/authorized_keys")
        end
      end
    '')
  ];
}
