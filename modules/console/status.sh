esc=$(printf '\033')
RST="${esc}[0m"
BLD="${esc}[1m"
DIM="${esc}[2m"
RED="${esc}[31m"
GRN="${esc}[32m"
YEL="${esc}[33m"
CYN="${esc}[36m"

BARS="########################################"
DOTS="........................................"

cores=$(nproc 2>/dev/null || echo 1)

screen_rows=24
screen_cols=80
if size=$(stty size 2>/dev/null); then read -r screen_rows screen_cols <<< "$size"; fi

# --- keys -------------------------------------------------------------------

# Hardware keys arrive as single characters on a fifo, typed keys on stdin.
# bash waits on one descriptor at a time, so both are polled in slices.
has_keys=0
if [ -p "$keys" ] && exec 9<> "$keys"; then has_keys=1; fi

# Slices per second, so a budget stays the seconds it claims either way.
if [ "$has_keys" = 1 ]; then slices=10; else slices=20; fi

# Only the introducer reaches here; the rest of the sequence would otherwise
# read as one keypress per byte.
swallow_seq() {
  local c n
  for ((n = 0; n < 8; n++)); do
    read -rsn1 -t 0.02 c || return
    case "$c" in [a-zA-Z~]) return ;; esac
  done
}

key=""
getkey() {
  local budget=$1 i
  for ((i = 0; i < budget * slices; i++)); do
    key=""
    if read -rsn1 -t 0.05 key; then
      if [ "$key" = "$esc" ]; then swallow_seq; else return 0; fi
    fi
    if [ "$has_keys" = 1 ]; then
      key=""
      read -rsn1 -t 0.05 key <&9 && return 0
    fi
  done
  key=""
  return 1
}

# --- readers ----------------------------------------------------------------

# A frame touches about thirty files, so they go through the `read` builtin
# rather than $(cat ...): thirty forks per repaint is visible on eight A53s.
val=""
sysread() {
  val=""
  [ -r "$1" ] || return 1
  read -r val < "$1" 2>/dev/null || return 1
  [ -n "$val" ]
}

human_kb() {
  local k=$1
  if [ "$k" -ge 1048576 ]; then
    printf '%d.%01dG' "$((k / 1048576))" "$((k % 1048576 * 10 / 1048576))"
  elif [ "$k" -ge 1024 ]; then
    printf '%dM' "$((k / 1024))"
  else
    printf '%dK' "$k"
  fi
}

duration() {
  local s=$1
  if [ "$s" -ge 86400 ]; then
    printf '%dd %02dh %02dm' "$((s / 86400))" "$((s % 86400 / 3600))" "$((s % 3600 / 60))"
  elif [ "$s" -ge 3600 ]; then
    printf '%dh %02dm' "$((s / 3600))" "$((s % 3600 / 60))"
  else
    printf '%dm %02ds' "$((s / 60))" "$((s % 60))"
  fi
}

bar() {
  local v=$1 m=$2 w=$3 n=0 pct=0 colour=$GRN
  if [ "$m" -gt 0 ]; then
    n=$((v * w / m))
    pct=$((v * 100 / m))
  fi
  [ "$n" -gt "$w" ] && n=$w
  [ "$n" -lt 0 ] && n=0
  [ "$pct" -ge 70 ] && colour=$YEL
  [ "$pct" -ge 90 ] && colour=$RED
  printf '%s[%s%s]%s' "$colour" "${BARS:0:n}" "${DOTS:0:$((w - n))}" "$RST"
}

label() { printf ' %s%-6s%s ' "$CYN" "$1" "$RST"; }

state_of() {
  case "$1" in
    active) printf '%s%-8s%s' "$GRN" "active" "$RST" ;;
    inactive | failed) printf '%s%-8s%s' "$RED" "$1" "$RST" ;;
    *) printf '%s%-8s%s' "$DIM" "${1:-unknown}" "$RST" ;;
  esac
}

temp_c() {
  sysread "$1" || {
    printf '?'
    return
  }
  printf '%d' "$((val / 1000))"
}

