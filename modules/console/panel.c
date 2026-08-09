/* On-panel dashboard for a device whose only inputs are three hardware keys.
 *
 * Every reading comes from procfs, sysfs, sd-bus or a socket read in this
 * process. The shell version forked about thirty times per repaint -- nproc,
 * stty, df, ss, ip, ps, who, systemctl, tailscale -- which cost 420ms on eight
 * A53s and made the key poll a set of 50ms slices between forks.
 *
 * Paths go through rp() so a fixture tree can stand in for /proc and /sys, and
 * the key decoder reads packed input_event structs from any descriptor, so the
 * frame and the state machine are both testable off the device.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <ifaddrs.h>
#include <limits.h>
#include <linux/input.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/un.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <utmpx.h>

#include <systemd/sd-bus.h>
#include <systemd/sd-journal.h>

#define RST "\033[0m"
#define BLD "\033[1m"
#define DIM "\033[2m"
#define RED "\033[31m"
#define GRN "\033[32m"
#define YEL "\033[33m"
#define CYN "\033[36m"

#define MAX_ROWS 128
#define MAX_LINE 2048
#define MAX_SERVICES 16
#define MAX_TOP 3

static const char BARS[] = "########################################";
static const char DOTS[] = "........................................";

/* ---- configuration --------------------------------------------------------- */

struct service {
  char unit[64];
  int port;
};

static struct {
  const char *root;
  const char *backlight;
  const char *state_dir;
  const char *keys_dev;
  const char *socket_path;
  const char *tailscale;
  const char *subtitle;
  const char *load_note;
  int interval;
  int log_lines;
  int top_margin;
  int default_brightness;
  int hold_ms;
  int repeat_ms;
  int k_power;
  int k_volup;
  int k_voldown;
  int keys_raw;
  int once;
  long fixed_now;
  struct service services[MAX_SERVICES];
  int nservices;
} cfg = {
    .root = "",
    .backlight = "/sys/class/leds/lcd-backlight",
    .state_dir = "/run/display",
    .keys_dev = "",
    .socket_path = "",
    .tailscale = "tailscale",
    .subtitle = "",
    .load_note = "",
    .interval = 5,
    .log_lines = 3000,
    .top_margin = 5,
    .default_brightness = 200,
    .hold_ms = 500,
    .repeat_ms = 120,
    .k_power = 116,
    .k_volup = 115,
    .k_voldown = 114,
    .fixed_now = -1,
};

/* Rotated so several calls can be live in one printf argument list. */
static const char *rp(const char *path) {
  static char buf[8][PATH_MAX];
  static unsigned slot;
  if (!cfg.root[0]) {
    return path;
  }
  char *b = buf[slot++ % 8];
  snprintf(b, PATH_MAX, "%s%s", cfg.root, path);
  return b;
}

/* Stand-ins for the readings that have no file behind them: statvfs, the
 * interface list, the bus and tailscale. Only ever consulted under --root. */
static const char *fixture(const char *name) {
  static char buf[PATH_MAX];
  if (!cfg.root[0]) {
    return NULL;
  }
  snprintf(buf, sizeof buf, "%s/fixture/%s", cfg.root, name);
  return buf;
}

/* ---- file readers ---------------------------------------------------------- */

static ssize_t slurp(const char *path, char *buf, size_t n) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return -1;
  }
  size_t off = 0;
  while (off + 1 < n) {
    ssize_t r = read(fd, buf + off, n - 1 - off);
    if (r < 0) {
      if (errno == EINTR) {
        continue;
      }
      close(fd);
      return -1;
    }
    if (r == 0) {
      break;
    }
    off += (size_t)r;
  }
  close(fd);
  buf[off] = '\0';
  return (ssize_t)off;
}

static int first_line(const char *path, char *out, size_t n) {
  char buf[4096];
  if (slurp(path, buf, sizeof buf) < 0) {
    return -1;
  }
  buf[strcspn(buf, "\n")] = '\0';
  snprintf(out, n, "%s", buf);
  return out[0] ? 0 : -1;
}

static long long read_ll(const char *path, long long dflt) {
  char buf[64];
  if (first_line(path, buf, sizeof buf) < 0) {
    return dflt;
  }
  errno = 0;
  char *end;
  long long v = strtoll(buf, &end, 10);
  if (end == buf || errno) {
    return dflt;
  }
  return v;
}

static int read_link(const char *path, char *out, size_t n) {
  ssize_t r = readlink(path, out, n - 1);
  if (r < 0) {
    out[0] = '\0';
    return -1;
  }
  out[r] = '\0';
  return 0;
}

/* ---- formatting ------------------------------------------------------------ */

static void human_kb(long long k, char *out, size_t n) {
  if (k >= 1048576) {
    snprintf(out, n, "%lld.%01lldG", k / 1048576, k % 1048576 * 10 / 1048576);
  } else if (k >= 1024) {
    snprintf(out, n, "%lldM", k / 1024);
  } else {
    snprintf(out, n, "%lldK", k);
  }
}

static void duration(long long s, char *out, size_t n) {
  if (s >= 86400) {
    snprintf(out, n, "%lldd %02lldh %02lldm", s / 86400, s % 86400 / 3600,
             s % 3600 / 60);
  } else if (s >= 3600) {
    snprintf(out, n, "%lldh %02lldm", s / 3600, s % 3600 / 60);
  } else {
    snprintf(out, n, "%lldm %02llds", s / 60, s % 60);
  }
}

static void bar(long long v, long long m, int w, char *out, size_t n) {
  int filled = 0;
  long long pct = 0;
  if (m > 0) {
    filled = (int)(v * w / m);
    pct = v * 100 / m;
  }
  if (filled > w) {
    filled = w;
  }
  if (filled < 0) {
    filled = 0;
  }
  const char *colour = GRN;
  if (pct >= 70) {
    colour = YEL;
  }
  if (pct >= 90) {
    colour = RED;
  }
  snprintf(out, n, "%s[%.*s%.*s]" RST, colour, filled, BARS, w - filled, DOTS);
}

static void state_of(const char *state, char *out, size_t n) {
  const char *colour = DIM;
  if (!state || !state[0]) {
    state = "unknown";
  }
  if (!strcmp(state, "active")) {
    colour = GRN;
  } else if (!strcmp(state, "inactive") || !strcmp(state, "failed")) {
    colour = RED;
  }
  snprintf(out, n, "%s%-8s" RST, colour, state);
}

/* ---- frame buffer ---------------------------------------------------------- */

struct screen {
  char line[MAX_ROWS][MAX_LINE];
  int n;
};

static struct screen screens[2];
static struct screen *cur = &screens[0];
static struct screen *prev = &screens[1];

static void screen_reset(struct screen *s) {
  s->n = 0;
  s->line[0][0] = '\0';
}

static void out(const char *fmt, ...) {
  char tmp[MAX_LINE * 2];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);

  for (const char *p = tmp; *p; p++) {
    if (*p == '\n') {
      if (cur->n + 1 < MAX_ROWS) {
        cur->n++;
        cur->line[cur->n][0] = '\0';
      }
      continue;
    }
    char *dst = cur->line[cur->n];
    size_t len = strlen(dst);
    if (len + 2 < MAX_LINE) {
      dst[len] = *p;
      dst[len + 1] = '\0';
    }
  }
}

static void label(const char *name) { out(" " CYN "%-6s" RST " ", name); }

static char obuf[256 * 1024];
static size_t olen;

static void emit(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsnprintf(obuf + olen, sizeof obuf - olen, fmt, ap);
  va_end(ap);
  if (r > 0 && (size_t)r < sizeof obuf - olen) {
    olen += (size_t)r;
  }
}

/* Lines are erased to end-of-line and overwritten in place rather than
 * cleared: mtkfb only composites when msm-fb-refresher pans, so a blank frame
 * stays on the panel until the next pan. Unchanged lines are skipped outright,
 * which on a dashboard where only the clock moves is most of them. */
static void render(int force) {
  int rows = cur->n > prev->n ? cur->n : prev->n;
  olen = 0;
  for (int i = 0; i <= rows && i < MAX_ROWS; i++) {
    const char *a = i <= cur->n ? cur->line[i] : "";
    const char *b = i <= prev->n ? prev->line[i] : "";
    if (!force && !strcmp(a, b)) {
      continue;
    }
    emit("\033[%d;1H%s\033[K", i + 1, a);
  }
  /* A forced repaint owns the screen: on the first frame `prev` is empty, so
   * whatever the tty held before -- boot messages, a session that failed to
   * start -- is below the frame and would never be repainted away. */
  if (force || cur->n < prev->n) {
    emit("\033[%d;1H\033[J", cur->n + 2);
  }
  if (olen) {
    ssize_t w = write(STDOUT_FILENO, obuf, olen);
    (void)w;
  }
  struct screen *t = cur;
  cur = prev;
  prev = t;
  screen_reset(cur);
}

/* ---- terminal -------------------------------------------------------------- */

static int screen_rows = 24;
static int screen_cols = 80;
static struct termios saved_term;
static int term_saved;

static void measure_screen(void) {
  struct winsize ws;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row && ws.ws_col) {
    screen_rows = ws.ws_row;
    screen_cols = ws.ws_col;
  }
}

static void term_restore(void) {
  if (term_saved) {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_term);
    term_saved = 0;
  }
  ssize_t w = write(STDOUT_FILENO, "\033[?25h" RST "\n", 8);
  (void)w;
}

static void term_raw(void) {
  if (tcgetattr(STDIN_FILENO, &saved_term) < 0) {
    return;
  }
  struct termios raw = saved_term;
  raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
  raw.c_cc[VMIN] = 0;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0) {
    term_saved = 1;
  }
}

