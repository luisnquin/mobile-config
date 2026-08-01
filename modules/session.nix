# Stage-2 session policy, shared by every device: a TTY by default, a graphical
# session only when one is asked for.
{ config, lib, ... }:

let
  cfg = config.mobile.session;
in
{
  options.mobile.session = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "mobile";
      description = "Unprivileged account that owns the on-device session.";
    };

    graphical.autostart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Start the graphical session from tty1 at boot. When false the device
        boots to a shell and the session is started by hand.
      '';
    };
  };

  config = {
    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "video"
        "input"
        "audio"
        "dialout"
      ];
      openssh.authorizedKeys.keys = import ../authorized-keys.nix;

      # Empty rather than locked: an account with no password cannot use `doas`
      # at all, and these devices have no usable keyboard until touch works. An
      # unlocked bootloader already grants anyone holding the phone root.
      hashedPassword = "";
    };

    users.users.root.openssh.authorizedKeys.keys = import ../authorized-keys.nix;

    services.getty.autologinUser = cfg.user;

    services.openssh.enable = true;
    services.openssh.settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };

    # Enabling any X session makes NixOS default to graphical.target. Both modes
    # boot to the same place; only the login-shell hook differs.
    systemd.defaultUnit = lib.mkForce "multi-user.target";
  };
}
