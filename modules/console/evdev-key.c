/* Print a line per press of a key code on an evdev node.
 *
 * Read directly rather than through logind or triggerhappy: both wait on udev
 * to tag the input device, and this device's udev worker fails events with
 * EINVAL. The node itself comes from devtmpfs, with no udev involved.
 */
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <event-node> <key-code>\n", argv[0]);
    return 2;
  }

  int wanted = atoi(argv[2]);
  int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    perror(argv[1]);
    return 1;
  }

  for (;;) {
    struct input_event ev;
    ssize_t n = read(fd, &ev, sizeof ev);

    if (n == 0) {
      return 0;
    }
    if (n < 0) {
      perror("read");
      return 1;
    }
    if (n != (ssize_t)sizeof ev) {
      continue;
    }

    /* 1 is a press; 0 is release and 2 is autorepeat. */
    if (ev.type == EV_KEY && ev.code == wanted && ev.value == 1) {
      puts("press");
      fflush(stdout);
    }
  }
}