/* ---- backlight ------------------------------------------------------------- */

static long backlight_max;

static void backlight_path(char *out_path, size_t n, const char *leaf) {
  snprintf(out_path, n, "%s/%s", cfg.backlight, leaf);
}

static long backlight_level(void) {
  char p[PATH_MAX];
  backlight_path(p, sizeof p, "brightness");
  return (long)read_ll(rp(p), 0);
}

static int write_num(const char *path, long v) {
  int fd = open(path, O_WRONLY | O_CLOEXEC | O_TRUNC);
  if (fd < 0) {
    return -1;
  }
  char buf[32];
  int len = snprintf(buf, sizeof buf, "%ld\n", v);
  ssize_t w = write(fd, buf, (size_t)len);
  close(fd);
  return w == len ? 0 : -1;
}

static void saved_level_path(char *out_path, size_t n) {
  snprintf(out_path, n, "%s/brightness", cfg.state_dir);
}

static void display_off(void) {
  char p[PATH_MAX], s[PATH_MAX];
  backlight_path(p, sizeof p, "brightness");
  saved_level_path(s, sizeof s);
  long cur_level = backlight_level();
  if (cur_level > 0) {
    write_num(rp(s), cur_level);
  }
  write_num(rp(p), 0);
}

static void display_on(void) {
  char p[PATH_MAX], s[PATH_MAX];
  backlight_path(p, sizeof p, "brightness");
  saved_level_path(s, sizeof s);
  long level = (long)read_ll(rp(s), 0);
  if (level <= 0) {
    level = cfg.default_brightness;
  }
  write_num(rp(p), level);
  unlink(rp(s));
}

static void display_toggle(void) {
  if (backlight_level() > 0) {
    display_off();
  } else {
    display_on();
  }
}

/* ---- systemd bus ----------------------------------------------------------- */

static sd_bus *bus;

static void bus_init(void) {
  if (cfg.root[0]) {
    return;
  }
  if (sd_bus_default_system(&bus) < 0) {
    bus = NULL;
  }
}

static void unit_state(const char *unit, char *out_state, size_t n) {
  snprintf(out_state, n, "unknown");

  if (cfg.root[0]) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/fixture/units/%s.service", cfg.root, unit);
    first_line(path, out_state, n);
    return;
  }
  if (!bus) {
    return;
  }

  char full[128];
  snprintf(full, sizeof full, "%s.service", unit);
  char *path = NULL;
  if (sd_bus_path_encode("/org/freedesktop/systemd1/unit", full, &path) < 0) {
    return;
  }
  char *value = NULL;
  int r = sd_bus_get_property_string(bus, "org.freedesktop.systemd1", path,
                                     "org.freedesktop.systemd1.Unit",
                                     "ActiveState", NULL, &value);
  if (r >= 0 && value) {
    snprintf(out_state, n, "%s", value);
  }
  free(value);
  free(path);
}

static void failed_units(char *out_units, size_t n) {
  out_units[0] = '\0';

  if (cfg.root[0]) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/fixture/failed", cfg.root);
    first_line(path, out_units, n);
    return;
  }
  if (!bus) {
    return;
  }

  sd_bus_message *reply = NULL;
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int r = sd_bus_call_method(bus, "org.freedesktop.systemd1",
                             "/org/freedesktop/systemd1",
                             "org.freedesktop.systemd1.Manager",
                             "ListUnitsFiltered", &err, &reply, "as", 1,
                             "failed");
  if (r < 0) {
    sd_bus_error_free(&err);
    return;
  }
  if (sd_bus_message_enter_container(reply, 'a', "(ssssssouso)") >= 0) {
    const char *id, *desc, *load, *active, *sub, *follow, *opath, *jtype,
        *jpath;
    uint32_t jid;
    size_t len = 0;
    while (sd_bus_message_read(reply, "(ssssssouso)", &id, &desc, &load,
                               &active, &sub, &follow, &opath, &jid, &jtype,
                               &jpath) > 0) {
      int w = snprintf(out_units + len, n - len, "%s%s", len ? " " : "", id);
      if (w > 0 && (size_t)w < n - len) {
        len += (size_t)w;
      }
    }
    sd_bus_message_exit_container(reply);
  }
  sd_bus_message_unref(reply);
  sd_bus_error_free(&err);
}

/* ---- collectors ------------------------------------------------------------ */

static int core_count(void) {
  char buf[8192];
  if (slurp(rp("/proc/stat"), buf, sizeof buf) < 0) {
    return 1;
  }
  int n = 0;
  for (char *p = buf; p; p = strchr(p, '\n')) {
    if (*p == '\n') {
      p++;
    }
    if (!strncmp(p, "cpu", 3) && isdigit((unsigned char)p[3])) {
      n++;
    }
  }
  return n ? n : 1;
}

static long long cpu_prev_busy, cpu_prev_total;

static int cpu_percent(void) {
  char buf[512];
  int fd = open(rp("/proc/stat"), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return 0;
  }
  ssize_t r = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (r <= 0) {
    return 0;
  }
  buf[r] = '\0';

  long long v[8] = {0};
  if (sscanf(buf, "cpu %lld %lld %lld %lld %lld %lld %lld %lld", &v[0], &v[1],
             &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) < 4) {
    return 0;
  }
  long long total = 0;
  for (int i = 0; i < 8; i++) {
    total += v[i];
  }
  long long busy = total - v[3] - v[4];
  long long dt = total - cpu_prev_total;
  long long db = busy - cpu_prev_busy;
  cpu_prev_total = total;
  cpu_prev_busy = busy;
  return dt > 0 ? (int)(db * 100 / dt) : 0;
}

static void cpu_ghz(char *out_ghz, size_t n) {
  long long top = 0;
  DIR *d = opendir(rp("/sys/devices/system/cpu"));
  if (d) {
    struct dirent *e;
    while ((e = readdir(d))) {
      if (strncmp(e->d_name, "cpu", 3) || !isdigit((unsigned char)e->d_name[3])) {
        continue;
      }
      char p[PATH_MAX];
      snprintf(p, sizeof p, "/sys/devices/system/cpu/%s/cpufreq/scaling_cur_freq",
               e->d_name);
      long long v = read_ll(rp(p), 0);
      if (v > top) {
        top = v;
      }
    }
    closedir(d);
  }
  snprintf(out_ghz, n, "%lld.%02lldGHz", top / 1000000, top % 1000000 / 10000);
}

static void temp_c(const char *path, char *out_temp, size_t n) {
  char buf[64];
  if (first_line(rp(path), buf, sizeof buf) < 0) {
    snprintf(out_temp, n, "?");
    return;
  }
  snprintf(out_temp, n, "%d", (int)(strtoll(buf, NULL, 10) / 1000));
}

/* JEDEC 5.0: DEVICE_LIFE_TIME_EST is consumed write endurance in 10% steps, one
 * hex byte per bank, and PRE_EOL_INFO is a three-state reserved-pool summary. */
static void emmc_health(char *out_health, size_t n) {
  char life[32] = "?";
  char eol[64] = "?";
  char buf[128];

  if (first_line(rp("/sys/block/mmcblk0/device/life_time"), buf, sizeof buf) == 0) {
    long a = 0, b = 0;
    char sa[32] = "", sb[32] = "";
    if (sscanf(buf, "%31s %31s", sa, sb) >= 1) {
      a = strtol(sa[0] == '0' && (sa[1] == 'x' || sa[1] == 'X') ? sa + 2 : sa,
                 NULL, 16);
      b = strtol(sb[0] == '0' && (sb[1] == 'x' || sb[1] == 'X') ? sb + 2 : sb,
                 NULL, 16);
    }
    int v = (int)(a > b ? a : b);
    if (v > 0 && v <= 15) {
      snprintf(life, sizeof life, "%d-%d%%", (v - 1) * 10, v * 10);
    }
  }

  if (first_line(rp("/sys/block/mmcblk0/device/pre_eol_info"), buf, sizeof buf) == 0) {
    if (!strcmp(buf, "01")) {
      snprintf(eol, sizeof eol, "normal");
    } else if (!strcmp(buf, "02")) {
      snprintf(eol, sizeof eol, YEL "warning" RST DIM);
    } else if (!strcmp(buf, "03")) {
      snprintf(eol, sizeof eol, RED "urgent" RST DIM);
    } else {
      snprintf(eol, sizeof eol, "%.31s", buf);
    }
  }

  snprintf(out_health, n, "emmc %s used, %s", life, eol);
}

/* capacity is integer-only on this gauge -- charge_counter is just
 * capacity * charge_full / 100, and there is no raw SOC in /proc or debugfs --
 * so the finer signal is how long the charge lasts at the current draw.
 * charge in uAh, current in the fuel gauge's 0.1 mA steps. */
static void endurance(long long charge, long long raw_ma, long long full,
                      const char *flow, char *out_est, size_t n) {
  out_est[0] = '\0';
  if (!strcmp(flow, "full")) {
    return;
  }
  long long ma = raw_ma < 0 ? -raw_ma : raw_ma;
  ma /= 10;
  if (ma <= 5) {
    return;
  }
  if (!strcmp(flow, "charging")) {
    charge = full - charge;
  }
  if (charge <= 0) {
    return;
  }
  long long mins = charge * 60 / (ma * 1000);
  snprintf(out_est, n, "%lldh%02lldm", mins / 60, mins % 60);
}

struct fsinfo {
  long long total_kb;
  long long used_kb;
  int pct;
};

