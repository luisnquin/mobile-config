# Key-authenticated SSH over the USB gadget during stage-1.
#
# This deliberately does not use `mobile.boot.stage-1.ssh.enable`. That option
# (mobile-nixos/modules/initrd-ssh.nix) runs `passwd -d root` and starts
# dropbear with `-B`, which is documented upstream as
# "OPENS ACCESS TO ALL WITHOUT A PASSWORD NOR SSH KEY". Anyone on the USB bus
# gets root. What is wanted here is one named key, so the daemon is configured
# directly instead.
#
# Transport is RNDIS, not ECM: the running kernel has CONFIG_USB_F_RNDIS=y and
# CONFIG_USB_CONFIGFS_RNDIS=y, while CONFIG_USB_CONFIGFS_ECM and _NCM are unset
# (read from /proc/config.gz on the device). `rndis = "rndis.usb0"` is already
# declared in ../devices/xiaomi-dandelion/default.nix, and enabling networking
# below is what finally appends "rndis" to the gadget's function list
# (modules/initrd-usb.nix:104). It composes with "adb" in the same config, so
# adb stays up alongside it.
#
# The stage-1 /etc/passwd already reads `root:*:0:0:root:/root:/bin/sh` and
# /root is 0700 root-owned, so pubkey auth needs no account setup: the password
# field is locked and `-s` refuses password auth outright.
{ pkgs, ... }:

let
  authorizedKeys = import ../authorized-keys.nix;

  authorizedKeysFile = pkgs.writeText "dandelion-authorized-keys" (
    builtins.concatStringsSep "\n" authorizedKeys + "\n"
  );
in
{
  # Adds "rndis" to the gadget and installs the udhcpd task that addresses the
  # interface (172.16.42.1) and leases 172.16.42.2 to the host.
  mobile.boot.stage-1.networking.enable = true;

  # libnss_files is not optional: dropbear resolves the account through NSS, and
  # the initrd's glibc has no compiled-in files backend. Mirrors what
  # modules/adb.nix does for adbd.
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
