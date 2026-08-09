# A deadman switch on `switch-to-configuration switch`.
#
# This device has one lifeline, rndis0 over the USB gadget, and a configuration
# that breaks it cannot be fixed from the device: there is no keyboard, and the
# recovery is a physical power cycle with the phone in hand. So the switch that
# breaks it has to undo itself.
#
# Arming starts a timer. If nothing confirms before it elapses, the guard rolls
# the system profile back one generation and switches to it. Confirming is a
# single command, which is what makes this testable from the build host: the
# host runs the switch, waits for the device to answer again, and only then
# confirms. An unreachable device confirms nothing and is rolled back by the
# generation it just replaced.
#
# It is armed from two places, because the two cover different failures:
#
#   - `deploy-guard arm` from the host, before the switch. Covers a switch that
#     dies before it reaches the activation script.
#   - the activation script below, during the switch. Covers `nixos-rebuild
#     switch --target-host` and anything else that does not know about this
#     module at all.
#
# What it does not cover: a configuration that breaks the *next boot* rather
# than the running system. The guard runs in the system it is judging, so it
# needs that system to be alive enough to run a timer.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.services.deployGuard;

  # Rolls back in its own transient unit rather than in deploy-guard.service.
  # switch-to-configuration restarts units whose files changed between the two
  # generations, and deploy-guard.service is one of them whenever the timeout
  # was edited -- so running the switch inside that service means the switch can
  # kill the process performing it, halfway through.
  rollback = pkgs.writeShellScript "deploy-guard-rollback" ''
    set -eu

    echo "not confirmed within ${toString cfg.timeoutSec}s, rolling back"
    ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --rollback

    # DEPLOY_GUARD_SKIP is read by the activation script below. Without it this
    # switch arms the guard again, and the next timeout rolls back the rollback.
    DEPLOY_GUARD_SKIP=1 \
      /nix/var/nix/profiles/system/bin/switch-to-configuration switch

    echo "rolled back to $(readlink -f /run/current-system)"
  '';

  cli = pkgs.writeShellApplication {
    name = "deploy-guard";
    runtimeInputs = [config.systemd.package];
    text = ''
      case "''${1:-status}" in
        arm)
          systemctl restart deploy-guard.timer
          echo "armed: confirm within ${toString cfg.timeoutSec}s or the system rolls back"
          ;;
        confirm)
          systemctl stop deploy-guard.timer
          echo "confirmed: $(readlink -f /run/current-system)"
          ;;
        status)
          if systemctl is-active --quiet deploy-guard.timer; then
            echo "armed"
            systemctl show deploy-guard.timer -p NextElapseUSecRealtime --value
          else
            echo "disarmed"
          fi
          ;;
        *)
          echo "usage: deploy-guard [arm|confirm|status]" >&2
          exit 2
          ;;
      esac
    '';
    meta.description = "Arm or confirm the deploy deadman switch";
  };
in {
  options.mobile.services.deployGuard = {
    enable = lib.mkEnableOption "the deploy deadman switch";

    timeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        How long an unconfirmed switch survives. Long enough for the units the
        switch restarts to settle and for the host to reconnect over a gadget
        that re-enumerates during the switch; short enough that a lost device
        comes back on its own rather than after a walk to wherever it is.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cli];

    systemd.services.deploy-guard = {
      description = "Roll back the system profile after an unconfirmed switch";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${config.systemd.package}/bin/systemd-run --collect --unit=deploy-guard-rollback ${rollback}";
      };
    };

    # No wantedBy: nothing starts this except an explicit arm. RemainAfterElapse
    # is off so that a fired timer reads as disarmed again rather than as an
    # armed one that already went off.
    systemd.timers.deploy-guard = {
      description = "Deadline for confirming the running system generation";
      timerConfig = {
        OnActiveSec = cfg.timeoutSec;
        AccuracySec = "5s";
        RemainAfterElapse = false;
        Unit = "deploy-guard.service";
      };
    };

    # `/run/systemd/system` is the canonical "systemd is running" test, and here
    # it is also the boot-versus-switch test: stage-2 init runs this activation
    # script and only then execs systemd, so at boot there is no manager to arm
    # a timer against. Booting is not a deploy and must not need confirming --
    # an unattended reboot would otherwise roll the device back.
    system.activationScripts.deploy-guard = ''
      if [ -d /run/systemd/system ] && [ "''${DEPLOY_GUARD_SKIP:-0}" != 1 ]; then
        ${config.systemd.package}/bin/systemctl --no-block restart deploy-guard.timer || true
      fi
    '';
  };
}