static void disk_usage(struct fsinfo *fs) {
  unsigned long long blocks = 0, bfree = 0, bavail = 0, frsize = 4096;

  const char *fx = fixture("statvfs");
  if (fx) {
    char buf[256];
    if (first_line(fx, buf, sizeof buf) == 0) {
      sscanf(buf, "%llu %llu %llu %llu", &blocks, &bfree, &bavail, &frsize);
    }
  } else {
    struct statvfs st;
    if (statvfs("/", &st) == 0) {
      blocks = st.f_blocks;
      bfree = st.f_bfree;
      bavail = st.f_bavail;
      frsize = st.f_frsize ? st.f_frsize : st.f_bsize;
    }
  }

  unsigned long long unit = frsize ? frsize : 4096;
  unsigned long long used = blocks - bfree;
  fs->total_kb = (long long)(blocks * unit / 1024);
  fs->used_kb = (long long)(used * unit / 1024);
  /* df rounds Use% up and measures it against what a non-root writer can
   * reach, not against the whole filesystem. */
  unsigned long long denom = used + bavail;
  fs->pct = denom ? (int)((used * 100 + denom - 1) / denom) : 0;
}

static void iface_addr(const char *name, char *out_addr, size_t n) {
  snprintf(out_addr, n, "-");

  const char *fx = fixture("ifaddr");
  if (fx) {
    char buf[4096];
    if (slurp(fx, buf, sizeof buf) < 0) {
      return;
    }
    char *save = NULL;
    for (char *l = strtok_r(buf, "\n", &save); l; l = strtok_r(NULL, "\n", &save)) {
      char iface[64], addr[64];
      if (sscanf(l, "%63s %63s", iface, addr) == 2 && !strcmp(iface, name)) {
        snprintf(out_addr, n, "%s", addr);
        return;
      }
    }
    return;
  }

  struct ifaddrs *ifa;
  if (getifaddrs(&ifa) < 0) {
    return;
  }
  for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
    if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) {
      continue;
    }
    if (strcmp(p->ifa_name, name)) {
      continue;
    }
    struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
    uint32_t mask = 0;
    if (p->ifa_netmask) {
      mask = ntohl(((struct sockaddr_in *)p->ifa_netmask)->sin_addr.s_addr);
    }
    int prefix = 0;
    for (int i = 31; i >= 0 && (mask & (1u << i)); i--) {
      prefix++;
    }
    uint32_t a = ntohl(sin->sin_addr.s_addr);
    snprintf(out_addr, n, "%u.%u.%u.%u/%d", a >> 24, (a >> 16) & 0xff,
             (a >> 8) & 0xff, a & 0xff, prefix);
    break;
  }
  freeifaddrs(ifa);
}

static void default_gateway(char *out_gw, size_t n) {
  out_gw[0] = '\0';
  char buf[16384];
  if (slurp(rp("/proc/net/route"), buf, sizeof buf) < 0) {
    return;
  }
  char *save = NULL;
  char *line = strtok_r(buf, "\n", &save);
  for (line = strtok_r(NULL, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
    char iface[64];
    unsigned dest, gw, flags;
    if (sscanf(line, "%63s %x %x %x", iface, &dest, &gw, &flags) < 4) {
      continue;
    }
    if (dest != 0) {
      continue;
    }
    snprintf(out_gw, n, "%u.%u.%u.%u", gw & 0xff, (gw >> 8) & 0xff,
             (gw >> 16) & 0xff, (gw >> 24) & 0xff);
    return;
  }
}

/* /proc/net/tcp holds addresses as host-order hex, so the octets come out
 * reversed on a little-endian machine and tcp6 packs four such words. */
#define TCP_ESTABLISHED 0x01
#define TCP_LISTEN 0x0a
#define MAX_CONNS 512

struct conn {
  int local_port;
  int state;
  char peer[80];
};

static struct conn conns[MAX_CONNS];
static int nconns;

static void format_v4(unsigned a, char *out_addr, size_t n) {
  snprintf(out_addr, n, "%u.%u.%u.%u", a & 0xff, (a >> 8) & 0xff,
           (a >> 16) & 0xff, (a >> 24) & 0xff);
}

static void scan_tcp_file(const char *path, int v6) {
  char buf[512 * 1024];
  if (slurp(rp(path), buf, sizeof buf) < 0) {
    return;
  }
  char *save = NULL;
  char *line = strtok_r(buf, "\n", &save);
  for (line = strtok_r(NULL, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
    if (nconns >= MAX_CONNS) {
      return;
    }
    char local[128], remote[128];
    unsigned state;
    if (sscanf(line, "%*d: %127s %127s %x", local, remote, &state) != 3) {
      continue;
    }
    char *lp = strrchr(local, ':');
    char *rp_ = strrchr(remote, ':');
    if (!lp || !rp_) {
      continue;
    }
    *lp++ = '\0';
    *rp_++ = '\0';

    struct conn *c = &conns[nconns++];
    c->state = (int)state;
    c->local_port = (int)strtol(lp, NULL, 16);

    unsigned words[4] = {0};
    int nw = v6 ? 4 : 1;
    for (int i = 0; i < nw; i++) {
      char word[9];
      memcpy(word, remote + i * 8, 8);
      word[8] = '\0';
      words[i] = (unsigned)strtoul(word, NULL, 16);
    }
    char host[64];
    if (!v6) {
      format_v4(words[0], host, sizeof host);
    } else if (words[0] == 0 && words[1] == 0 && words[2] == 0xffff0000u) {
      format_v4(words[3], host, sizeof host);
    } else {
      snprintf(host, sizeof host, "[%08x:%08x:%08x:%08x]", words[0], words[1],
               words[2], words[3]);
    }
    snprintf(c->peer, sizeof c->peer, "%.63s:%u", host,
             (unsigned)strtoul(rp_, NULL, 16));
  }
}

static void scan_tcp(void) {
  nconns = 0;
  scan_tcp_file("/proc/net/tcp", 0);
  scan_tcp_file("/proc/net/tcp6", 1);
}

static int clients_on(int port) {
  int c = 0;
  for (int i = 0; i < nconns; i++) {
    if (conns[i].state == TCP_ESTABLISHED && conns[i].local_port == port) {
      c++;
    }
  }
  return c;
}

static void peers_on(int port, char *out_peers, size_t n) {
  size_t len = 0;
  out_peers[0] = '\0';
  for (int i = 0; i < nconns; i++) {
    if (conns[i].state != TCP_ESTABLISHED || conns[i].local_port != port) {
      continue;
    }
    int w = snprintf(out_peers + len, n - len, "%s%s", len ? " " : "",
                     conns[i].peer);
    if (w > 0 && (size_t)w < n - len) {
      len += (size_t)w;
    }
  }
}

static int cmp_int(const void *a, const void *b) {
  return *(const int *)a - *(const int *)b;
}

static void listening_ports(char *out_ports, size_t n) {
  int ports[MAX_CONNS];
  int np = 0;
  for (int i = 0; i < nconns; i++) {
    if (conns[i].state != TCP_LISTEN) {
      continue;
    }
    ports[np++] = conns[i].local_port;
  }
  qsort(ports, (size_t)np, sizeof(int), cmp_int);

  size_t len = 0;
  out_ports[0] = '\0';
  int last = -1;
  for (int i = 0; i < np; i++) {
    if (ports[i] == last) {
      continue;
    }
    last = ports[i];
    int w = snprintf(out_ports + len, n - len, "%s%d", len ? " " : "", ports[i]);
    if (w > 0 && (size_t)w < n - len) {
      len += (size_t)w;
    }
  }
  if (!len) {
    snprintf(out_ports, n, "-");
  }
}

struct proc_entry {
  int pid;
  long rss_kb;
  char comm[32];
};

static int cmp_rss(const void *a, const void *b) {
  const struct proc_entry *x = a, *y = b;
  return y->rss_kb > x->rss_kb ? 1 : y->rss_kb < x->rss_kb ? -1 : 0;
}

static int scan_procs(struct proc_entry *list, int max) {
  DIR *d = opendir(rp("/proc"));
  if (!d) {
    return 0;
  }
  long page_kb = sysconf(_SC_PAGESIZE) / 1024;
  int n = 0;
  struct dirent *e;
  while ((e = readdir(d)) && n < max) {
    if (!isdigit((unsigned char)e->d_name[0])) {
      continue;
    }
    char p[PATH_MAX], buf[256];
    snprintf(p, sizeof p, "/proc/%s/statm", e->d_name);
    if (first_line(rp(p), buf, sizeof buf) < 0) {
      continue;
    }
    long long size = 0, resident = 0;
    if (sscanf(buf, "%lld %lld", &size, &resident) != 2 || resident == 0) {
      continue;
    }
    snprintf(p, sizeof p, "/proc/%s/comm", e->d_name);
    if (first_line(rp(p), list[n].comm, sizeof list[n].comm) < 0) {
      continue;
    }
    list[n].pid = atoi(e->d_name);
    list[n].rss_kb = (long)(resident * page_kb);
    n++;
  }
  closedir(d);
  qsort(list, (size_t)n, sizeof *list, cmp_rss);
  return n;
}

static void top_rss(char *out_top, size_t n) {
  static struct proc_entry list[4096];
  int found = scan_procs(list, 4096);
  size_t len = 0;
  out_top[0] = '\0';
  for (int i = 0; i < found && i < MAX_TOP; i++) {
    int w = snprintf(out_top + len, n - len, "%s %ldM  ", list[i].comm,
                     list[i].rss_kb / 1024);
    if (w > 0 && (size_t)w < n - len) {
      len += (size_t)w;
    }
  }
}

/* sshd names its per-session process after the peer, which is the only place
 * the logged-in name appears without asking utmp about a session that a bare
 * `ssh host cmd` never creates. */
static void ssh_users(char *out_users, size_t n) {
  char names[16][64];
  int nn = 0;
  DIR *d = opendir(rp("/proc"));
  if (!d) {
    snprintf(out_users, n, "-");
    return;
  }
  struct dirent *e;
  while ((e = readdir(d)) && nn < 16) {
    if (!isdigit((unsigned char)e->d_name[0])) {
      continue;
    }
    char p[PATH_MAX], buf[1024];
    snprintf(p, sizeof p, "/proc/%s/cmdline", e->d_name);
    ssize_t r = slurp(rp(p), buf, sizeof buf);
    if (r <= 0) {
      continue;
    }
    for (ssize_t i = 0; i < r; i++) {
      if (buf[i] == '\0') {
        buf[i] = ' ';
      }
    }
    if (strncmp(buf, "sshd", 4)) {
      continue;
    }
    char *colon = strstr(buf, ": ");
    if (!colon) {
      continue;
    }
    char *at = strchr(colon + 2, '@');
    if (!at) {
      continue;
    }
    size_t len = (size_t)(at - (colon + 2));
    if (!len || len >= 64 || memchr(colon + 2, ' ', len) ||
        memchr(colon + 2, '[', len)) {
      continue;
    }
    char name[64];
    memcpy(name, colon + 2, len);
    name[len] = '\0';

    int dup = 0;
    for (int i = 0; i < nn; i++) {
      if (!strcmp(names[i], name)) {
        dup = 1;
      }
    }
    if (!dup) {
      snprintf(names[nn++], 64, "%s", name);
    }
  }
  closedir(d);

  size_t len = 0;
  out_users[0] = '\0';
  for (int i = 0; i < nn; i++) {
    int w = snprintf(out_users + len, n - len, "%s%s", len ? "," : "", names[i]);
    if (w > 0 && (size_t)w < n - len) {
      len += (size_t)w;
    }
  }
  if (!len) {
    snprintf(out_users, n, "-");
  }
}

static void tty_sessions(char *out_ttys, size_t n) {
  size_t len = 0;
  out_ttys[0] = '\0';

  utmpxname(rp("/var/run/utmp"));
  setutxent();
  struct utmpx *u;
  while ((u = getutxent())) {
    if (u->ut_type != USER_PROCESS) {
      continue;
    }
    time_t t = u->ut_tv.tv_sec;
    struct tm tm;
    char when[16] = "?";
    if (localtime_r(&t, &tm)) {
      strftime(when, sizeof when, "%H:%M", &tm);
    }
    int w = snprintf(out_ttys + len, n - len, "%.32s@%.32s since %s   ",
                     u->ut_user, u->ut_line, when);
    if (w > 0 && (size_t)w < n - len) {
      len += (size_t)w;
    }
  }
  endutxent();
  if (!len) {
    snprintf(out_ttys, n, "-");
  }
}

/* ---- tailscale peer count -------------------------------------------------- */

/* tailscale status costs about a fifth of a second here, so it runs detached
 * and the count it produces lands on a later frame rather than holding one up. */
static char peers[32] = "-";
static pid_t ts_pid = -1;
static int ts_fd = -1;
static int ts_count;
static char ts_buf[4096];
static size_t ts_len;

static void tailscale_start(void) {
  if (cfg.root[0]) {
    const char *fx = fixture("tailscale-peers");
    if (fx) {
      first_line(fx, peers, sizeof peers);
    }
    return;
  }
  if (ts_pid > 0) {
    return;
  }
  int fds[2];
  if (pipe2(fds, O_CLOEXEC) < 0) {
    return;
  }
  pid_t pid = fork();
  if (pid < 0) {
    close(fds[0]);
    close(fds[1]);
    return;
  }
  if (pid == 0) {
    dup2(fds[1], STDOUT_FILENO);
    int null = open("/dev/null", O_WRONLY);
    if (null >= 0) {
      dup2(null, STDERR_FILENO);
    }
    execlp(cfg.tailscale, cfg.tailscale, "status", "--self=false", (char *)NULL);
    _exit(127);
  }
  close(fds[1]);
  ts_pid = pid;
  ts_fd = fds[0];
  ts_count = 0;
  ts_len = 0;
}

static void tailscale_drain(void) {
  char buf[4096];
  for (;;) {
    ssize_t r = read(ts_fd, buf, sizeof buf);
    if (r > 0) {
      for (ssize_t i = 0; i < r; i++) {
        if (buf[i] == '\n') {
          ts_buf[ts_len] = '\0';
          if (!strncmp(ts_buf, "100.", 4)) {
            ts_count++;
          }
          ts_len = 0;
        } else if (ts_len + 1 < sizeof ts_buf) {
          ts_buf[ts_len++] = buf[i];
        }
      }
      continue;
    }
    if (r < 0 && errno == EINTR) {
      continue;
    }
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return;
    }
    break;
  }

  int status = 0;
  waitpid(ts_pid, &status, 0);
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
    snprintf(peers, sizeof peers, "%d", ts_count);
  }
  close(ts_fd);
  ts_fd = -1;
  ts_pid = -1;
}

