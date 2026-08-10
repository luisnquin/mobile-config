// Userspace half of the mt6765 connectivity bring-up. Two jobs Android splits
// between /vendor/bin/wmt_loader and /vendor/bin/wmt_launcher:
//
//   1. the ioctl sequence on /dev/wmtdetect that runs the built-in sub-driver
//      inits, and the power-on write on /dev/wmtWifi they expose;
//   2. the request/response service on /dev/stpwmt that the WMT core uses to
//      ask userspace where the firmware patches are.
//
// Neither ordering is negotiable; see ./default.nix for why.

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define WMT_DETECT_IOC_MAGIC 'w'
#define COMBO_IOCTL_SET_CHIP_ID _IOW(WMT_DETECT_IOC_MAGIC, 1, int)
#define COMBO_IOCTL_GET_SOC_CHIP_ID _IOR(WMT_DETECT_IOC_MAGIC, 3, int)
#define COMBO_IOCTL_DO_MODULE_INIT _IOR(WMT_DETECT_IOC_MAGIC, 4, int)
#define COMBO_IOCTL_MODULE_CLEANUP _IOR(WMT_DETECT_IOC_MAGIC, 5, int)

#define WMT_IOC_MAGIC 0xa0
#define WMT_IOCTL_SET_STP_MODE _IOW(WMT_IOC_MAGIC, 5, int)
#define WMT_IOCTL_SET_PATCH_NUM _IOW(WMT_IOC_MAGIC, 14, int)
#define WMT_IOCTL_SET_PATCH_INFO _IOW(WMT_IOC_MAGIC, 15, char *)
#define WMT_IOCTL_SET_ROM_PATCH_INFO _IOW(WMT_IOC_MAGIC, 31, char *)

// wmt_lib_set_hif() packs the transport in the low nibble and the FM routing in
// the next one. mt6765 talks to the combo chip over BTIF; leaving this unset
// means hifType keeps its zero value, WMT_HIF_UART, and stp open later drives a
// UART that does not exist.
#define STP_BTIF_FULL 0x03
#define WMT_FM_COMM 0x02
#define STP_MODE (STP_BTIF_FULL | (WMT_FM_COMM << 4))

#define DETECT_NODE "/dev/wmtdetect"
#define WIFI_NODE "/dev/wmtWifi"
#define WMT_NODE "/dev/stpwmt"

#define DEFAULT_FIRMWARE_DIR "/run/current-system/firmware"

// device_create() lands in devtmpfs before the ioctl returns, but a failed
// sub-init leaves the node absent for good.
#define NODE_TIMEOUT_S 10

// struct wmt_rom_patch is 48 bytes -- ucDateTime[16], ucPLat[4], u2HwVer,
// u2SwVer, u4PatchAddr, u4PatchType, u4CRC[4] -- but only the two words at 24
// and 28 matter here: the load address the chip wants and the driver type the
// body belongs to. Reading 32 bytes covers both; the trailing CRC is the
// kernel's business, not ours.
//
// u4PatchAddr is a CONNSYS-view address (0xf0000011 for mcu, 0xf0080011 for bt,
// 0xf0140011 for wifi), which the driver masks to 24 bits and adds to the EMI
// base. The odd 0x11 offset is genuine, not a misparse.
#define PATCH_HDR_LEN 32
#define PATCH_HDR_ADDR_OFF 24
#define PATCH_HDR_TYPE_OFF 28

#define MAX_PATCH_NUM 10

// WMT_PATCH_INFO, the ioctl argument for the non-ROM patch path.
struct patch_info {
  uint32_t download_seq;
  uint8_t address[4];
  uint8_t name[256];
};

// struct wmt_rom_patch_info.
struct rom_patch_info {
  uint32_t type;
  uint8_t address[4];
  uint8_t name[256];
};

static const char *firmware_dir = DEFAULT_FIRMWARE_DIR;

static int wait_for_node(const char *path) {
  struct timespec tick = {.tv_sec = 0, .tv_nsec = 100 * 1000 * 1000};

  for (int i = 0; i < NODE_TIMEOUT_S * 10; i++) {
    if (access(path, F_OK) == 0) return 0;
    nanosleep(&tick, NULL);
  }

  return -1;
}

