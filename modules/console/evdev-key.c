/* Report clicks and holds of selected key codes on an evdev node.
 *
 * Read directly rather than through logind or triggerhappy: both wait on udev
 * to tag the input device, and this device's udev worker fails events with
 * EINVAL. The node itself comes from devtmpfs, with no udev involved.
 *
 * A hold is announced the moment the threshold passes, not on release, so the
 * panel can react while the key is still down.
 *
 * A code suffixed `:r` repeats instead: it clicks on the press, again once the
 * hold threshold passes, and then every repeat interval until release. mtk-kpd
 * advertises EV_SYN and EV_KEY only, so nothing else produces a repeat here.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MAX_KEYS 8

static long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int main(int argc, char **argv) {
  if (argc < 5 || argc > 4 + MAX_KEYS) {
    fprintf(stderr,
            "usage: %s <event-node> <hold-ms> <repeat-ms> <key-code[:r]>...\n",
            argv[0]);
    return 2;
  }

  long hold_ms = atol(argv[2]);
  long repeat_ms = atol(argv[3]);
  int codes[MAX_KEYS];
  int repeats[MAX_KEYS];
  int ncodes = argc - 4;
  for (int i = 0; i < ncodes; i++) {
    const char *spec = argv[4 + i];
    codes[i] = atoi(spec);
    repeats[i] = strchr(spec, ':') != NULL;
  }

  int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    perror(argv[1]);
    return 1;
  }

  /* The console keyboard handler shares this device and maps these codes to
   * F-keys, so without a grab every press also reaches tty1 as an escape
   * sequence. The kernel drops the grab when fd closes. */
  if (ioctl(fd, EVIOCGRAB, 1) < 0) {
    perror("EVIOCGRAB");
  }

  int held = -1;
  int held_repeats = 0;
  long due = 0;
  int pending = 0;
  int announced = 0;

  for (;;) {
    int timeout = -1;
    if (held >= 0 && pending) {
      timeout = (int)(due - now_ms());
      if (timeout < 0) {
        timeout = 0;
      }
    }

    struct pollfd p = {.fd = fd, .events = POLLIN};
    int n = poll(&p, 1, timeout);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      perror("poll");
      return 1;
    }

    if (n == 0) {
      if (held_repeats) {
        printf("click %d\n", held);
        due = now_ms() + repeat_ms;
      } else {
        printf("hold %d\n", held);
        announced = 1;
        pending = 0;
      }
      fflush(stdout);
      continue;
    }

    struct input_event ev;
    ssize_t r = read(fd, &ev, sizeof ev);
    if (r == 0) {
      return 0;
    }
    if (r < 0) {
      if (errno == EINTR) {
        continue;
      }
      perror("read");
      return 1;
    }
    if (r != (ssize_t)sizeof ev || ev.type != EV_KEY) {
      continue;
    }

    int idx = -1;
    for (int i = 0; i < ncodes; i++) {
      if (codes[i] == ev.code) {
        idx = i;
      }
    }
    if (idx < 0) {
      continue;
    }

    /* 1 is a press and 0 a release; 2 is kernel autorepeat, ignored so it
     * cannot double the synthesized one. */
    if (ev.value == 1) {
      held = ev.code;
      held_repeats = repeats[idx];
      announced = 0;
      pending = 1;
      due = now_ms() + hold_ms;
      if (held_repeats) {
        printf("click %d\n", held);
        fflush(stdout);
      }
    } else if (ev.value == 0 && ev.code == held) {
      if (!held_repeats && !announced) {
        printf("click %d\n", held);
        fflush(stdout);
      }
      held = -1;
      pending = 0;
    }
  }
}