/* ---- dashboard ------------------------------------------------------------- */

static int cores;

static void build_dashboard(void) {
  char buf[8192];
  char host[128] = "?";
  char kernel[128] = "?";
  char generation[64] = "?";
  char now[32] = "";
  char tmp[256];

  time_t t = cfg.fixed_now >= 0 ? (time_t)cfg.fixed_now : time(NULL);
  struct tm tm;
  if (localtime_r(&t, &tm)) {
    strftime(now, sizeof now, "%Y-%m-%d %H:%M:%S", &tm);
  }

  first_line(rp("/proc/sys/kernel/hostname"), host, sizeof host);

  long long uptime_s = 0;
  if (first_line(rp("/proc/uptime"), buf, sizeof buf) == 0) {
    uptime_s = strtoll(buf, NULL, 10);
  }

  char l1[16] = "?", l5[16] = "?", l15[16] = "?", procs[32] = "?";
  if (first_line(rp("/proc/loadavg"), buf, sizeof buf) == 0) {
    sscanf(buf, "%15s %15s %15s %31s", l1, l5, l15, procs);
  }

  if (first_line(rp("/proc/version"), buf, sizeof buf) == 0) {
    sscanf(buf, "%*s %*s %127s", kernel);
  }

  if (read_link(rp("/nix/var/nix/profiles/system"), buf, sizeof buf) == 0) {
    char *base = strrchr(buf, '/');
    base = base ? base + 1 : buf;
    if (!strncmp(base, "system-", 7)) {
      base += 7;
    }
    char *dash = strstr(base, "-link");
    if (dash) {
      *dash = '\0';
    }
    snprintf(generation, sizeof generation, "%.63s", base);
  }

  char booted_link[PATH_MAX], current_link[PATH_MAX];
  read_link(rp("/run/booted-system"), booted_link, sizeof booted_link);
  read_link(rp("/run/current-system"), current_link, sizeof current_link);
  const char *booted = strcmp(booted_link, current_link) ? YEL : DIM;

  int pct = cpu_percent();
  char ghz[32], soc_t[16];
  cpu_ghz(ghz, sizeof ghz);
  temp_c("/sys/class/thermal/thermal_zone1/temp", soc_t, sizeof soc_t);

  long long memtotal = 0, memavail = 0, swaptotal = 0, swapfree = 0;
  if (slurp(rp("/proc/meminfo"), buf, sizeof buf) > 0) {
    char *save = NULL;
    for (char *l = strtok_r(buf, "\n", &save); l; l = strtok_r(NULL, "\n", &save)) {
      char key[32];
      long long v;
      if (sscanf(l, "%31s %lld", key, &v) != 2) {
        continue;
      }
      if (!strcmp(key, "MemTotal:")) {
        memtotal = v;
      } else if (!strcmp(key, "MemAvailable:")) {
        memavail = v;
      } else if (!strcmp(key, "SwapTotal:")) {
        swaptotal = v;
      } else if (!strcmp(key, "SwapFree:")) {
        swapfree = v;
      }
    }
  }
  long long memused = memtotal - memavail;

  long long zorig = 0, zcompr = 0;
  char zratio[16] = "-";
  if (first_line(rp("/sys/block/zram0/mm_stat"), buf, sizeof buf) == 0) {
    if (sscanf(buf, "%lld %lld", &zorig, &zcompr) == 2 && zcompr > 0) {
      snprintf(zratio, sizeof zratio, "%lld.%lldx", zorig / zcompr,
               zorig * 10 / zcompr % 10);
    }
  }

  struct fsinfo fs;
  disk_usage(&fs);

  char bat[PATH_MAX];
#define BATF(leaf, dflt)                                                       \
  (snprintf(bat, sizeof bat, "/sys/class/power_supply/battery/" leaf),          \
   read_ll(rp(bat), dflt))
  long long cap = BATF("capacity", 0);
  long long volt = BATF("voltage_now", 0);
  long long curr = BATF("current_avg", 0);
  if (curr == 0) {
    curr = BATF("current_now", 0);
  }
  long long batt_t = BATF("temp", 0);
  long long charge = BATF("charge_counter", 0);
  long long charge_full = BATF("charge_full", 0);
#undef BATF
  long long input_ua = read_ll(rp("/sys/class/power_supply/main/input_current_now"), 0);

  char status[32] = "?";
  first_line(rp("/sys/class/power_supply/battery/status"), status, sizeof status);
  const char *flow = "draining";
  if (!strcmp(status, "Charging")) {
    flow = "charging";
  } else if (!strcmp(status, "Full")) {
    flow = "full";
  }
  char est[32];
  endurance(charge, curr, charge_full, flow, est, sizeof est);

  long level = backlight_level();
  const char *panel_state = level > 0 ? "on" : "off";

  scan_tcp();

  char users[256], peer_list[512], ttys[512], failed[512];
  ssh_users(users, sizeof users);
  peers_on(22, peer_list, sizeof peer_list);
  if (!peer_list[0]) {
    snprintf(peer_list, sizeof peer_list, "-");
  }
  tty_sessions(ttys, sizeof ttys);
  failed_units(failed, sizeof failed);

  char listening[1024];
  listening_ports(listening, sizeof listening);

  for (int i = 0; i < cfg.top_margin; i++) {
    out("\n");
  }

  char upper[128];
  size_t hl = strlen(host);
  for (size_t i = 0; i < hl && i + 1 < sizeof upper; i++) {
    upper[i] = (char)toupper((unsigned char)host[i]);
  }
  upper[hl < sizeof upper - 1 ? hl : sizeof upper - 1] = '\0';

  out("  " BLD CYN "%s" RST "   " DIM, upper);
  if (cfg.subtitle[0]) {
    out("%s . ", cfg.subtitle);
  }
  out("%s" RST "\n\n", now);

  char up[64];
  duration(uptime_s, up, sizeof up);
  label("HOST");
  out(BLD "%s" RST "   linux %s   gen %s%s" RST "   up %s\n", host, kernel,
      booted, generation, up);

  label("LOAD");
  out("%s %s %s   procs %s   " DIM "%s" RST "\n\n", l1, l5, l15, procs,
      cfg.load_note);

  char b[64];
  label("CPU");
  bar(pct, 100, 10, b, sizeof b);
  out("%s %3d%%   %dx %s   soc %sC\n", b, pct, cores, ghz, soc_t);

  char a1[32], a2[32], top[256];
  label("MEM");
  bar(memused, memtotal, 10, b, sizeof b);
  human_kb(memused, a1, sizeof a1);
  human_kb(memtotal, a2, sizeof a2);
  top_rss(top, sizeof top);
  out("%s %6s / %-6s " DIM "top %s" RST "\n", b, a1, a2, top);

  label("SWAP");
  bar(swaptotal - swapfree, swaptotal, 10, b, sizeof b);
  human_kb(swaptotal - swapfree, a1, sizeof a1);
  human_kb(swaptotal, a2, sizeof a2);
  human_kb(zcompr / 1024, tmp, sizeof tmp);
  out("%s %6s / %-6s " DIM "zram holds %s at %s" RST "\n", b, a1, a2, tmp, zratio);

  char health[128];
  label("DISK");
  bar(fs.pct, 100, 10, b, sizeof b);
  human_kb(fs.used_kb, a1, sizeof a1);
  human_kb(fs.total_kb, a2, sizeof a2);
  emmc_health(health, sizeof health);
  out("%s %6s / %-6s " DIM "%s" RST "\n", b, a1, a2, health);

  label("BATT");
  bar(cap, 100, 10, b, sizeof b);
  out("%s %3lld%%  %-8s %lld.%03lldV  %+lldmA  %lld.%lldC  " DIM "%s%s%s, in %lldmA" RST "\n",
      b, cap, status, volt / 1000000, volt % 1000000 / 1000, curr / 10,
      batt_t / 10, batt_t % 10, est, est[0] ? " " : "", flow, input_ua / 1000);

  label("PANEL");
  out("%s  " DIM "%ld of %ld" RST "\n\n", panel_state, level, backlight_max);

  char rndis[64], ts[64], gw[64];
  iface_addr("rndis0", rndis, sizeof rndis);
  iface_addr("tailscale0", ts, sizeof ts);
  default_gateway(gw, sizeof gw);
  label("NET");
  out("rndis0      %-20s tailscale0  %s\n", rndis, ts);
  out("        gateway     %-20s peers       %s\n", gw, peers);
  out("        " DIM "listening   %s" RST "\n\n", listening);

  label("SVC");
  const char *pad = "";
  for (int i = 0; i < cfg.nservices; i++) {
    char state[64], coloured[128], mem_h[32];
    unit_state(cfg.services[i].unit, state, sizeof state);
    state_of(state, coloured, sizeof coloured);
    snprintf(tmp, sizeof tmp, "/sys/fs/cgroup/system.slice/%s.service/memory.current",
             cfg.services[i].unit);
    /* MemoryCurrent comes from the cgroup rather than the bus: asking systemd
     * for it also makes it stat cpu.stat, which this kernel does not carry, and
     * it logs a failure to the journal on every repaint. */
    human_kb(read_ll(rp(tmp), 0) / 1024, mem_h, sizeof mem_h);
    out("%s" BLD "%-11s" RST " %s %6s", pad, cfg.services[i].unit, coloured, mem_h);
    if (cfg.services[i].port) {
      out("  %d clients", clients_on(cfg.services[i].port));
    }
    out("\n");
    pad = "        ";
  }
  if (failed[0]) {
    out("        " RED "failed      %s" RST "\n\n", failed);
  } else {
    out("        " DIM "failed      none" RST "\n\n");
  }

  label("SSH");
  out("%-22s %s\n", users, peer_list);
  label("TTY");
  out("%s\n\n", ttys);

  out(" " BLD "power" RST " screen   " BLD "hold power" RST " menu" DIM
      "        every %ds" RST "\n",
      cfg.interval);
}

