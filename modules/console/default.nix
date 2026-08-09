# On-panel dashboard, and the power key as the panel's on/off switch.
#
# The toggle writes the LED brightness and never /sys/class/graphics/fb0/blank:
# writing 4 there deadlocks mtkfb, leaving the writer and both msm-fb-refresher
# processes in uninterruptible sleep until the next reboot. There is no
# /sys/class/backlight on this device.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.console;

  stateDir = "/run/display";
  brightness = "${cfg.backlight}/brightness";

  evdevKey = pkgs.runCommandCC "evdev-key" {} ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Wextra -o $out/bin/evdev-key ${./evdev-key.c}
  '';

  display = pkgs.writeShellApplication {
    name = "display";
    runtimeInputs = [pkgs.coreutils];
    text =
      ''
        backlight=${brightness}
        saved=${stateDir}/brightness
        fallback=${toString cfg.defaultBrightness}
      ''
      + builtins.readFile ./display.sh;
  };

  powerKeyDaemon = pkgs.writeShellApplication {
    name = "display-power-key";
    runtimeInputs = [
      evdevKey
      display
    ];
    text = ''
      evdev-key "$1" "$2" | while read -r _; do
        display toggle
      done
    '';
  };

  panel = pkgs.writeShellApplication {
    name = "panel";
    # Every reading is best-effort against a device that may not expose it; a
    # dashboard that exits over one missing sysfs file is worse than a dash.
    bashOptions = [];
    runtimeInputs = [
      display
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.iproute2
      pkgs.less
      pkgs.procps
      pkgs.util-linux
      config.services.tailscale.package
      config.systemd.package
    ];
    text =
      ''
        backlight=${brightness}
        backlight_max=$(cat ${cfg.backlight}/max_brightness 2>/dev/null || echo 0)
        interval=${toString cfg.interval}
        top_margin=${toString cfg.topMargin}
        services=(${lib.concatMapStringsSep " " lib.escapeShellArg cfg.services})
        subtitle=${lib.escapeShellArg cfg.subtitle}
        load_note=${lib.escapeShellArg cfg.loadNote}
      ''
      + builtins.readFile ./status.sh;
  };
in {
  options.mobile.console = {
    enable = lib.mkEnableOption "the on-panel dashboard and power-key display toggle";

    subtitle = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "xiaomi redmi 9a . mt6765";
      description = "Hardware line printed beside the hostname and clock.";
    };

    loadNote = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Parenthetical printed after the load average. Meant for ports whose
        idle load is not zero, where an unannotated figure reads as a fault.
      '';
    };

    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "sshd:22"
        "tailscaled"
      ];
      example = ["postgresql:5432"];
      description = ''
        Units to show state and memory for, as `name` or `name:port`. A port
        adds a count of established connections to it.
      '';
    };

    topMargin = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 5;
      description = ''
        Blank rows above the first line. Enough to clear rounded corners and a
        camera cutout, both of which sit over the first rows of the console.
      '';
    };

    quietConsole = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep kernel messages off the console so they do not overwrite the
        dashboard. Clears `ignore_loglevel`, which the boot image sets on the
        cmdline and which otherwise forces every message through regardless of
        `kernel.printk`. Turn it off when bringing up a kernel, where losing
        console output costs more than a legible panel.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Seconds between repaints, and how long a keypress waits.";
    };

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = !(config.mobile.session.sxmo.enable && config.mobile.session.graphical.autostart);
      defaultText = lib.literalExpression ''
        !(config.mobile.session.sxmo.enable && config.mobile.session.graphical.autostart)
      '';
      description = ''
        Run the dashboard from tty1's login shell, whenever a graphical session
        is not already claiming that tty. Quitting it with `q` leaves a plain
        shell behind, and it comes back on the next login.
      '';
    };

    backlight = lib.mkOption {
      type = lib.types.str;
      default = "/sys/class/leds/lcd-backlight";
      description = "LED class directory driving the panel.";
    };

    defaultBrightness = lib.mkOption {
      type = lib.types.ints.positive;
      default = 200;
      description = "Level restored when no previous level was recorded.";
    };

    powerKey = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Toggle the panel when the power key is pressed.";
      };

      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/input/event1";
        description = ''
          evdev node carrying the power key. Numbering is driver probe order,
          so check /proc/bus/input/devices before changing it.
        '';
      };

      code = lib.mkOption {
        type = lib.types.ints.positive;
        default = 116;
        description = "Linux key code to act on. 116 is KEY_POWER.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      display
      panel
    ];

    # udev's 90-backlight.rules cannot run here, so the session user gets write
    # access to the brightness node this way instead.
    systemd.tmpfiles.rules =
      [
        "d ${stateDir} 0775 root video -"
        "z ${brightness} 0664 root video -"
      ]
      ++ lib.optional cfg.quietConsole "w /sys/module/printk/parameters/ignore_loglevel - - - - N";

    boot.kernel.sysctl = lib.mkIf cfg.quietConsole {"kernel.printk" = "3 4 1 7";};

    systemd.services.display-power-key = lib.mkIf cfg.powerKey.enable {
      description = "Toggle the panel backlight from the power key";
      wantedBy = ["multi-user.target"];
      after = ["systemd-tmpfiles-setup.service"];
      serviceConfig = {
        ExecStart = "${powerKeyDaemon}/bin/display-power-key ${cfg.powerKey.device} ${toString cfg.powerKey.code}";
        Restart = "always";
        RestartSec = 5;
      };
    };

    services.logind.powerKey = "ignore";
    services.logind.powerKeyLongPress = "ignore";

    # Not `exec`: quitting the dashboard has to leave a shell behind, or getty
    # autologins straight back into it.
    environment.loginShellInit = lib.mkIf cfg.autostart ''
      if [ "$(tty)" = /dev/tty1 ]; then
        panel
      fi
    '';
  };
}
