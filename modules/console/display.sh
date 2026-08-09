current() {
  local v
  read -r v < "$backlight" 2>/dev/null || v=0
  printf '%s' "${v:-0}"
}

turn_off() {
  local cur
  cur=$(current)
  if [ "$cur" -gt 0 ]; then
    printf '%s\n' "$cur" > "$saved"
  fi
  printf '0\n' > "$backlight"
}

turn_on() {
  local level=""
  if [ -r "$saved" ]; then
    read -r level < "$saved" 2>/dev/null || level=""
  fi
  case "$level" in
    "" | *[!0-9]*) level=$fallback ;;
  esac
  [ "$level" -gt 0 ] || level=$fallback
  printf '%s\n' "$level" > "$backlight"
  rm -f "$saved"
}

case "${1:-toggle}" in
  on) turn_on ;;
  off) turn_off ;;
  toggle)
    if [ "$(current)" -gt 0 ]; then turn_off; else turn_on; fi
    ;;
  status)
    if [ "$(current)" -gt 0 ]; then echo on; else echo off; fi
    ;;
  *)
    echo "usage: display [on|off|toggle|status]" >&2
    exit 2
    ;;
esac