/* ---- log sources ----------------------------------------------------------- */

struct textbuf {
  char **line;
  int n;
  int cap;
};

static void tb_free(struct textbuf *tb) {
  for (int i = 0; i < tb->n; i++) {
    free(tb->line[i]);
  }
  free(tb->line);
  tb->line = NULL;
  tb->n = 0;
  tb->cap = 0;
}

static void tb_push(struct textbuf *tb, const char *s) {
  if (tb->n == tb->cap) {
    int cap = tb->cap ? tb->cap * 2 : 256;
    char **grown = realloc(tb->line, (size_t)cap * sizeof *grown);
    if (!grown) {
      return;
    }
    tb->line = grown;
    tb->cap = cap;
  }
  tb->line[tb->n] = strdup(s);
  if (tb->line[tb->n]) {
    tb->n++;
  }
}

static void tb_pushf(struct textbuf *tb, const char *fmt, ...) {
  char buf[4096];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  tb_push(tb, buf);
}

static const char *jfield(sd_journal *j, const char *field, char *buf,
                          size_t n) {
  const void *data;
  size_t len;
  if (sd_journal_get_data(j, field, &data, &len) < 0) {
    return NULL;
  }
  size_t skip = strlen(field) + 1;
  if (len <= skip) {
    return NULL;
  }
  len -= skip;
  if (len > n - 1) {
    len = n - 1;
  }
  memcpy(buf, (const char *)data + skip, len);
  buf[len] = '\0';
  return buf;
}

static void journal_format(sd_journal *j, struct textbuf *tb) {
  char ident[128], pid[32], msg[3072];
  uint64_t usec = 0;
  sd_journal_get_realtime_usec(j, &usec);

  char when[32] = "";
  time_t t = (time_t)(usec / 1000000);
  struct tm tm;
  if (localtime_r(&t, &tm)) {
    strftime(when, sizeof when, "%b %d %H:%M:%S", &tm);
  }

  const char *id = jfield(j, "SYSLOG_IDENTIFIER", ident, sizeof ident);
  if (!id) {
    id = jfield(j, "_COMM", ident, sizeof ident);
  }
  const char *p = jfield(j, "_PID", pid, sizeof pid);
  const char *m = jfield(j, "MESSAGE", msg, sizeof msg);

  tb_pushf(tb, "%s %s%s%s%s: %s", when, id ? id : "?", p ? "[" : "",
           p ? p : "", p ? "]" : "", m ? m : "");
}

static void load_journal(struct textbuf *tb, int errors_only) {
  sd_journal *j = NULL;
  if (sd_journal_open(&j, SD_JOURNAL_LOCAL_ONLY) < 0) {
    tb_push(tb, "journal unavailable");
    return;
  }

  char boot_id[64];
  if (first_line(rp("/proc/sys/kernel/random/boot_id"), boot_id, sizeof boot_id) == 0) {
    char match[128];
    size_t o = 0;
    o += (size_t)snprintf(match, sizeof match, "_BOOT_ID=");
    for (const char *c = boot_id; *c; c++) {
      if (*c != '-' && o + 1 < sizeof match) {
        match[o++] = *c;
      }
    }
    match[o] = '\0';
    sd_journal_add_match(j, match, 0);
  }
  if (errors_only) {
    sd_journal_add_conjunction(j);
    for (int p = 0; p <= 3; p++) {
      char match[32];
      snprintf(match, sizeof match, "PRIORITY=%d", p);
      sd_journal_add_match(j, match, 0);
    }
  }

  if (sd_journal_seek_tail(j) < 0 ||
      sd_journal_previous_skip(j, (uint64_t)cfg.log_lines) < 0) {
    sd_journal_close(j);
    return;
  }
  do {
    journal_format(j, tb);
  } while (sd_journal_next(j) > 0);

  if (!tb->n) {
    tb_push(tb, "-- no entries --");
  }
  sd_journal_close(j);
}

/* /dev/kmsg replaces dmesg: records carry microseconds since boot, so the wall
 * clock comes from the current time less the uptime. */
