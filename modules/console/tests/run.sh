#!/usr/bin/env bash
# Panel tests. PANEL points at the binary; without it the one on PATH is used.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
panel=${PANEL:-panel}
fixture=$here/fixture
expected=$here/expected/dashboard.txt
status=0

# The fixture is a snapshot of the device's procfs and sysfs, so the frame is a
# pure function of it once the clock and the timezone are pinned.
actual=$(mktemp)
TZ=UTC "$panel" --once \
  --root "$fixture" \
  --now 1770000000 \
  --subtitle "xiaomi redmi 9a . mt6765" \
  --load-note "23 mt6765 vendor threads sit in D forever" \
  --service sshd:22 \
  --service tailscaled \
  < /dev/null > "$actual"

if diff -u "$expected" "$actual" > /tmp/panel-frame-diff 2>&1; then
  echo "ok   dashboard frame matches the golden"
else
  echo "FAIL dashboard frame differs"
  cat -v /tmp/panel-frame-diff
  status=1
fi
rm -f "$actual" /tmp/panel-frame-diff

PANEL=$panel FIXTURE=$fixture python3 "$here/keys.py" || status=1

exit $status