cpu_prev_busy=0
cpu_prev_total=0
cpu_percent() {
  local user nice sys idle iowait irq softirq steal total busy dt db
  read -r _ user nice sys idle iowait irq softirq steal _ < /proc/stat
  total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
  busy=$((total - idle - iowait))
  dt=$((total - cpu_prev_total))
  db=$((busy - cpu_prev_busy))
  cpu_prev_total=$total
  cpu_prev_busy=$busy
  if [ "$dt" -gt 0 ]; then printf '%d' "$((db * 100 / dt))"; else printf '0'; fi
}

cpu_ghz() {
  local f top=0
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    sysread "$f" || continue
    [ "$val" -gt "$top" ] && top=$val
  done
  printf '%d.%02dGHz' "$((top / 1000000))" "$((top % 1000000 / 10000))"
}

# JEDEC 5.0: DEVICE_LIFE_TIME_EST is consumed write endurance in 10% steps, one
# hex byte per bank, and PRE_EOL_INFO is a three-state reserved-pool summary.
emmc_health() {
  local a b n life="?" eol="?"
  if sysread /sys/block/mmcblk0/device/life_time; then
    read -r a b <<< "$val"
    a=$((16#${a#0x}))
    b=${b#0x}
    b=$((16#${b:-0}))
    n=$((a > b ? a : b))
    if [ "$n" -gt 0 ]; then life="$(((n - 1) * 10))-$((n * 10))%"; fi
  fi
  if sysread /sys/block/mmcblk0/device/pre_eol_info; then
    case "$val" in
      01) eol="normal" ;;
      02) eol="${YEL}warning${RST}${DIM}" ;;
      03) eol="${RED}urgent${RST}${DIM}" ;;
      *) eol="$val" ;;
    esac
  fi
  printf 'emmc %s used, %s' "$life" "$eol"
}

# capacity is integer-only on this gauge -- charge_counter is just
# capacity * charge_full / 100, and there is no raw SOC in /proc or debugfs --
# so the finer signal is how long the charge lasts at the current draw.
# charge in uAh, current in the FG's 0.1 mA steps.
endurance() {
  local charge=$1 ma=$2 full=$3 mins
  [ "$4" = full ] && return
  [ "$ma" -lt 0 ] && ma=$((-ma))
  ma=$((ma / 10))
  [ "$ma" -gt 5 ] || return
  if [ "$4" = charging ]; then charge=$((full - charge)); fi
  [ "$charge" -gt 0 ] || return
  mins=$((charge * 60 / (ma * 1000)))
  printf '%dh%02dm' "$((mins / 60))" "$((mins % 60))"
}

ip_of() {
  local a
  a=$(ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4; exit}')
  printf '%s' "${a:--}"
}

established=""
clients_on() {
  awk -v p="$1" '{n = split($3, a, ":"); if (a[n] == p) c++} END {print c + 0}' <<< "$established"
}

# MemoryCurrent comes from the cgroup rather than `systemctl show`: asking
# systemd for it also makes it stat cpu.stat, which this kernel does not carry,
# and it logs a failure to the journal on every repaint.
service_row() {
  local unit=$1 state mem=0
  state=$(systemctl show "$unit.service" -p ActiveState --value 2>/dev/null)
  sysread "/sys/fs/cgroup/system.slice/$unit.service/memory.current" && mem=$val
  case "$mem" in '' | *[!0-9]*) mem=0 ;; esac
  printf '%s%-11s%s %s %6s' "$BLD" "$unit" "$RST" "$(state_of "$state")" "$(human_kb "$((mem / 1024))")"
}

# tailscale status costs about a fifth of a second here. Neither it nor the
# listening set moves fast enough to pay that on every repaint.
peers="-"
listening="-"
refresh_slow() {
  local n l
  n=$(tailscale status --self=false 2>/dev/null | grep -c '^100\.') && peers=$n
  l=$(ss -tlnH 2>/dev/null |
    awk '{n = split($4, a, ":"); print a[n]}' | sort -un | paste -sd' ' -)
  listening=${l:--}
}

# --- frame ------------------------------------------------------------------