// The header stores the type big-endian while the address is consumed byte by
// byte, so it is copied verbatim.
static int read_patch_header(const char *name, uint8_t address[4], uint32_t *type) {
  char path[PATH_MAX];
  uint8_t hdr[PATCH_HDR_LEN];

  snprintf(path, sizeof(path), "%s/%s", firmware_dir, name);

  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s: %s\n", path, strerror(errno));
    return -1;
  }

  ssize_t got = read(fd, hdr, sizeof(hdr));
  close(fd);

  if (got != (ssize_t)sizeof(hdr)) {
    fprintf(stderr, "%s: short header\n", path);
    return -1;
  }

  memcpy(address, hdr + PATCH_HDR_ADDR_OFF, 4);

  if (type != NULL) {
    *type = ((uint32_t)hdr[PATCH_HDR_TYPE_OFF] << 24) |
            ((uint32_t)hdr[PATCH_HDR_TYPE_OFF + 1] << 16) |
            ((uint32_t)hdr[PATCH_HDR_TYPE_OFF + 2] << 8) |
            (uint32_t)hdr[PATCH_HDR_TYPE_OFF + 3];
  }

  return 0;
}

// Both patch families are named soc<n>_<n>_<kind>_<ip>_<fw>_hdr.bin, with the
// kind fixed and the versions tracking the chip. Matching on the affixes keeps
// this working across firmware revisions instead of pinning 1_1.
static int collect(const char *infix, char names[][NAME_MAX + 1], int max) {
  DIR *dir = opendir(firmware_dir);
  if (dir == NULL) {
    fprintf(stderr, "opendir %s: %s\n", firmware_dir, strerror(errno));
    return -1;
  }

  int found = 0;
  struct dirent *entry;

  while (found < max && (entry = readdir(dir)) != NULL) {
    size_t len = strlen(entry->d_name);

    if (len > NAME_MAX) continue;
    if (strncmp(entry->d_name, "soc", 3) != 0) continue;
    if (strstr(entry->d_name, infix) == NULL) continue;
    if (len < 8 || strcmp(entry->d_name + len - 8, "_hdr.bin") != 0) continue;

    strcpy(names[found++], entry->d_name);
  }

  closedir(dir);
  return found;
}

static int handle_rom_patch(int fd) {
  char names[MAX_PATCH_NUM][NAME_MAX + 1];
  int count = collect("_ram_", names, MAX_PATCH_NUM);

  if (count <= 0) {
    fprintf(stderr, "no ROM patches in %s\n", firmware_dir);
    return -1;
  }

  for (int i = 0; i < count; i++) {
    struct rom_patch_info info = {0};

    if (read_patch_header(names[i], info.address, &info.type) < 0) return -1;

    memcpy(info.name, names[i], strlen(names[i]) + 1);

    if (ioctl(fd, WMT_IOCTL_SET_ROM_PATCH_INFO, &info) < 0) {
      fprintf(stderr, "SET_ROM_PATCH_INFO %s: %s\n", names[i], strerror(errno));
      return -1;
    }

    printf("rom patch %s type %u addr %02x%02x%02x%02x\n", names[i], info.type,
           info.address[3], info.address[2], info.address[1], info.address[0]);
  }

  return 0;
}

static int handle_patch(int fd) {
  static int announced;

  char names[MAX_PATCH_NUM][NAME_MAX + 1];
  int count = collect("_patch_", names, MAX_PATCH_NUM);

  if (count <= 0) {
    fprintf(stderr, "no patches in %s\n", firmware_dir);
    return -1;
  }

  // SET_PATCH_NUM allocates the kernel-side table once and rejects a second
  // call outright, so a re-search must reuse the count from the first.
  if (!announced) {
    if (ioctl(fd, WMT_IOCTL_SET_PATCH_NUM, count) < 0) {
      fprintf(stderr, "SET_PATCH_NUM: %s\n", strerror(errno));
      return -1;
    }
    announced = 1;
  }

  for (int i = 0; i < count; i++) {
    struct patch_info info = {0};

    info.download_seq = i + 1;
    if (read_patch_header(names[i], info.address, NULL) < 0) return -1;

    memcpy(info.name, names[i], strlen(names[i]) + 1);

    if (ioctl(fd, WMT_IOCTL_SET_PATCH_INFO, &info) < 0) {
      fprintf(stderr, "SET_PATCH_INFO %s: %s\n", names[i], strerror(errno));
      return -1;
    }

    printf("patch %d/%d %s\n", info.download_seq, count, names[i]);
  }

  return 0;
}

