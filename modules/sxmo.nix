# Sxmo as an X11 session, built from wentam/sxmo-nix's packages.
#
# Its NixOS modules are not imported. They target option paths nixpkgs removed
# years ago (`fonts.fonts`, `services.xserver.libinput`,
# `services.xserver.displayManager.{autoLogin,defaultSession,sessionPackages}`)
# and their display-manager half exists to toggle between dwm and sway, which is
# not a choice on a device with no KMS. The packages are current enough; the
# wiring is done here.
{
  config,
  lib,
  pkgs,
  sxmo-nix,
  ...
}: let
  cfg = config.mobile.session;

  # These trees stopped being touched in 2022 and GCC 14 turned several
  # long-standing C warnings into errors by default. The promotion is not tied
  # to `-std`, so selecting an older dialect does not undo it -- each one has to
  # be named. `_XOPEN_SOURCE` is separate: it is what actually declares
  # wcwidth() in codemadness-frontends' util.c, rather than silencing the
  # complaint about calling it undeclared.
  preC23 = drv:
    drv.overrideAttrs (old: {
      NIX_CFLAGS_COMPILE = toString [
        (old.NIX_CFLAGS_COMPILE or "")
        "-Wno-error=implicit-function-declaration"
        "-Wno-error=incompatible-pointer-types"
        "-Wno-error=int-conversion"
        "-D_XOPEN_SOURCE=700"
        "-D_DEFAULT_SOURCE"
      ];
    });

  # Only what nixpkgs does not already carry. nixpkgs' mmsd-tng, superd, mnc and
  # proycon-wayout are all newer than sxmo-nix's copies and are taken from there
  # implicitly -- sxmo-nix's mmsd-tng 1.9 still wants libsoup 2, which nixpkgs
  # has removed as end-of-life.
  sxmoPkgs = rec {
    # sxmo-nix builds this as `dwm.overrideAttrs`, so it inherits upstream dwm's
    # buildInputs -- which have no libxcb, because upstream dwm does not link
    # it. sxmo's fork does (`-lX11-xcb -lxcb -lxcb-res`, for window swallowing).
    sxmo-dwm = preC23 (
      (pkgs.callPackage "${sxmo-nix}/pkgs/sxmo-dwm" {}).overrideAttrs (old: {
        buildInputs = (old.buildInputs or []) ++ [pkgs.libxcb];
      })
    );
    sxmo-st = preC23 (pkgs.callPackage "${sxmo-nix}/pkgs/sxmo-st" {});
    sxmo-dmenu = preC23 (pkgs.callPackage "${sxmo-nix}/pkgs/sxmo-dmenu" {});
    # ninja and protoc are build-host tools, but sxmo-nix lists them in
    # buildInputs. Native builds put those on PATH anyway, so the mistake only
    # surfaces when cross-compiling -- as meson failing to detect ninja at all.
    vvmd = preC23 (
      (pkgs.callPackage "${sxmo-nix}/pkgs/vvmd" {}).overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [])
          ++ [
            pkgs.ninja
            pkgs.protobuf
          ];
      })
    );
    codemadness-frontends = preC23 (pkgs.callPackage "${sxmo-nix}/pkgs/codemadness-frontends" {});

    sxmo-utils = pkgs.callPackage "${sxmo-nix}/pkgs/sxmo-utils" {
      inherit
        sxmo-dwm
        sxmo-st
        sxmo-dmenu
        vvmd
        codemadness-frontends
        ;

      # swmo needs sway, sway needs KMS. Off here also drops the whole
      # wayland closure from the cross build.
      waylandSupport = false;

      # `light` was removed from nixpkgs as unmaintained; `pn` is not packaged
      # there at all. Everything else sxmo-utils asks for still resolves.
      light = pkgs.brightnessctl;
      pn = pkgs.emptyDirectory;

      # youtube-dl is marked insecure and unmaintained, and only sxmo_youtube.sh
      # uses it. yt-dlp is not a drop-in here: it provides no `youtube-dl`
      # binary, so the script stays broken either way, and it drags in deno ->
      # rusty-v8 -> a rust toolchain whose clippy does not cross-compile.
      youtube-dl = pkgs.emptyDirectory;

      # mpv reaches Qt 6 by a route nothing here asks for: mpv ->
      # libdisplay-info -> v4l-utils, whose qv4l2/qvidcap GUIs are built by
      # default, and libdisplay-info wants v4l-utils only to run its tests. That
      # is qtbase, qttools, qttranslations and qt5compat cross-built so a media
      # player can read EDIDs on a panel with no EDID. Only sxmo_youtube.sh,
      # sxmo_record.sh playback and the notification sounds use it.
      mpv = pkgs.emptyDirectory;

      # The keypress click. Opt-in upstream -- it appears only in commented-out
      # KEYBOARD_ARGS lines in profile_template -- and it costs sdl2-compat ->
      # sdl3 -> zenity -> gtk4, because SDL3 shells out to zenity for message
      # boxes.
      clickclack = pkgs.emptyDirectory;

      # svkbd's config.mk calls `pkg-config` by its bare name. Cross builds
      # install the wrapper under a target prefix only, so the call resolves to
      # nothing, every `--cflags`/`--libs` expands empty, and the link fails on
      # a missing libfontconfig rather than on anything to do with the keyboard.
      svkbd = pkgs.svkbd.overrideAttrs (old: {
        postPatch =
          (old.postPatch or "")
          + ''
            substituteInPlace config.mk Makefile \
              --replace-quiet pkg-config ${pkgs.stdenv.cc.targetPrefix}pkg-config
          '';
      });
    };
  };

  # sxmo_hook_scripts.sh builds the Scripts menu from every executable under
  # `xdg_data_path sxmo/appscripts`, and environment.pathsToLink merges each
  # package's share/ into one tree -- so a menu entry is a package, with no
  # mutable dotfile to seed. The `# title=` line is parsed by that hook.
  #
  # sxmo's own `sxmo_power.sh logout` is not usable here: it decides how to end
  # the session by reading /var/lib/tinydm/default-session.desktop, and this
  # device has no display manager, so neither branch matches and nothing
  # happens. Killing dwm ends xinit, which returns from sxmo_xinit.sh into the
  # login shell that called it.
  ttyModeApp = pkgs.writeTextFile {
    name = "sxmo-appscript-tty-mode";
    destination = "/share/sxmo/appscripts/sxmo_tty_mode.sh";
    executable = true;
    text = ''
      #!/bin/sh
      # title="TTY mode (leave sxmo)"
      session-mode tty
      sxmo_hook_logout.sh
      ${pkgs.procps}/bin/pkill dwm
    '';
  };
