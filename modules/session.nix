# Stage-2 session policy, shared by every device: a TTY by default, a graphical
# session only when one is asked for.
{ config, lib, pkgs, ... }:

let
  cfg = config.mobile.session;

  sessionMode = pkgs.writeShellScriptBin "session-mode" ''
    flag=${cfg.graphical.overrideFlag}
    case "''${1:-status}" in
      tty)    mkdir -p "$(dirname "$flag")" && touch "$flag" && echo "tty from next login" ;;
      gui)    rm -f "$flag" && echo "gui from next login" ;;
      status) if [ -e "$flag" ]; then echo tty; else echo gui; fi ;;
      *)      echo "usage: session-mode [tty|gui|status]" >&2; exit 2 ;;
    esac
  '';
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

    graphical.overrideFlag = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mobile-session/tty-only";
      description = ''
        While this file exists, autostart is skipped and tty1 gets a plain
        shell. Managed with `session-mode tty` / `session-mode gui`.
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

    environment.systemPackages = [ sessionMode ];

    # Owned by the session user so `session-mode` needs no privileges: on a
    # device whose only keyboard is the graphical session's own on-screen one,
    # asking for doas to leave that session is a trap.
    systemd.tmpfiles.rules = [
      "d ${builtins.dirOf cfg.graphical.overrideFlag} 0755 ${cfg.user} users -"
    ];

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