static int handle_command(int fd, const char *cmd) {
  if (strcmp(cmd, "srh_rom_patch") == 0) return handle_rom_patch(fd);
  if (strcmp(cmd, "srh_patch") == 0) return handle_patch(fd);

  // update_patch_version only feeds the vendor patch version readback, and
  // open_stp/close_stp are the UART transport's business. Acknowledging is the
  // whole contract; the alternative is a 6 s stall per request.
  if (strcmp(cmd, "update_patch_version") == 0) return 0;
  if (strcmp(cmd, "open_stp") == 0 || strcmp(cmd, "close_stp") == 0) return 0;

  fprintf(stderr, "unhandled command %s\n", cmd);
  return -1;
}

static int power_on(void) {
  if (wait_for_node(WIFI_NODE) < 0) {
    fprintf(stderr, "%s did not appear\n", WIFI_NODE);
    return -1;
  }

  int fd = open(WIFI_NODE, O_WRONLY | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s: %s\n", WIFI_NODE, strerror(errno));
    return -1;
  }

  ssize_t written = write(fd, "1", 1);
  close(fd);

  if (written != 1) {
    fprintf(stderr, "power on: %s\n", strerror(errno));
    return -1;
  }

  return 0;
}

static int detect(void) {
  int fd = open(DETECT_NODE, O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s: %s\n", DETECT_NODE, strerror(errno));
    return -1;
  }

  int chip_id = ioctl(fd, COMBO_IOCTL_GET_SOC_CHIP_ID);
  if (chip_id <= 0) {
    fprintf(stderr, "GET_SOC_CHIP_ID: %s\n", strerror(errno));
    close(fd);
    return -1;
  }
  printf("chip id 0x%04x\n", chip_id);

  int ok = ioctl(fd, COMBO_IOCTL_SET_CHIP_ID, chip_id) == 0 &&
           ioctl(fd, COMBO_IOCTL_MODULE_CLEANUP) == 0 &&
           ioctl(fd, COMBO_IOCTL_DO_MODULE_INIT, chip_id) == 0;
  if (!ok) {
    fprintf(stderr, "wmtdetect init: %s\n", strerror(errno));
    close(fd);
    return -1;
  }

  close(fd);
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1) firmware_dir = argv[1];

  setvbuf(stdout, NULL, _IOLBF, 0);

  if (detect() < 0) return 1;

  if (wait_for_node(WMT_NODE) < 0) {
    fprintf(stderr, "%s did not appear\n", WMT_NODE);
    return 1;
  }

  int fd = open(WMT_NODE, O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s: %s\n", WMT_NODE, strerror(errno));
    return 1;
  }

  // Reports "hif_info had been set!" and succeeds on a restart, so this stays
  // unconditional.
  if (ioctl(fd, WMT_IOCTL_SET_STP_MODE, STP_MODE) < 0) {
    fprintf(stderr, "SET_STP_MODE: %s\n", strerror(errno));
    return 1;
  }

  // The write below blocks in the kernel for as long as the core is waiting on
  // an answer from this very program, so it cannot happen on this thread.
  pid_t child = fork();
  if (child < 0) {
    fprintf(stderr, "fork: %s\n", strerror(errno));
    return 1;
  }
  if (child == 0) {
    close(fd);
    return power_on() < 0 ? 1 : 0;
  }

  for (;;) {
    struct pollfd pfd = {.fd = fd, .events = POLLIN};

    // WMT_poll() always reports writable, so only POLLIN is armed. The timeout
    // is what lets the power-on child be reaped.
    if (poll(&pfd, 1, 200) < 0) {
      if (errno == EINTR) continue;
      fprintf(stderr, "poll: %s\n", strerror(errno));
      return 1;
    }

    if (pfd.revents & POLLIN) {
      char cmd[NAME_MAX + 1] = {0};
      ssize_t got = read(fd, cmd, sizeof(cmd) - 1);

      if (got > 0) {
        cmd[got] = '\0';
        printf("command %s\n", cmd);

        const char *reply = handle_command(fd, cmd) == 0 ? "ok" : "fail";
        if (write(fd, reply, strlen(reply)) < 0)
          fprintf(stderr, "reply %s: %s\n", reply, strerror(errno));
      }
    }

    if (child > 0) {
      int status;

      if (waitpid(child, &status, WNOHANG) == child) {
        child = -1;

        // Exiting here would take the /dev/stpwmt service down with it and
        // leave the next power-on attempt -- a write to /dev/wmtWifi, which
        // the chip accepts again after a failure -- with nobody to answer
        // srh_rom_patch. The module init behind us is the part that cannot be
        // repeated; this one can, so stay up for it.
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
          fprintf(stderr, "power on failed, serving %s anyway\n", WMT_NODE);
        else
          printf("wlan powered on\n");
      }
    }
  }
}