static void load_kmsg(struct textbuf *tb) {
  int fd = open(rp("/dev/kmsg"), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    tb_push(tb, "/dev/kmsg unavailable");
    return;
  }
  lseek(fd, 0, SEEK_SET);

  char uptime[64];
  double up = 0;
  if (first_line(rp("/proc/uptime"), uptime, sizeof uptime) == 0) {
    up = strtod(uptime, NULL);
  }
  time_t boot = time(NULL) - (time_t)up;

  char rec[8192];
  for (;;) {
    ssize_t r = read(fd, rec, sizeof rec - 1);
    if (r < 0) {
      if (errno == EPIPE) {
        continue;
      }
      break;
    }
    if (r == 0) {
      break;
    }
    rec[r] = '\0';

    char *semi = strchr(rec, ';');
    if (!semi) {
      continue;
    }
    *semi = '\0';
    unsigned long long usec = 0;
    if (sscanf(rec, "%*u,%*u,%llu", &usec) != 1) {
      continue;
    }
    char *msg = semi + 1;
    msg[strcspn(msg, "\n")] = '\0';

    time_t t = boot + (time_t)(usec / 1000000);
    struct tm tm;
    char when[40] = "?";
    if (localtime_r(&t, &tm)) {
      strftime(when, sizeof when, "%a %b %e %H:%M:%S %Y", &tm);
    }
    tb_pushf(tb, "[%s] %s", when, msg);
  }
  close(fd);
  if (!tb->n) {
    tb_push(tb, "-- no entries --");
  }
}

static void load_units(struct textbuf *tb) {
  if (!bus) {
    tb_push(tb, "bus unavailable");
    return;
  }
  sd_bus_message *reply = NULL;
  sd_bus_error err = SD_BUS_ERROR_NULL;
  if (sd_bus_call_method(bus, "org.freedesktop.systemd1",
                         "/org/freedesktop/systemd1",
                         "org.freedesktop.systemd1.Manager", "ListUnits", &err,
                         &reply, "") < 0) {
    tb_pushf(tb, "ListUnits: %s", err.message ? err.message : "failed");
    sd_bus_error_free(&err);
    return;
  }
  if (sd_bus_message_enter_container(reply, 'a', "(ssssssouso)") >= 0) {
    const char *id, *desc, *load, *active, *sub, *follow, *opath, *jtype, *jpath;
    uint32_t jid;
    while (sd_bus_message_read(reply, "(ssssssouso)", &id, &desc, &load, &active,
                               &sub, &follow, &opath, &jid, &jtype, &jpath) > 0) {
      tb_pushf(tb, "%-44s %-8s %-10s %-10s %s", id, load, active, sub, desc);
    }
    sd_bus_message_exit_container(reply);
  }
  sd_bus_message_unref(reply);
  sd_bus_error_free(&err);
}

static void load_network(struct textbuf *tb) {
  struct ifaddrs *ifa = NULL;
  if (getifaddrs(&ifa) == 0) {
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
      if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) {
        continue;
      }
      char addr[64];
      iface_addr(p->ifa_name, addr, sizeof addr);
      tb_pushf(tb, "%-12s %-8s %s", p->ifa_name,
               (p->ifa_flags & IFF_UP) ? "UP" : "DOWN", addr);
    }
    freeifaddrs(ifa);
  }
  tb_push(tb, "");

  char gw[64];
  default_gateway(gw, sizeof gw);
  tb_pushf(tb, "default via %s", gw[0] ? gw : "-");
  tb_push(tb, "");

  scan_tcp();
  tb_push(tb, "established");
  for (int i = 0; i < nconns; i++) {
    if (conns[i].state == TCP_ESTABLISHED) {
      tb_pushf(tb, "  :%-6d %s", conns[i].local_port, conns[i].peer);
    }
  }
}

static void load_processes(struct textbuf *tb) {
  static struct proc_entry list[4096];
  int n = scan_procs(list, 4096);
  tb_pushf(tb, "%7s %-20s %10s", "PID", "COMMAND", "RSS");
  for (int i = 0; i < n && i < 40; i++) {
    tb_pushf(tb, "%7d %-20s %8ldM", list[i].pid, list[i].comm,
             list[i].rss_kb / 1024);
  }
}

/* ---- views ----------------------------------------------------------------- */

enum view { V_DASH, V_MENU, V_PAGER };

static enum view view = V_DASH;
static int menu_sel;
static struct textbuf pager_text;
static int pager_top;
static void (*pager_reload)(struct textbuf *);
static enum view pager_parent = V_MENU;

static const char *const menu_items[] = {"backlight", "boot log", "errors",
                                         "kernel logs", "units", "network",
                                         "back"};
#define MENU_N ((int)(sizeof menu_items / sizeof *menu_items))

static void build_menu(void) {
  long level = backlight_level();
  for (int i = 0; i < cfg.top_margin; i++) {
    out("\n");
  }
  out("  " BLD CYN "MENU" RST "   " DIM "hold power to close" RST "\n\n");
  for (int i = 0; i < MENU_N; i++) {
    out("  %s%-14s" RST, i == menu_sel ? CYN ">" RST " " BLD : "  ",
        menu_items[i]);
    if (!strcmp(menu_items[i], "backlight")) {
      out(DIM "%s, %ld of %ld" RST, level > 0 ? "on" : "off", level,
          backlight_max);
    }
    out("\n");
  }
  out("\n " BLD "vol +/-" RST " move   " BLD "power" RST " select\n");
}

static int pager_rows(void) {
  int rows = screen_rows - cfg.top_margin - 3;
  return rows < 5 ? 5 : rows;
}

static void build_pager(void) {
  int rows = pager_rows();
  int total = pager_text.n;
  int printed = total - pager_top;
  if (printed > rows) {
    printed = rows;
  }
  if (printed < 0) {
    printed = 0;
  }

  for (int i = 0; i < cfg.top_margin; i++) {
    out("\n");
  }
  for (int i = 0; i < rows; i++) {
    int idx = pager_top + i;
    if (idx < total) {
      out("%.*s\n", screen_cols, pager_text.line[idx]);
    } else {
      out("\n");
    }
  }
  out("\n " DIM "%d-%d of %d" RST "   " BLD "vol +/-" RST " scroll   " BLD
      "power" RST " back\n",
      total ? pager_top + 1 : 0, pager_top + printed, total);
}

static void pager_clamp(void) {
  int rows = pager_rows();
  if (pager_top > pager_text.n - rows) {
    pager_top = pager_text.n - rows;
  }
  if (pager_top < 0) {
    pager_top = 0;
  }
}

/* A capture holds the loop for as long as the source takes, so the frame says
 * so before the read starts rather than looking hung. */
static void pager_open(void (*load)(struct textbuf *), enum view parent,
                       int live) {
  screen_reset(cur);
  for (int i = 0; i < cfg.top_margin; i++) {
    out("\n");
  }
  out(" " DIM "reading..." RST "\n");
  render(1);

  tb_free(&pager_text);
  load(&pager_text);
  pager_reload = live ? load : NULL;
  pager_parent = parent;
  pager_top = pager_text.n - pager_rows();
  pager_clamp();
  view = V_PAGER;
}

static void pager_refresh(void) {
  if (!pager_reload) {
    return;
  }
  tb_free(&pager_text);
  pager_reload(&pager_text);
  pager_top = pager_text.n - pager_rows();
  pager_clamp();
}

static void load_boot_log(struct textbuf *tb) { load_journal(tb, 0); }
static void load_errors(struct textbuf *tb) { load_journal(tb, 1); }

static void repaint(int force) {
  screen_reset(cur);
  switch (view) {
    case V_DASH:
      build_dashboard();
      break;
    case V_MENU:
      build_menu();
      break;
    case V_PAGER:
      build_pager();
      break;
  }
  render(force);
}

/* ---- key handling ---------------------------------------------------------- */

enum action { A_NONE, A_UP, A_DOWN, A_SELECT, A_MENU, A_QUIT, A_OTHER };

static void menu_activate(void) {
  const char *item = menu_items[menu_sel];
  if (!strcmp(item, "backlight")) {
    display_toggle();
  } else if (!strcmp(item, "boot log")) {
    pager_open(load_boot_log, V_MENU, 0);
  } else if (!strcmp(item, "errors")) {
    pager_open(load_errors, V_MENU, 0);
  } else if (!strcmp(item, "kernel logs")) {
    pager_open(load_kmsg, V_MENU, 0);
  } else if (!strcmp(item, "units")) {
    pager_open(load_units, V_MENU, 0);
  } else if (!strcmp(item, "network")) {
    pager_open(load_network, V_MENU, 0);
  } else if (!strcmp(item, "back")) {
    view = V_DASH;
  }
}

static int quitting;

static void handle_action(enum action a) {
  if (a == A_NONE) {
    return;
  }
  switch (view) {
    case V_DASH:
      switch (a) {
        case A_MENU:
          view = V_MENU;
          menu_sel = 0;
          break;
        case A_SELECT:
          display_toggle();
          break;
        case A_QUIT:
          quitting = 1;
          break;
        default:
          break;
      }
      break;

    case V_MENU:
      switch (a) {
        case A_UP:
          menu_sel = (menu_sel + MENU_N - 1) % MENU_N;
          break;
        case A_DOWN:
          menu_sel = (menu_sel + 1) % MENU_N;
          break;
        case A_SELECT:
          menu_activate();
          break;
        case A_MENU:
        case A_QUIT:
          view = V_DASH;
          break;
        default:
          break;
      }
      break;

    case V_PAGER:
      switch (a) {
        case A_UP:
          pager_top -= pager_rows() / 2;
          pager_clamp();
          break;
        case A_DOWN:
          pager_top += pager_rows() / 2;
          pager_clamp();
          break;
        default:
          view = pager_parent;
          pager_reload = NULL;
          break;
      }
      break;
  }
  repaint(1);
}

/* Typed keys are only reachable over ssh, where the whole hotkey set from the
 * shell version still applies; the hardware keys go through handle_action. */
