# On-panel dashboard, driven by the three hardware keys the mt6765 keypad
# reports: power, volume up, volume down.
#
# The backlight toggle writes the LED brightness and never
# /sys/class/graphics/fb0/blank: writing 4 there deadlocks mtkfb, leaving the
# writer and both msm-fb-refresher processes in uninterruptible sleep until the
# next reboot. There is no /sys/class/backlight on this device.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.console;

  stateDir = "/run/display";
  brightness = "${cfg.backlight}/brightness";
  keysSocket = "${stateDir}/keys.sock";

  # sd-bus and sd-journal, so the dashboard reads unit state and logs without
  # forking systemctl and journalctl on every repaint. The cc wrapper carries
  # the include and library paths for buildInputs, which pkg-config would only
  # duplicate -- under a target prefix that plain `pkg-config` does not answer
  # to when cross-compiling.
  binary =
    pkgs.runCommandCC "mobile-panel" {
      buildInputs = [pkgs.systemd];
    } ''
      mkdir -p $out/bin
      $CC -O2 -Wall -Wextra -std=gnu11 -o $out/bin/panel ${./panel.c} -lsystemd
    '';

  # Shared by every entry point: which nodes to touch, and where the level
  # survives a screen-off.
  commonArgs = [
    "--backlight"
    cfg.backlight
    "--state-dir"
    stateDir
    "--default-brightness"
    (toString cfg.defaultBrightness)
  ];

  keysArgs =
    commonArgs
    ++ [
      "--keys"
      cfg.keys.device
      "--socket"
      keysSocket
      "--hold-ms"
      (toString cfg.keys.holdMs)
      "--repeat-ms"
      (toString cfg.keys.repeatMs)
      "--power"
      (toString cfg.keys.power)
      "--vol-up"
      (toString cfg.keys.volumeUp)
      "--vol-down"
      (toString cfg.keys.volumeDown)
    ];

  dashboardArgs =
    commonArgs
    ++ [
      "--interval"
      (toString cfg.interval)
      "--log-lines"
      (toString cfg.logLines)
      "--top-margin"
      (toString cfg.topMargin)
      "--tailscale"
      "${config.services.tailscale.package}/bin/tailscale"
    ]
    ++ lib.optionals (cfg.subtitle != "") ["--subtitle" cfg.subtitle]
    ++ lib.optionals (cfg.loadNote != "") ["--load-note" cfg.loadNote]
    ++ lib.concatMap (s: ["--service" s]) cfg.services
    ++ lib.optionals cfg.keys.enable ["--socket" keysSocket];

  # makeWrapper word-splits --add-flags, which would tear the subtitle apart.
  panel = pkgs.writeShellScriptBin "panel" ''
    exec ${binary}/bin/panel ${lib.escapeShellArgs dashboardArgs} "$@"
  '';

  display = pkgs.writeShellScriptBin "display" ''
    exec ${binary}/bin/panel display ${lib.escapeShellArgs commonArgs} "$@"
  '';
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
      description = "Seconds between repaints.";
    };

    logLines = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3000;
      description = ''
        Trailing lines a log view collects. The whole boot is 640k lines on a
        port this noisy.
      '';
    };

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the dashboard from tty1's login shell. It is ordered after the
        graphical session's own hook, which returns rather than execs, so the
        dashboard picks up tty1 whenever the session declines to start, fails
        to start, or is quit. On a device with no keyboard that is the only
        useful thing to fall through to. Quitting it with `q` leaves a plain
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
      default = 1200;
      description = ''
        Level restored when no previous level was recorded. Against this
        panel's max_brightness of 2047 the old default of 200 was a tenth of
        the range: legible in a dark room and not otherwise, which is a poor
        thing to fall back to when the reason no level was recorded is usually
        that something just restarted.
      '';
    };

    keys = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Drive the dashboard from the hardware keys. A held power key opens
          the menu, the volume keys move through it, a power click selects.
        '';
      };

      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/input/event1";
        description = ''
          evdev node carrying the keys. Numbering is driver probe order, so
          check /proc/bus/input/devices before changing it.
        '';
      };

      power = lib.mkOption {
        type = lib.types.ints.positive;
        default = 116;
        description = "Linux key code for the power key. 116 is KEY_POWER.";
      };

      volumeUp = lib.mkOption {
        type = lib.types.ints.positive;
        default = 115;
        description = "Linux key code for volume up. 115 is KEY_VOLUMEUP.";
      };

      volumeDown = lib.mkOption {
        type = lib.types.ints.positive;
        default = 114;
        description = "Linux key code for volume down. 114 is KEY_VOLUMEDOWN.";
      };

      holdMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 500;
        description = ''
          Milliseconds a key must stay down to count as a hold rather than a
          click. Announced as it passes, so the panel reacts before release.

          A release before the threshold is the only thing that emits a click,
          so the two can never both fire and this only has to sit above an
          ordinary tap.
        '';
      };

      repeatMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = ''
          Milliseconds between steps once a volume key is held past the hold
          threshold. This keypad reports no EV_REP, so without a synthesized
          repeat a held key moves a menu by one entry and a log by one screen.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      display
      panel
    ];

    # udev's 90-backlight.rules cannot run here, so the session user gets write
    # access to the brightness node this way instead. The key socket takes the
    # same group from this directory when the daemon binds it.
    systemd.tmpfiles.rules =
      [
        "d ${stateDir} 0775 root video -"
        "z ${brightness} 0664 root video -"
      ]
      ++ lib.optional cfg.quietConsole "w /sys/module/printk/parameters/ignore_loglevel - - - - N";

    boot.kernel.sysctl = lib.mkIf cfg.quietConsole {"kernel.printk" = "3 4 1 7";};

    # `consoleblank=0` on the cmdline is the real fix, but that only arrives with
    # a flashed boot image, and a rootfs deploy has to be able to correct this on
    # its own. Both sequences are written straight to the console rather than run
    # through setterm: setterm resolves the terminal type before emitting
    # anything, and with TERM unset -- which it is under systemd -- it silently
    # emits nothing. That failure mode is invisible; the check is
    # /sys/module/kernel/parameters/consoleblank, which must read 0.
    #
    #   ESC [ 9 ; 0 ]   blankinterval = 0, disarming the timer (vt.c case 9)
    #   ESC [ 13 ]      poke_blanked_console(), for a console already blanked
    systemd.services.console-noblank = {
      description = "Disarm the VT blank timer";
      wantedBy = ["multi-user.target"];
      before = ["getty@tty1.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "tty";
        TTYPath = "/dev/tty1";
        ExecStart = "${pkgs.runtimeShell} -c 'printf \"\\033[9;0]\\033[13]\"'";
      };
    };

    # Holds the evdev grab for the whole uptime, so the dashboard can come and
    # go with tty1's login shell without the keys changing hands. With nothing
    # connected the power key is still the on/off switch.
    systemd.services.console-keys = lib.mkIf cfg.keys.enable {
      description = "Feed the hardware keys to the panel dashboard";
      wantedBy = ["multi-user.target"];
      after = ["systemd-tmpfiles-setup.service"];
      serviceConfig = {
        ExecStart = "${binary}/bin/panel keys ${lib.escapeShellArgs keysArgs}";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # The dashboard is a child of tty1's login shell, so it belongs to no unit
    # and `switch-to-configuration` cannot replace it: a deploy leaves the
    # previous generation's wrapper running indefinitely. On 2026-08-09 two
    # generations' panels ran at once and drove the backlight to 0 and to 200
    # alternately, a second or two apart, for hours.
    #
    # Retiring it by restarting the getty was tried and reverted. NixOS already
    # owns `systemd.services."getty@tty1"` -- that is where tty1's autologin
    # ExecStart is defined -- so adding restartTriggers with
    # `overrideStrategy = "asDropin"` demoted the whole unit to a drop-in and
    # left only the vendor template behind it, whose ExecStart is
    # `-/usr/bin/agetty`. That path does not exist here, so the next start
    # exited 203, Restart=always burned the start limit, and tty1 was left with
    # no login at all. Restarting the getty by hand is safe; making a deploy do
    # it through that attribute is not.
    #
    # Retire a stale dashboard with `systemctl restart getty@tty1` instead, and
    # give it time: the stop can sit in final-sigterm for the full
    # TimeoutStopSec before the login session lets go.

    services.logind.settings.Login = {
      HandlePowerKey = "ignore";
      HandlePowerKeyLongPress = "ignore";
    };

    # mkAfter so the graphical session's hook gets tty1 first; that hook returns
    # rather than execs, so this runs whenever it declines or fails. Not `exec`:
    # quitting the dashboard has to leave a shell behind, or getty autologins
    # straight back into it.
    environment.loginShellInit = lib.mkIf cfg.autostart (lib.mkAfter ''
      if [ "$(tty)" = /dev/tty1 ]; then
        panel
      fi
    '');
  };
}