frame() {
  local now host uptime_s l1 l5 l15 procs kernel generation booted
  local pct ghz soc_t
  local memtotal=0 memavail=0 swaptotal=0 swapfree=0 memused
  local zorig=0 zcompr=0 zratio="-"
  local dtotal dused dpct
  local bat cap status volt curr batt_t charge charge_full input_ua flow est panel level
  local spec unit port pad="" i
  local users peer_list ttys failed

  printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1
  sysread /proc/sys/kernel/hostname && host=$val || host="?"
  read -r uptime_s _ < /proc/uptime
  uptime_s=${uptime_s%%.*}
  read -r l1 l5 l15 procs _ < /proc/loadavg
  read -r _ _ kernel _ < /proc/version
  generation=$(readlink /nix/var/nix/profiles/system 2>/dev/null)
  generation=${generation#system-}
  generation=${generation%-link}

  pct=$(cpu_percent)
  ghz=$(cpu_ghz)
  soc_t=$(temp_c /sys/class/thermal/thermal_zone1/temp)

  while read -r k v _; do
    case "$k" in
      MemTotal:) memtotal=$v ;;
      MemAvailable:) memavail=$v ;;
      SwapTotal:) swaptotal=$v ;;
      SwapFree:) swapfree=$v ;;
    esac
  done < /proc/meminfo
  memused=$((memtotal - memavail))

  if sysread /sys/block/zram0/mm_stat; then
    read -r zorig zcompr _ <<< "$val"
    if [ "$zcompr" -gt 0 ]; then
      zratio="$((zorig / zcompr)).$((zorig * 10 / zcompr % 10))x"
    fi
  fi

  read -r _ dtotal dused _ dpct _ < <(df -Pk / | tail -1)
  dpct=${dpct%\%}

  bat=/sys/class/power_supply/battery
  sysread "$bat/capacity" && cap=$val || cap=0
  sysread "$bat/status" && status=$val || status="?"
  sysread "$bat/voltage_now" && volt=$val || volt=0
  sysread "$bat/current_avg" && curr=$val || curr=0
  if [ "$curr" -eq 0 ] && sysread "$bat/current_now"; then curr=$val; fi
  sysread "$bat/temp" && batt_t=$val || batt_t=0
  sysread "$bat/charge_counter" && charge=$val || charge=0
  sysread "$bat/charge_full" && charge_full=$val || charge_full=0
  sysread /sys/class/power_supply/main/input_current_now && input_ua=$val || input_ua=0
  case "$status" in
    Charging) flow=charging ;;
    Full) flow=full ;;
    *) flow=draining ;;
  esac
  est=$(endurance "$charge" "$curr" "$charge_full" "$flow")

  panel=$(display status)
  sysread "$backlight" && level=$val || level=0

  established=$(ss -tnH state established 2>/dev/null)
  users=$(ps -eo args= 2>/dev/null |
    sed -n 's/^sshd[a-z-]*: \([^ @[]*\)@.*/\1/p' | sort -u | paste -sd, -)
  peer_list=$(awk '{n = split($3, a, ":"); if (a[n] == "22") print $4}' <<< "$established")
  peer_list=$(paste -sd' ' - <<< "$peer_list")
  ttys=$(who 2>/dev/null | awk '{printf "%s@%s since %s   ", $1, $2, $4}')
  failed=$(systemctl list-units --failed --no-legend --plain 2>/dev/null |
    awk '{print $1}' | paste -sd' ' -)

  booted=$DIM
  [ "$(readlink /run/booted-system)" = "$(readlink /run/current-system)" ] || booted=$YEL

  # Lines are erased to end-of-line and overwritten in place rather than
  # cleared: mtkfb only composites when msm-fb-refresher pans, so a blank frame
  # stays on the panel until the next pan.
  {
    # The panel's corners are rounded, so the first rows are partly cut off.
    for ((i = 0; i < top_margin; i++)); do printf '\n'; done

    printf '  %s%s%s   %s%s%s%s\n\n' \
      "$BLD$CYN" "${host^^}" "$RST" "$DIM" "${subtitle:+$subtitle . }" "$now" "$RST"

    label HOST
    printf '%s%s%s   linux %s   gen %s%s%s   up %s\n' \
      "$BLD" "$host" "$RST" "$kernel" "$booted" "${generation:-?}" "$RST" "$(duration "$uptime_s")"

    label LOAD
    printf '%s %s %s   procs %s   %s%s%s\n\n' \
      "$l1" "$l5" "$l15" "$procs" "$DIM" "$load_note" "$RST"

    label CPU
    printf '%s %3s%%   %sx %s   soc %sC\n' "$(bar "$pct" 100 10)" "$pct" "$cores" "$ghz" "$soc_t"

    label MEM
    printf '%s %6s / %-6s %stop %s%s\n' \
      "$(bar "$memused" "$memtotal" 10)" "$(human_kb "$memused")" "$(human_kb "$memtotal")" \
      "$DIM" "$(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -3 |
        awk '{printf "%s %dM  ", $2, $1 / 1024}')" "$RST"

    label SWAP
    printf '%s %6s / %-6s %szram holds %s at %s%s\n' \
      "$(bar "$((swaptotal - swapfree))" "$swaptotal" 10)" \
      "$(human_kb "$((swaptotal - swapfree))")" "$(human_kb "$swaptotal")" \
      "$DIM" "$(human_kb "$((zcompr / 1024))")" "$zratio" "$RST"

    label DISK
    printf '%s %6s / %-6s %s%s%s\n' "$(bar "$dpct" 100 10)" \
      "$(human_kb "$dused")" "$(human_kb "$dtotal")" "$DIM" "$(emmc_health)" "$RST"

    label BATT
    printf '%s %3s%%  %-8s %d.%03dV  %+dmA  %d.%dC  %s%s%s, in %dmA%s\n' \
      "$(bar "$cap" 100 10)" "$cap" "$status" \
      "$((volt / 1000000))" "$((volt % 1000000 / 1000))" "$((curr / 10))" \
      "$((batt_t / 10))" "$((batt_t % 10))" \
      "$DIM" "${est:+$est }" "$flow" \
      "$((input_ua / 1000))" "$RST"

    label PANEL
    printf '%s  %s%s of %s%s\n\n' "$panel" "$DIM" "$level" "$backlight_max" "$RST"

    label NET
    printf 'rndis0      %-20s tailscale0  %s\n' "$(ip_of rndis0)" "$(ip_of tailscale0)"
    printf '        gateway     %-20s peers       %s\n' \
      "$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')" "$peers"
    printf '        %slistening   %s%s\n\n' "$DIM" "$listening" "$RST"

    label SVC
    for spec in "${services[@]}"; do
      unit=${spec%%:*}
      port=""
      [ "$spec" = "$unit" ] || port=${spec#*:}
      printf '%s%s%s\n' "$pad" "$(service_row "$unit")" \
        "${port:+  $(clients_on "$port") clients}"
      pad='        '
    done
    if [ -n "$failed" ]; then
      printf '        %sfailed      %s%s\n\n' "$RED" "$failed" "$RST"
    else
      printf '        %sfailed      none%s\n\n' "$DIM" "$RST"
    fi

    label SSH
    printf '%-22s %s\n' "${users:--}" "${peer_list:--}"
    label TTY
    printf '%s\n\n' "${ttys:--}"

    printf ' %spower%s screen   %shold power%s menu%s        every %ss%s\n' \
      "$BLD" "$RST" "$BLD" "$RST" "$DIM" "$interval" "$RST"
  } | sed "s/\$/${esc}[K/"

  printf '%s[J' "$esc"
}

