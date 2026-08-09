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

  # Transient rather than declared units, and that is not a style choice.
  #
  # The first revision of this module shipped deploy-guard.{service,timer} as
  # ordinary units and armed them from the activation script. It never armed:
  # switch-to-configuration runs the activation script *before* it reloads the
  # manager, so at the moment the arm runs, systemd has never heard of a unit by
  # that name and `systemctl restart` fails on a fresh install -- exactly the
  # deploy the guard exists to protect. `systemd-run` needs no unit file and no
  # reload, so it works at any point in a switch, including inside the
  # activation script of a generation systemd has not read yet.
  #
  # Being transient also settles the other problem. The rollback runs
  # switch-to-configuration, which restarts every unit whose file changed
  # between the two generations -- and a declared deploy-guard.service is one of
  # them whenever the timeout was edited, so the switch would kill the process
  # performing it, halfway through. A transient unit is in no generation, so no
  # switch touches it.
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

  # One name for both halves: `systemd-run --on-active` creates <unit>.timer and
  # the <unit>.service it triggers, so stopping the timer disarms and stopping
  # the service would interrupt a rollback in progress.
  unit = "deploy-guard";

  # Absolute paths: this runs from the activation script too, whose PATH is not
  # this system's.
  arm = pkgs.writeShellScript "deploy-guard-arm" ''
    set -eu
    ${config.systemd.package}/bin/systemctl stop ${unit}.timer ${unit}.service 2>/dev/null || true
    exec ${config.systemd.package}/bin/systemd-run \
      --collect \
      --unit=${unit} \
      --on-active=${toString cfg.timeoutSec} \
      --description="Roll back the system profile after an unconfirmed switch" \
      --timer-property=RemainAfterElapse=false \
      --quiet \
      ${rollback}
  '';

  cli = pkgs.writeShellApplication {
    name = "deploy-guard";
    runtimeInputs = [config.systemd.package];
    text = ''
      case "''${1:-status}" in
        arm)
          ${arm}
          echo "armed: confirm within ${toString cfg.timeoutSec}s or the system rolls back"
          ;;
        confirm)
          systemctl stop ${unit}.timer 2>/dev/null || true
          echo "confirmed: $(readlink -f /run/current-system)"
          ;;
        status)
          # An elapsed timer that systemd has not collected yet still reads as
          # active, with its next elapse at infinity. Reporting that as "armed"
          # tells an operator the opposite of the truth: the rollback has
          # already run. RemainAfterElapse=false above is what makes the unit go
          # away; this is the check that does not depend on it having.
          next=$(systemctl show ${unit}.timer -p NextElapseUSecMonotonic --value 2>/dev/null || true)
          if systemctl is-active --quiet ${unit}.timer && [ "$next" != infinity ]; then
            echo "armed, fires at $next (monotonic)"
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

    # `/run/systemd/system` is the canonical "systemd is running" test, and here
    # it is also the boot-versus-switch test: stage-2 init runs this activation
    # script and only then execs systemd, so at boot there is no manager to arm
    # a timer against. Booting is not a deploy and must not need confirming --
    # an unattended reboot would otherwise roll the device back.
    #
    # A guard that cannot arm is a lost safety net, not a reason to abandon the
    # switch: the activation script runs under `set -e`, so an unguarded `${arm}`
    # here aborts activation partway and leaves the system between two
    # generations. Observed once, on the switch that replaced this module's
    # declared units with transient ones -- systemd refuses a transient unit
    # whose name still has a fragment file, and the fragment is not gone until
    # the manager reloads, which happens after this script.
    system.activationScripts.deploy-guard = ''
      if [ -d /run/systemd/system ] && [ "''${DEPLOY_GUARD_SKIP:-0}" != 1 ]; then
        ${arm} || echo "deploy-guard: could not arm, this switch is unguarded" >&2
      fi
    '';
  };
}