in {
  options.mobile.session.sxmo.enable = lib.mkEnableOption "the sxmo X11 session";

  config = lib.mkIf cfg.sxmo.enable {
    services.xserver.enable = true;

    # The only Xorg driver that does not need KMS. It writes into the mmap'd
    # framebuffer, so a panel that only composites on FBIOPAN_DISPLAY still
    # needs mobile.quirks.fb-refresher.
    services.xserver.videoDrivers = ["fbdev"];

    # No display manager: `startx` is what the session hook below runs.
    services.xserver.displayManager.startx.enable = true;
    services.displayManager.sessionPackages = [sxmoPkgs.sxmo-utils];
    services.displayManager.defaultSession = "sxmo";

    services.libinput.enable = lib.mkDefault true;

    # Anything declaring a session pulls in nixpkgs' graphical-desktop baseline,
    # which turns speech-dispatcher on by default. sxmo has no text-to-speech,
    # and it is not a cheap dependency: speechd -> espeak-ng -> ffmpeg ->
    # sdl2-compat -> sdl3, all of which have to be built natively as well for
    # espeak-ng's data generator.
    services.speechd.enable = false;

    environment.systemPackages =
      [
        sxmoPkgs.sxmo-utils
        pkgs.superd
      ]
      ++ lib.optional cfg.graphical.autostart ttyModeApp;

    # sxmo reads hooks, superd services and its own configuration out of
    # /run/current-system/sw/share.
    environment.pathsToLink = ["/share"];
    services.udev.packages = [sxmoPkgs.sxmo-utils];
    # The same graphical-desktop baseline turns on the default font set, which
    # is noto-fonts-cjk-{sans,serif} plus noto-fonts-color-emoji. The emoji one
    # runs zopflipng over a few thousand PNGs at build time, and none of it is
    # substitutable on a cross build. dwm and st ask fontconfig for "monospace",
    # so DejaVu is the whole requirement.
    fonts.enableDefaultPackages = false;
    fonts.packages = [
      pkgs.dejavu_fonts
      pkgs.nerd-fonts.symbols-only
    ];

    powerManagement.enable = lib.mkDefault true;

    # sxmo binds the power button to its own menu.
    services.logind.settings.Login.HandlePowerKey = lib.mkDefault "ignore";

    # sxmo shells out to doas for these. Kept here rather than taking
    # sxmo-utils' own rules, so the privileged set is reviewable in one place.
    security.doas.enable = true;
    security.doas.extraConfig = ''
      permit persist :wheel
      permit nopass :wheel as root cmd poweroff
      permit nopass :wheel as root cmd reboot
      permit nopass :wheel as root cmd rtcwake
      permit nopass :wheel as root cmd systemctl args poweroff
      permit nopass :wheel as root cmd systemctl args reboot
      permit nopass :wheel as root cmd sxmo_wifitoggle.sh
      permit nopass :wheel as root cmd sxmo_bluetoothtoggle.sh
      permit nopass :wheel as root cmd systemctl args restart bluetooth
      permit nopass :wheel as root cmd systemctl args start ModemManager
      permit nopass :wheel as root cmd systemctl args stop ModemManager
    '';

    # Not `exec`: replacing the login shell leaves nothing to return to, so
    # quitting sxmo -- or X failing to start at all -- ends the shell, getty
    # respawns it, autologin fires and the session restarts. That is an
    # unbreakable loop on a device with no keyboard. Falling through to the
    # shell instead makes "quit" mean tty until the next login, and
    # `session-mode tty` makes it mean tty until told otherwise.
    environment.loginShellInit = lib.mkIf cfg.graphical.autostart ''
      if [ "$(tty)" = /dev/tty1 ] && [ ! -e ${cfg.graphical.overrideFlag} ]; then
        sxmo_xinit.sh
      fi
    '';
  };
}