# --- sub-views --------------------------------------------------------------

# Ctrl-C leaves these views, and reaches this script too. A no-op handler makes
# bash defer the signal until the child exits and then discard it.
view() {
  printf '%s%s[2J%s[H' "$RST" "$esc" "$esc"
  trap ':' INT
  "$@"
  trap - INT
  printf '\n%s-- any key to return --%s' "$DIM" "$RST"
  while ! getkey "$interval"; do :; done
}

network_detail() {
  ip -br -4 addr
  echo
  ip -4 route
  echo
  tailscale status 2>&1 | head -20
}

# less takes a keyboard the panel does not have, so output is captured once and
# a window of it is redrawn per keypress.
pager() {
  local file total rows half top printed i
  # No key is polled until the capture returns.
  printf '%s[2J%s[H\n %sreading...%s' "$esc" "$esc" "$DIM" "$RST"
  file=$(mktemp) || return
  "$@" > "$file" 2>&1
  total=$(grep -c "" "$file")

  rows=$((screen_rows - top_margin - 3))
  [ "$rows" -lt 5 ] && rows=5
  half=$((rows / 2))
  top=$((total - rows))
  [ "$top" -lt 0 ] && top=0

  printf '%s[2J' "$esc"
  while :; do
    printed=$((total - top))
    [ "$printed" -gt "$rows" ] && printed=$rows

    printf '%s[H' "$esc"
    {
      for ((i = 0; i < top_margin; i++)); do printf '\n'; done
      sed -n "$((top + 1)),$((top + rows))p" "$file" | cut -c "1-$screen_cols"
      for ((i = printed; i < rows; i++)); do printf '\n'; done
      printf '\n %s%d-%d of %d%s   %svol +/-%s scroll   %spower%s back\n' \
        "$DIM" "$((top + 1))" "$((top + printed))" "$total" "$RST" \
        "$BLD" "$RST" "$BLD" "$RST"
    } | sed "s/\$/${esc}[K/"
    printf '%s[J' "$esc"

    getkey "$interval" || continue
    case "$key" in
      '+' | k) top=$((top - half)) ;;
      '-' | j) top=$((top + half)) ;;
      *) break ;;
    esac
    [ "$top" -gt $((total - rows)) ] && top=$((total - rows))
    [ "$top" -lt 0 ] && top=0
  done

  rm -f "$file"
}

