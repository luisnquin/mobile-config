# NetworkManager, for nmcli: wifi networks get joined from the device with
# `nmcli device wifi connect <ssid> --ask` instead of from this repository,
# which is the only workable shape for a network whose password nobody wants in
# a git history.
#
# Nothing here has a radio to drive yet. The mt6765 wlan driver is not built:
# drivers/misc/mediatek/connectivity/Makefile in the vendor tree descends into
# wlan/adaptor and wlan/core/gen4m only under CONFIG_WLAN_DRV_BUILD_IN=y, and
# dandelion_halium_defconfig leaves that unset, so the kernel ships the connadp
# adapter alone and /sys/class/net has no wlan0. `nmcli device` will report an
# empty list until that changes.
{
  config,
  lib,
  ...
}: let
  cfg = config.mobile.services.networkManager;
in {
  options.mobile.services.networkManager.enable =
    lib.mkEnableOption "NetworkManager and nmcli for wifi";

  config = lib.mkIf cfg.enable {
    networking.networkmanager = {
      enable = true;

      # NetworkManager claims every interface it is not told to leave alone,
      # and the first one it would find here is rndis0 -- the USB gadget that
      # carries every ssh session and every deploy, addressed by a scripted
      # unit in ./usb-network.nix that NetworkManager knows nothing about.
      # Losing it costs a physical power cycle. `*` followed by
      # `except:type:wifi` inverts the default so it manages a radio and
      # nothing else, which is the entire reason it is here.
      #
      # A type rather than a list of names, because a name list has to be right
      # about every interface that ever appears -- and this kernel already
      # exposes ifb0, ifb1 and four tunnel stubs. It also survives the udev
      # gap described in ./usb-network.nix: an interface whose record carries
      # no tags is still not wifi, so it stays unmanaged.
      unmanaged = [
        "*"
        "except:type:wifi"
      ];
    };

    # NetworkManager's module pulls ModemManager in by default. There is no
    # modem on this port -- sxmo's own probes answer "couldn't find the
    # ModemManager process in the bus" -- so it would be a daemon polling for
    # hardware that is not wired up.
    networking.modemmanager.enable = false;

    # NetworkManager drives wpa_supplicant over D-Bus, and NixOS hardens that
    # unit with RootDirectory=/run/wpa_supplicant. systemd 261 opens a root
    # directory through chase(), which asks statx() for a mount id; STATX_MNT_ID
    # is Linux 5.8, this kernel is 4.9, and the open comes back EUNATCH:
    #
    #   Failed to open service's root fs: /run/wpa_supplicant:
    #   Protocol driver not attached
    #   wpa_supplicant.service: Failed at step NAMESPACE
    #
    # Same shape as patch 0002 in ./systemd-linux-4.9.nix, at a call site that
    # patch does not reach. Dropped rather than turning off
    # `networking.wireless.enableHardening`, which would take the other thirty
    # directives with it -- and a daemon that parses frames off the air is the
    # last one to strip a sandbox from.
    systemd.services.wpa_supplicant.serviceConfig = {
      RootDirectory = lib.mkForce "";
      RootDirectoryStartOnly = lib.mkForce false;
    };

    # nmcli reaches NetworkManager over D-Bus and polkit decides who may change
    # anything. Without the group every command that is not a read answers
    # "not authorized".
    users.users.${config.mobile.session.user}.extraGroups = ["networkmanager"];
  };
}