static void handle_char(char c) {
  if (view == V_DASH) {
    switch (c) {
      case 'b': pager_open(load_boot_log, V_DASH, 0); break;
      case 'e': pager_open(load_errors, V_DASH, 0); break;
      case 'k': pager_open(load_kmsg, V_DASH, 0); break;
      case 'u': pager_open(load_units, V_DASH, 0); break;
      case 'n': pager_open(load_network, V_DASH, 0); break;
      case 't': pager_open(load_processes, V_DASH, 1); break;
      case 'j': pager_open(load_boot_log, V_DASH, 1); break;
      case 'd':
      case '.': display_toggle(); break;
      case 'm': handle_action(A_MENU); return;
      case 'q': handle_action(A_QUIT); return;
      default: return;
    }
    repaint(1);
    return;
  }

  switch (c) {
    case '+':
    case 'k': handle_action(A_UP); break;
    case '-':
    case 'j': handle_action(A_DOWN); break;
    case '.':
    case '\r':
    case '\n': handle_action(A_SELECT); break;
    case 'm':
    case 'q': handle_action(A_MENU); break;
    default: handle_action(A_OTHER); break;
  }
}

/* Hardware key decoding. A hold is announced the moment the threshold passes,
 * not on release, so the panel reacts while the key is still down. The volume
 * keys repeat instead: mtk-kpd advertises EV_SYN and EV_KEY only, so nothing
 * else produces one here. */
static volatile sig_atomic_t stop_requested;
static int keys_fd = -1;
static int held = -1;
static int held_repeats;
static int announced;
static int pending;
static long due_ms;

static long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* A dark panel spends the first press waking up, as every phone does. A hold
 * emits nothing on the way down, so swallowing it too would leave the menu
 * unreachable from off. */
static int wake_guard(int is_hold) {
  if (backlight_level() > 0) {
    return 1;
  }
  display_on();
  return is_hold;
}

static char key_token(int code, int is_hold) {
  if (code == cfg.k_power) {
    return is_hold ? 'm' : '.';
  }
  if (code == cfg.k_volup) {
    return '+';
  }
  if (code == cfg.k_voldown) {
    return '-';
  }
  return 0;
}

/* Set in the standalone key daemon, where a decoded key goes out on the socket
 * instead of into this process's own views. */
static int mode_keys;
static int keys_client = -1;

static void keys_deliver(int code, int is_hold) {
  if (!wake_guard(is_hold)) {
    return;
  }
  char token = key_token(code, is_hold);
  if (!token) {
    return;
  }
  if (!mode_keys) {
    handle_char(token);
    return;
  }
  /* Without a dashboard on the other end the power key falls back to being the
   * on/off switch, which is what it does on a phone with nothing running. */
  if (keys_client < 0 || write(keys_client, &token, 1) != 1) {
    if (keys_client >= 0) {
      close(keys_client);
      keys_client = -1;
    }
    if (token == '.') {
      display_toggle();
    }
  }
}

static void keys_timeout(void) {
  if (held < 0 || !pending) {
    return;
  }
  if (held_repeats) {
    due_ms = now_ms() + cfg.repeat_ms;
    keys_deliver(held, 0);
  } else {
    announced = 1;
    pending = 0;
    keys_deliver(held, 1);
  }
}

/* One event per wake-up; epoll is level-triggered, so a backlog re-arms it. */
static void keys_readable(void) {
  struct input_event ev;
  ssize_t r = read(keys_fd, &ev, sizeof ev);
  if (r == 0) {
    stop_requested = 1;
    return;
  }
  if (r != (ssize_t)sizeof ev || ev.type != EV_KEY) {
    return;
  }
  int repeats = ev.code == cfg.k_volup || ev.code == cfg.k_voldown;
  if (ev.code != cfg.k_power && !repeats) {
    return;
  }

  /* 1 is a press and 0 a release; 2 is kernel autorepeat, ignored so it cannot
   * double the synthesized one. */
  if (ev.value == 1) {
    held = ev.code;
    held_repeats = repeats;
    announced = 0;
    pending = 1;
    due_ms = now_ms() + cfg.hold_ms;
    if (repeats) {
      keys_deliver(ev.code, 0);
    }
  } else if (ev.value == 0 && ev.code == held) {
    if (!held_repeats && !announced) {
      keys_deliver(held, 0);
    }
    held = -1;
    pending = 0;
  }
}

/* Only the introducer reaches the dispatcher; the rest of the sequence would
 * otherwise read as one keypress per byte. */
static int in_escape;

static void stdin_readable(void) {
  char buf[64];
  ssize_t r = read(STDIN_FILENO, buf, sizeof buf);
  if (r <= 0) {
    return;
  }
  for (ssize_t i = 0; i < r; i++) {
    if (in_escape) {
      if (isalpha((unsigned char)buf[i]) || buf[i] == '~') {
        in_escape = 0;
      }
      continue;
    }
    if (buf[i] == '\033') {
      in_escape = 1;
      continue;
    }
    handle_char(buf[i]);
  }
}

/* ---- key socket ------------------------------------------------------------ */

static int sock_addr(struct sockaddr_un *sa) {
  if (!cfg.socket_path[0] || strlen(cfg.socket_path) >= sizeof sa->sun_path) {
    return -1;
  }
  memset(sa, 0, sizeof *sa);
  sa->sun_family = AF_UNIX;
  snprintf(sa->sun_path, sizeof sa->sun_path, "%s", cfg.socket_path);
  return 0;
}

static int keys_listen(void) {
  struct sockaddr_un sa;
  if (sock_addr(&sa) < 0) {
    return -1;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    return -1;
  }
  unlink(sa.sun_path);
  if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(fd, 4) < 0) {
    close(fd);
    return -1;
  }
  /* The daemon is root and the panel is not, so the socket takes the state
   * directory's group -- the one already granted write access to the backlight
   * -- rather than carrying a gid this binary would have to be told. */
  struct stat st;
  if (stat(rp(cfg.state_dir), &st) == 0) {
    (void)!chown(sa.sun_path, (uid_t)-1, st.st_gid);
  }
  chmod(sa.sun_path, 0660);
  return fd;
}

static int keys_connect(void) {
  struct sockaddr_un sa;
  if (sock_addr(&sa) < 0) {
    return -1;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    return -1;
  }
  if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
    close(fd);
    return -1;
  }
  return fd;
}

/* ---- argument parsing ------------------------------------------------------ */

static void add_service(const char *spec) {
  if (cfg.nservices >= MAX_SERVICES) {
    return;
  }
  struct service *s = &cfg.services[cfg.nservices++];
  const char *colon = strchr(spec, ':');
  if (colon) {
    size_t len = (size_t)(colon - spec);
    if (len >= sizeof s->unit) {
      len = sizeof s->unit - 1;
    }
    memcpy(s->unit, spec, len);
    s->unit[len] = '\0';
    s->port = atoi(colon + 1);
  } else {
    snprintf(s->unit, sizeof s->unit, "%s", spec);
    s->port = 0;
  }
}

enum {
  OPT_ROOT = 1000, OPT_BACKLIGHT, OPT_STATE_DIR, OPT_KEYS, OPT_KEYS_RAW,
  OPT_TAILSCALE, OPT_SUBTITLE, OPT_LOAD_NOTE, OPT_INTERVAL, OPT_LOG_LINES,
  OPT_TOP_MARGIN, OPT_BRIGHTNESS, OPT_HOLD_MS, OPT_REPEAT_MS, OPT_POWER,
  OPT_VOLUP, OPT_VOLDOWN, OPT_SERVICE, OPT_ONCE, OPT_NOW, OPT_SOCKET,
};

static const struct option long_opts[] = {
    {"root", required_argument, NULL, OPT_ROOT},
    {"backlight", required_argument, NULL, OPT_BACKLIGHT},
    {"state-dir", required_argument, NULL, OPT_STATE_DIR},
    {"keys", required_argument, NULL, OPT_KEYS},
    {"keys-raw", no_argument, NULL, OPT_KEYS_RAW},
    {"socket", required_argument, NULL, OPT_SOCKET},
    {"tailscale", required_argument, NULL, OPT_TAILSCALE},
    {"subtitle", required_argument, NULL, OPT_SUBTITLE},
    {"load-note", required_argument, NULL, OPT_LOAD_NOTE},
    {"interval", required_argument, NULL, OPT_INTERVAL},
    {"log-lines", required_argument, NULL, OPT_LOG_LINES},
    {"top-margin", required_argument, NULL, OPT_TOP_MARGIN},
    {"default-brightness", required_argument, NULL, OPT_BRIGHTNESS},
    {"hold-ms", required_argument, NULL, OPT_HOLD_MS},
    {"repeat-ms", required_argument, NULL, OPT_REPEAT_MS},
    {"power", required_argument, NULL, OPT_POWER},
    {"vol-up", required_argument, NULL, OPT_VOLUP},
    {"vol-down", required_argument, NULL, OPT_VOLDOWN},
    {"service", required_argument, NULL, OPT_SERVICE},
    {"once", no_argument, NULL, OPT_ONCE},
    {"now", required_argument, NULL, OPT_NOW},
    {NULL, 0, NULL, 0},
};