# --- menu -------------------------------------------------------------------

menu_items=(backlight "boot log" errors "kernel logs" units network back)

menu_frame() {
  local sel=$1 i mark state level
  state=$(display status)
  read -r level < "$backlight" 2>/dev/null || level=0
  {
    for ((i = 0; i < top_margin; i++)); do printf '\n'; done

    printf '  %sMENU%s   %shold power to close%s\n\n' "$BLD$CYN" "$RST" "$DIM" "$RST"

    for ((i = 0; i < ${#menu_items[@]}; i++)); do
      if [ "$i" -eq "$sel" ]; then mark="$CYN>$RST $BLD"; else mark='  '; fi
      printf '  %s%-14s%s' "$mark" "${menu_items[i]}" "$RST"
      if [ "${menu_items[i]}" = backlight ]; then
        printf '%s%s, %s of %s%s' "$DIM" "$state" "$level" "$backlight_max" "$RST"
      fi
      printf '\n'
    done

    printf '\n %svol +/-%s move   %spower%s select\n' "$BLD" "$RST" "$BLD" "$RST"
  } | sed "s/\$/${esc}[K/"

  printf '%s[J' "$esc"
}

menu() {
  local sel=0 n=${#menu_items[@]}
  printf '%s[2J' "$esc"
  while :; do
    printf '%s[H' "$esc"
    menu_frame "$sel"

    getkey "$interval" || continue
    case "$key" in
      '+' | k) sel=$(((sel + n - 1) % n)) ;;
      '-' | j) sel=$(((sel + 1) % n)) ;;
      m | q) return ;;
      '' | .)
        case "${menu_items[sel]}" in
          backlight) display toggle ;;
          "boot log") pager journalctl -b -n "$log_lines" --no-pager ;;
          errors) pager journalctl -b -p err -n "$log_lines" --no-pager ;;
          "kernel logs") pager dmesg -HT ;;
          units) pager systemctl list-units --no-pager --plain ;;
          network) pager network_detail ;;
          back) return ;;
        esac
        printf '%s[2J' "$esc"
        ;;
      *) ;;
    esac
  done
}

# --- main -------------------------------------------------------------------

if [ "${1:-}" = "--once" ] || [ ! -t 0 ]; then
  refresh_slow
  frame
  exit 0
fi

printf '%s[?25l%s[2J' "$esc" "$esc"
trap 'printf "%s[?25h%s\n" "$esc" "$RST"' EXIT

tick=0
while :; do
  if [ "$((tick % 6))" -eq 0 ]; then refresh_slow; fi
  tick=$((tick + 1))

  printf '%s[H' "$esc"
  frame

  getkey "$interval" || continue
  case "$key" in
    j) view journalctl -f -n 40 ;;
    b) pager journalctl -b -n "$log_lines" --no-pager ;;
    e) pager journalctl -b -p err -n "$log_lines" --no-pager ;;
    k) pager dmesg -HT ;;
    u) pager systemctl list-units --no-pager --plain ;;
    t) view top ;;
    n) pager network_detail ;;
    d | .) display toggle ;;
    m) menu ;;
    q) exit 0 ;;
    *) ;;
  esac
done
