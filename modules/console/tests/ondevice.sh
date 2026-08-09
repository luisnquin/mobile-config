#!/usr/bin/env bash
# Hands-free check against real hardware. Runs a second panel on tty2 and feeds
# it synthetic key events through the daemon's raw fifo, then reads the console
# back through /dev/vcs2. tty1 keeps whatever is already on it, and the active
# VT never changes, so this is safe to run over ssh on a phone nobody is
# holding.
#
#   PANEL=/path/to/panel bash ondevice.sh
set -u
P=${PANEL:?set PANEL to the panel binary}
HOST_NAME=${HOST_NAME:-$(hostname)}
D=/tmp/panel-ondevice
VT=${VT:-2}

# openvt forks, so the panel is not $!. Everything is matched on the state
# directory instead, which nothing else on the device carries.
cleanup() {
  pkill -f "state-dir $D" 2>/dev/null
  sleep 1
  pkill -9 -f "state-dir $D" 2>/dev/null
  deallocvt "$VT" 2>/dev/null
  rm -rf "$D"
}
trap cleanup EXIT
cleanup

mkdir -p "$D/bl" "$D/state"
echo 200 > "$D/bl/brightness"
echo 2047 > "$D/bl/max_brightness"
mkfifo "$D/evt"

# A scratch backlight directory, so a toggle under test never darkens the panel
# somebody may be reading.
"$P" keys --keys "$D/evt" --keys-raw --socket "$D/keys.sock" \
  --backlight "$D/bl" --state-dir "$D/state" \
  --hold-ms 400 --repeat-ms 120 &
for _ in $(seq 40); do
  [ -S "$D/keys.sock" ] && break
  sleep 0.25
done
[ -S "$D/keys.sock" ] || { echo "FAIL the key daemon never bound its socket"; exit 1; }

openvt -f -c "$VT" -- "$P" --socket "$D/keys.sock" \
  --backlight "$D/bl" --state-dir "$D/state" \
  --interval 5 --service sshd:22 --service tailscaled &

send() {
  perl -e 'my ($f, $c, $v) = @ARGV;
           open(F, ">>", $f) or die $!; binmode F;
           print F pack("qqSSl", 0, 0, 1, $c, $v), pack("qqSSl", 0, 0, 0, 0, 0);
           close F;' "$D/evt" "$1" "$2"
}
tap() { send "$1" 1; sleep 0.12; send "$1" 0; sleep 0.6; }
hold() { send "$1" 1; sleep 0.8; send "$1" 0; sleep 0.8; }

# /dev/vcsa carries the geometry in its first four bytes; /dev/vcs is the plain
# character buffer with no line breaks, so it has to be folded by hand.
snap() {
  perl -e 'my $vt = shift;
           open(A, "<", "/dev/vcsa$vt") or die $!; binmode A;
           read(A, my $h, 4); my ($r, $c) = unpack("CC", $h);
           open(V, "<", "/dev/vcs$vt") or die $!; binmode V;
           read(V, my $s, $r * $c);
           for my $i (0 .. $r - 1) {
             my $l = substr($s, $i * $c, $c); $l =~ s/\s+$//;
             print "$l\n" if length $l;
           }' "$VT"
}

fails=0
last=""

# The device paints when its readings are ready rather than on a schedule, so
# every check polls the console instead of trusting a sleep.
expect() {
  local name=$1 pattern=$2 deadline=$((SECONDS + ${3:-12}))
  while :; do
    last=$(snap)
    if printf '%s' "$last" | grep -qa -- "$pattern"; then
      echo "ok   $name"
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.5
  done
  echo "FAIL $name  -- no /$pattern/ on tty$VT:"
  printf '%s\n' "$last" | head -40 | sed 's/^/       /'
  fails=$((fails + 1))
}

expect "dashboard renders on tty$VT" "$(echo "$HOST_NAME" | tr '[:lower:]' '[:upper:]')" 25
expect "battery telemetry reaches the panel" "BATT" 5
expect "sd-bus reports unit state" "tailscaled" 5

hold 116
expect "held power opens the menu" "MENU"

tap 114
tap 114
tap 114
expect "volume steps to kernel logs" "> kernel logs"

tap 116
expect "kernel log view fills from /dev/kmsg" "^\\[... ... " 20
expect "kernel log view is scrollable" " of [0-9]* .* scroll"

tap 116
expect "power leaves the pager" "MENU"

tap 114
tap 116
expect "unit view reaches the deployed systemd" "\\.service  *loaded" 20

tap 116
expect "power leaves the unit view" "MENU"

hold 116
expect "held power closes the menu" "$(echo "$HOST_NAME" | tr '[:lower:]' '[:upper:]')"

echo
if [ "$fails" -eq 0 ]; then
  echo "on-device: all checks passed"
else
  echo "on-device: $fails failed"
fi
exit "$fails"