static int parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt_long(argc, argv, "", long_opts, NULL)) != -1) {
    switch (c) {
      case OPT_ROOT: cfg.root = optarg; break;
      case OPT_BACKLIGHT: cfg.backlight = optarg; break;
      case OPT_STATE_DIR: cfg.state_dir = optarg; break;
      case OPT_KEYS: cfg.keys_dev = optarg; break;
      case OPT_KEYS_RAW: cfg.keys_raw = 1; break;
      case OPT_SOCKET: cfg.socket_path = optarg; break;
      case OPT_TAILSCALE: cfg.tailscale = optarg; break;
      case OPT_SUBTITLE: cfg.subtitle = optarg; break;
      case OPT_LOAD_NOTE: cfg.load_note = optarg; break;
      case OPT_INTERVAL: cfg.interval = atoi(optarg); break;
      case OPT_LOG_LINES: cfg.log_lines = atoi(optarg); break;
      case OPT_TOP_MARGIN: cfg.top_margin = atoi(optarg); break;
      case OPT_BRIGHTNESS: cfg.default_brightness = atoi(optarg); break;
      case OPT_HOLD_MS: cfg.hold_ms = atoi(optarg); break;
      case OPT_REPEAT_MS: cfg.repeat_ms = atoi(optarg); break;
      case OPT_POWER: cfg.k_power = atoi(optarg); break;
      case OPT_VOLUP: cfg.k_volup = atoi(optarg); break;
      case OPT_VOLDOWN: cfg.k_voldown = atoi(optarg); break;
      case OPT_SERVICE: add_service(optarg); break;
      case OPT_ONCE: cfg.once = 1; break;
      case OPT_NOW: cfg.fixed_now = atol(optarg); break;
      default: return -1;
    }
  }
  if (cfg.interval < 1) {
    cfg.interval = 1;
  }
  return 0;
}

/* ---- entry ----------------------------------------------------------------- */

static void on_signal(int sig) {
  (void)sig;
  stop_requested = 1;
}

static int display_command(int argc, char **argv, const char *what) {
  (void)argc;
  if (!strcmp(what, "on")) {
    display_on();
  } else if (!strcmp(what, "off")) {
    display_off();
  } else if (!strcmp(what, "toggle")) {
    display_toggle();
  } else if (!strcmp(what, "status")) {
    printf("%s\n", backlight_level() > 0 ? "on" : "off");
  } else {
    fprintf(stderr, "usage: %s display [on|off|toggle|status]\n", argv[0]);
    return 2;
  }
  return 0;
}

/* Owns the evdev node and its grab for the whole uptime, so the panel can come
 * and go with tty1's login shell without the keys changing hands. */
static int keys_command(void) {
  if (!cfg.keys_dev[0]) {
    fprintf(stderr, "keys: --keys is required\n");
    return 2;
  }
  mode_keys = 1;

  keys_fd = open(cfg.keys_dev,
                 (cfg.keys_raw ? O_RDWR | O_NONBLOCK : O_RDONLY) | O_CLOEXEC);
  if (keys_fd < 0) {
    perror(cfg.keys_dev);
    return 1;
  }
  if (!cfg.keys_raw) {
    ioctl(keys_fd, EVIOCGRAB, 1);
  }

  int listen_fd = keys_listen();
  int ep = epoll_create1(EPOLL_CLOEXEC);
  struct epoll_event ev = {.events = EPOLLIN, .data.fd = keys_fd};
  epoll_ctl(ep, EPOLL_CTL_ADD, keys_fd, &ev);
  if (listen_fd >= 0) {
    ev.data.fd = listen_fd;
    epoll_ctl(ep, EPOLL_CTL_ADD, listen_fd, &ev);
  }

  while (!stop_requested) {
    int timeout = -1;
    if (held >= 0 && pending) {
      long remaining = due_ms - now_ms();
      timeout = remaining < 0 ? 0 : (int)remaining;
    }

    struct epoll_event events[8];
    int n = epoll_wait(ep, events, 8, timeout);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    if (n == 0) {
      keys_timeout();
      continue;
    }
    for (int i = 0; i < n; i++) {
      int fd = events[i].data.fd;
      if (fd == keys_fd) {
        keys_readable();
      } else if (fd == listen_fd) {
        int c = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) {
          continue;
        }
        /* A newer panel displaces an older one: tty1 can be logged in again
         * before the previous shell's descriptors are reaped. */
        if (keys_client >= 0) {
          epoll_ctl(ep, EPOLL_CTL_DEL, keys_client, NULL);
          close(keys_client);
        }
        keys_client = c;
        ev.data.fd = c;
        epoll_ctl(ep, EPOLL_CTL_ADD, c, &ev);
      } else if (fd == keys_client) {
        char discard[64];
        if (read(keys_client, discard, sizeof discard) <= 0) {
          epoll_ctl(ep, EPOLL_CTL_DEL, keys_client, NULL);
          close(keys_client);
          keys_client = -1;
        }
      }
    }
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *subcommand = NULL;
  if (argc > 1 && (!strcmp(argv[1], "display") || !strcmp(argv[1], "keys"))) {
    subcommand = argv[1];
    argv[1] = argv[0];
    argc--;
    argv++;
  }
  if (parse_args(argc, argv) < 0) {
    return 2;
  }

  if (subcommand && !strcmp(subcommand, "display")) {
    return display_command(argc, argv,
                           optind < argc ? argv[optind] : "toggle");
  }

  signal(SIGPIPE, SIG_IGN);

  if (subcommand && !strcmp(subcommand, "keys")) {
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    return keys_command();
  }

  char p[PATH_MAX];
  backlight_path(p, sizeof p, "max_brightness");
  backlight_max = (long)read_ll(rp(p), 0);
  cores = core_count();

  if (!isatty(STDIN_FILENO)) {
    cfg.once = 1;
  }

  if (cfg.once) {
    measure_screen();
    bus_init();
    tailscale_start();
    if (ts_fd >= 0) {
      tailscale_drain();
    }
    /* The first sample has no predecessor, so busy time is measured against a
     * short interval rather than reported as the average since boot. */
    cpu_percent();
    usleep(200000);
    screen_reset(cur);
    build_dashboard();
    for (int i = 0; i < cur->n; i++) {
      printf("%s\n", cur->line[i]);
    }
    if (cur->line[cur->n][0]) {
      printf("%s\n", cur->line[cur->n]);
    }
    return 0;
  }

  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  signal(SIGHUP, on_signal);
  signal(SIGPIPE, SIG_IGN);

  measure_screen();
  bus_init();
  term_raw();
  ssize_t w = write(STDOUT_FILENO, "\033[?25l\033[2J", 10);
  (void)w;

  /* The evdev node is normally held by the key daemon and reaches the panel as
   * tokens on a socket; opening it here is the off-device path, where a fifo of
   * packed events stands in for the keypad. */
  if (cfg.keys_dev[0]) {
    keys_fd = open(cfg.keys_dev,
                   (cfg.keys_raw ? O_RDWR | O_NONBLOCK : O_RDONLY) | O_CLOEXEC);
    if (keys_fd >= 0 && !cfg.keys_raw) {
      ioctl(keys_fd, EVIOCGRAB, 1);
    }
  }
  int sock_fd = keys_connect();

  int ep = epoll_create1(EPOLL_CLOEXEC);
  int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
  struct itimerspec its = {.it_interval = {.tv_sec = cfg.interval},
                           .it_value = {.tv_sec = cfg.interval}};
  timerfd_settime(tfd, 0, &its, NULL);

  struct epoll_event ev = {.events = EPOLLIN, .data.fd = tfd};
  epoll_ctl(ep, EPOLL_CTL_ADD, tfd, &ev);
  ev.data.fd = STDIN_FILENO;
  epoll_ctl(ep, EPOLL_CTL_ADD, STDIN_FILENO, &ev);
  if (keys_fd >= 0) {
    ev.data.fd = keys_fd;
    epoll_ctl(ep, EPOLL_CTL_ADD, keys_fd, &ev);
  }
  if (sock_fd >= 0) {
    ev.data.fd = sock_fd;
    epoll_ctl(ep, EPOLL_CTL_ADD, sock_fd, &ev);
  }

  int registered_ts = -1;
  int tick = 0;
  cpu_percent();
  tailscale_start();
  repaint(1);

  while (!stop_requested && !quitting) {
    if (ts_fd >= 0 && ts_fd != registered_ts) {
      ev.data.fd = ts_fd;
      epoll_ctl(ep, EPOLL_CTL_ADD, ts_fd, &ev);
      registered_ts = ts_fd;
    }

    int timeout = -1;
    if (held >= 0 && pending) {
      long remaining = due_ms - now_ms();
      timeout = remaining < 0 ? 0 : (int)remaining;
    }

    struct epoll_event events[8];
    int n = epoll_wait(ep, events, 8, timeout);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    if (n == 0) {
      keys_timeout();
      continue;
    }

    for (int i = 0; i < n; i++) {
      int fd = events[i].data.fd;
      if (fd == tfd) {
        uint64_t ticks;
        ssize_t r = read(tfd, &ticks, sizeof ticks);
        (void)r;
        if (++tick % 6 == 0) {
          tailscale_start();
        }
        /* The key daemon restarts on its own schedule, so the panel keeps
         * trying rather than losing the keys until the next login. */
        if (sock_fd < 0 && cfg.socket_path[0]) {
          sock_fd = keys_connect();
          if (sock_fd >= 0) {
            ev.data.fd = sock_fd;
            epoll_ctl(ep, EPOLL_CTL_ADD, sock_fd, &ev);
          }
        }
        if (view == V_DASH) {
          repaint(0);
        } else if (view == V_PAGER && pager_reload) {
          pager_refresh();
          repaint(0);
        }
      } else if (fd == STDIN_FILENO) {
        stdin_readable();
      } else if (fd == keys_fd) {
        keys_readable();
      } else if (fd == sock_fd) {
        char tokens[16];
        ssize_t r = read(sock_fd, tokens, sizeof tokens);
        if (r <= 0) {
          epoll_ctl(ep, EPOLL_CTL_DEL, sock_fd, NULL);
          close(sock_fd);
          sock_fd = -1;
        } else {
          for (ssize_t k = 0; k < r; k++) {
            handle_char(tokens[k]);
          }
        }
      } else if (fd == ts_fd) {
        epoll_ctl(ep, EPOLL_CTL_DEL, ts_fd, NULL);
        registered_ts = -1;
        tailscale_drain();
      }
    }
  }

  term_restore();
  return 0;
}
