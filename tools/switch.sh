# Build, copy and activate a system generation, then prove the device survived
# it before letting the change stand.
#
# The proof is the point. `nixos-rebuild switch --target-host` reports success
# when switch-to-configuration exits 0, which it does whether or not the device
# is still reachable afterwards -- and on this port an unreachable device costs
# a physical power cycle. Here the switch runs behind the deadman switch in
# ../modules/deploy-guard.nix: the device is told to roll itself back unless
# something confirms, and only a device that answers ssh again with the expected
# generation gets confirmed.
#
# Deliberately no rndis keepalive. Re-asserting the address every few seconds
# from a transient unit does keep the link up across a switch, but it keeps it up
# for a configuration that broke networking too -- which is the one case this
# script exists to catch. The guard recovers that case; masking it does not.
#
# Environment:
#   HOST     ssh destination, default dandelion
#   FLAKE    flake reference, default .
#   ATTR     package attribute holding the toplevel
#   WAIT     seconds to wait for the device to answer after the switch

: "${HOST:=dandelion}"
: "${FLAKE:=.}"
: "${ATTR:=xiaomi-dandelion-system}"
: "${WAIT:=180}"

force=0
case "${1:-}" in
  --force) force=1 ;;
  "") ;;
  *)
    echo "usage: dandelion-switch [--force]" >&2
    exit 2
    ;;
esac

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# --out-link into a temporary directory rather than none at all: a build with no
# root is collectable the moment it finishes, and this host's nix-gc has eaten
# this port's outputs before. The link only has to outlive the copy.
echo "==> building $FLAKE#$ATTR"
nix build "$FLAKE#$ATTR" --out-link "$out/system"
toplevel=$(readlink -f "$out/system")
echo "    $toplevel"

ssh_() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@"; }

if ! current=$(ssh_ 'readlink -f /run/current-system'); then
  echo "FATAL: $HOST does not answer, nothing to switch" >&2
  exit 1
fi

if [ "$current" = "$toplevel" ]; then
  echo "==> already running this generation, nothing to do"
  exit 0
fi

# Re-execing PID 1 across two systemd builds hangs in manager_new(), and
# `switch` runs daemon-reexec unconditionally. The two builds differ on every
# change to ../modules/systemd-linux-4.9.nix, so this is not a rare case on this
# port -- it is the expected outcome of the work the port exists to do.
running_systemd=$(ssh_ 'readlink -f /run/current-system/systemd')
new_systemd=$(readlink -f "$toplevel/systemd")
if [ "$running_systemd" != "$new_systemd" ]; then
  echo "systemd differs between the running system and this generation:" >&2
  echo "  running $running_systemd" >&2
  echo "  new     $new_systemd" >&2
  if [ "$force" -eq 0 ]; then
    echo "Refusing to switch. Flash an image and reboot instead, or pass --force" >&2
    echo "if you have already established that this re-exec is safe." >&2
    exit 1
  fi
  echo "--force given, continuing" >&2
fi

echo "==> copying the closure"
nix copy --to "ssh://$HOST" "$toplevel"

echo "==> arming the guard"
ssh_ deploy-guard arm

# systemd-run --collect --wait so that losing ssh mid-switch cannot abort the
# switch: the gadget re-enumerates when sshd and the network units restart, and
# an ExecStart killed halfway leaves a system that is neither generation.
echo "==> switching"
status=0
ssh_ "nix-env -p /nix/var/nix/profiles/system --set $toplevel \
  && systemd-run --collect --unit=nixos-switch --wait \
     /nix/var/nix/profiles/system/bin/switch-to-configuration switch" || status=$?

# 255 is ssh's own "the connection failed", and losing the connection during a
# switch is ordinary here -- the gadget re-enumerates when sshd and the network
# units restart. Anything else came from the device and means the switch itself
# reported a problem, which is worth saying out loud even though the wait below
# is the same either way.
case "$status" in
  0) ;;
  255) echo "    ssh dropped during the switch, which is expected here" ;;
  *) echo "    switch-to-configuration reported failure (status $status)" >&2 ;;
esac

echo "==> waiting up to ${WAIT}s for $HOST to answer as the new generation"
deadline=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if now=$(ssh_ 'readlink -f /run/current-system' 2>/dev/null) && [ "$now" = "$toplevel" ]; then
    echo "==> confirming"
    ssh_ deploy-guard confirm
    ssh_ 'systemctl --failed --no-legend' || true
    exit 0
  fi
  sleep 5
done

echo "FATAL: $HOST never answered as $toplevel." >&2
echo "       The guard was armed before the switch and rolls the device back to" >&2
echo "       the previous generation on its own. Do not power-cycle it yet." >&2
exit 1
