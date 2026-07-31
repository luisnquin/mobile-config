# Key-authenticated root SSH over the USB gadget during stage-1.
#
# Deliberately not `mobile.boot.stage-1.ssh.enable`: that option runs
# `passwd -d root` and starts dropbear with `-B`, which upstream documents as
# "OPENS ACCESS TO ALL WITHOUT A PASSWORD NOR SSH KEY".
#
# The device needs a USB network function declared for this to be reachable.
# `mobile.usb.gadgetfs.functions` composes, so adb stays up alongside it.
{ pkgs, ... }:

let
  authorizedKeys = import ../authorized-keys.nix;

  authorizedKeysFile = pkgs.writeText "authorized-keys" (
    builtins.concatStringsSep "\n" authorizedKeys + "\n"
  );
in
{
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
    { object = authorizedKeysFile; symlink = "/etc/authorized_keys"; }
  ];

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
          System.spawn("dropbear", "-R", "-s", "-E")
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
