# Keeps the USB network alive after switch_root.
#
# The gadget itself survives: stage-1 builds it in configfs, and configfs is a
# kernel filesystem that stage-2 remounts (mobile-nixos/modules/usb-gadget.nix),
# so `rndis0` is still there and still bound to its UDC. What does not survive
# is everything stage-1 did in userspace -- the `ifconfig rndis0 <ip>` and the
# udhcpd that hands the build host its address, both from
# mobile-nixos/modules/stage-1/tasks/dhcpd-task.rb. Without replacing them,
# stage-2 comes up with an interface that has no address and a host that gets no
# lease, so the only way in is the panel.
#
# adb is not this module's problem: mobile.adbd.enable re-launches adbd against
# the same gadget.
{ config, lib, pkgs, ... }:

let
  cfg = config.mobile.services.usbNetwork;
in
{
  options.mobile.services.usbNetwork = {
    enable = lib.mkEnableOption "addressing and DHCP on the USB gadget's network interface";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "rndis0";
      description = "Gadget network interface. Stage-1 tries rndis0, usb0 and eth0 in that order.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "172.16.42.1";
      description = "Address given to the device. Matches the stage-1 default.";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "172.16.42.2";
      description = "The single address leased to whatever is plugged in.";
    };

    viaHostGateway = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Route the device's own traffic through the machine it is plugged into.
        That machine has to forward and masquerade for this to reach anything;
        without it the default route blackholes.
      '';
    };

    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "9.9.9.9" ];
      description = ''
        Resolvers to use with viaHostGateway. Not the host address: the DHCP
        server on this link answers no queries.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Addressing and routing done by hand, because NixOS's declarative path
    # cannot run on this interface.
    #
    # `networking.interfaces.<i>.ipv4.addresses` generates
    # network-addresses-<i>.service with BindsTo= and WantedBy= the
    # sys-subsystem-net-devices-<i>.device unit, and that device unit never
    # activates here. systemd synthesises .device units only for devices udev
    # has tagged "systemd", and rndis0's udev record is a stage-1 leftover --
    # /run is a tmpfs that survives switch_root, so stage-2's udevd inherits
    # /run/udev/data/n<ifindex> as stage-1 wrote it:
    #
    #   E:LD_LIBRARY_PATH=/nix/store/...-extra-utils-.../lib
    #   E:PATH=/nix/store/...-extra-utils-.../bin
    #
    # -- the initrd's own package, with no TAGS line. Rule 54 of
    # 99-systemd.rules (SUBSYSTEM=="net", TAG+="systemd") never ran for it, so
    # the address service sat at ConditionResult=no through a boot that
    # otherwise reached `running` with zero failed units. Nothing reports this:
    # the interface keeps the address stage-1 gave it, and the declarative
    # setting is simply never applied.
    #
    # Re-triggering the uevent would fix the class rather than the instance,
    # and is deliberately not done: a synthetic add on this vendor kernel is a
    # gamble on a device that needs a physical power cycle to recover, and
    # sweeping its device nodes has rebooted it before.
    systemd.services.usb-network-setup = {
      description = "Addressing on ${cfg.interface}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-pre.target" ];
      after = [ "network-pre.target" ];
      before = [ "network.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -e /sys/class/net/${cfg.interface} ]; then
          echo "${cfg.interface} is absent; the gadget did not survive switch_root" >&2
          exit 1
        fi

        # `replace` throughout: stage-1 has usually set the address already, and
        # this has to be a no-op in that case rather than an EEXIST.
        ip link set ${cfg.interface} up
        ip addr replace ${cfg.address}/24 dev ${cfg.interface}
      '' + lib.optionalString cfg.viaHostGateway ''
        ip route replace default via ${cfg.hostAddress} dev ${cfg.interface}
      '';
    };

    # networking.useDHCP is on for the sake of interfaces that do not exist yet
    # (wifi), and would otherwise have dhcpcd bid for an address on the one
    # interface that is meant to be serving them.
    #
    # ifb0 and ifb1 have to go with it. They are intermediate functional block
    # devices -- shaping stubs this kernel builds in, with no link to anywhere
    # -- but dhcpcd cannot tell that, bids on them, finds no server, and falls
    # back to IPv4LL. It then installs a default route out of ifb0, which on a
    # device with no other default route is *the* default route. Measured:
    #
    #   default dev ifb0 scope link src 169.254.183.20 metric 1001002
    #
    # Every packet meant to leave the device was being handed to a stub that
    # drops it, which is why tailscaled could never reach login.tailscale.com.
    networking.dhcpcd.denyInterfaces = [ cfg.interface "ifb*" ];

    services.dnsmasq = {
      enable = true;

      # DHCP only. Left on, this would also point the device's own resolver at
      # 127.0.0.1, which is a lie on a device with no upstream DNS.
      resolveLocalQueries = false;

      # rndis0 only appears once the host enumerates the gadget, which can be
      # after dnsmasq would first try to bind. Restart=always turns that race
      # into a delay.
      alwaysKeepRunning = true;

      settings = {
        interface = cfg.interface;
        bind-interfaces = true;
        port = 0;
        dhcp-authoritative = true;
        dhcp-range = "${cfg.hostAddress},${cfg.hostAddress},255.255.255.0,12h";
      };
    };

    # Not networking.defaultGateway: that is applied by the same scripted
    # networking that cannot run here, so the route is installed by
    # usb-network-setup above. nameservers stay declarative -- resolv.conf is a
    # generated file and does not depend on a .device unit, and it was the one
    # half of this that did land.
    #
    # dnsmasq above runs with `port = 0` and answers no queries, so resolution
    # has to go past it to the gateway along with everything else.
    networking.nameservers = lib.mkIf cfg.viaHostGateway cfg.nameservers;

    # 22 is stage-2's sshd. 2222 is the stage-1 initrd's dropbear, which nothing
    # stops at switch_root and which therefore keeps *listening* under stage-2 --
    # though it can no longer authenticate anyone once its initramfs is emptied,
    # for the reasons set out in ./stage-1-ssh.nix. The port stays open because
    # closing it would not stop the process, and because during stage-1 this is
    # the only ssh there is: it is what carries `dandelion-deploy-ssh` when the
    # rootfs being written is the one stage-2 would have booted from.
    networking.firewall.interfaces.${cfg.interface} = {
      allowedTCPPorts = [ 22 2222 ];
      allowedUDPPorts = [ 67 ];
    };
  };
}
