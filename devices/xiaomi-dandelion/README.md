# Xiaomi Redmi 9A — `dandelion`

**This is not a usable phone.** It is a stage-1 initramfs that boots, lights the
panel, prints a console and serves key-authenticated SSH over the USB gadget.
There is no stage-2, no root filesystem, no touch, no graphical shell. Flashing
it replaces your recovery partition.

## Target

Written against one exact hardware/firmware tuple. A Redmi 9A differing in any
of these is a different device for porting purposes.

| | |
|---|---|
| Model / codename | `M2006C3LG` / `dandelion` (`dandelion_global`) |
| SoC | MT6762G, `ro.boot.hardware=mt6762` |
| Hardware revision | 1.39.0 |
| Panel | NT36525B, BOE "dijing", 720x1600 |
| Touch | `NVTCapacitiveTouchScreen` |
| Kernel | arm64 4.9.190 |
| Firmware built against | `V12.0.22.0.QCDMIXM`, Android 10, SPL 2023-02-01 |
| Verified boot | AVB 1.1, bootloader unlocked, orange state |
| Slots | non-A/B; separate `boot`, `recovery`, `dtbo`, `vbmeta`; dynamic `super` |

Droidian shipped and then **withdrew** dandelion builds after brick reports on
newer hardware revisions. That is an unresolved compatibility unknown, not
evidence that revision 1.39.0 is safe.

## Status

| Area | State |
|---|---|
| Kernel builds, arm64, header v2 image | works |
| Boots from `recovery`, reaches stage-1 init | works |
| Panel lit, backlight driven | works |
| Framebuffer console on `tty1`, readable text | works |
| USB gadget: adb + RNDIS concurrently | works |
| SSH as root over RNDIS, key only | works |
| Stage-2 / switch_root | **not started** — no rootfs is written yet |
| Stage-2 session config (TTY, sxmo) | **evaluates only** — never built, never booted |
| Tailscale daemon | **evaluates only** — kernel has TUN, but no network to enrol over |
| Touch, Wi-Fi, audio, modem, charging, suspend | **untested** |
| KMS / Wayland compositor | **impossible as-is**, see below |

`boot` has never been written on the development unit. Neither have `dtbo`,
`vbmeta`, `super`, `userdata`, `lk`, `preloader_*`, `seccfg`, `nvram`, `nvdata`,
or the partition table.

## Flash and connect

The image goes to **`recovery`**, deliberately, so a working Android `boot`
stays on the device as the way back from every experiment.

```sh
nix build .#xiaomi-dandelion-boot-img

adb shell 'reboot bootloader'     # `adb reboot bootloader` fails on this device
fastboot flash recovery result
fastboot reboot recovery          # `fastboot oem reboot-recovery` is not a command here
```

The host then sees an RNDIS interface and takes a lease from the device's
`udhcpd`:

```sh
ssh root@172.16.42.1              # device is .1, host is leased .2
adb shell                         # adb stays available alongside
```

Password authentication is refused outright: dropbear runs with `-s` and the
stage-1 `/etc/passwd` locks the account. Put your key in
[`../../authorized-keys.nix`](../../authorized-keys.nix) before building.

`recovery` on this device measures 67108864 bytes. Check the fit before writing,
and have the exact stock `V12.0.22.0.QCDMIXM` package and a hashed stock
`recovery.img` on hand first.

## Findings

### The panel was never broken

`mtkfb` implements neither `.fb_setcolreg` nor `.fb_setcmap`. `fb_set_cmap()`
returns `-EINVAL` early when both are absent, so `fbcon_set_palette()` is a
no-op and `pseudo_palette` stays as `framebuffer_alloc()` left it: all zeroes.
The generic blitters index that array directly (`cfbimgblt.c:290`,
`cfbfillrect.c:292`), so every console colour resolves to `0x00000000`. fbcon
ran correctly the whole time and drew black on black.

`patches/linux/mt6765/0006-mtkfb-implement-fb_setcolreg.patch` supplies the
missing 28-line callback. Alpha matters: the overlay format is
`ARGB8888`/`BGRA8888` with `var.transp` 8 bits at offset 24, so a palette
written without opaque alpha produces a second, equally invisible render.

MediaTek appears to have inherited the omission by copy-paste from the OMAP
fbdev skeleton — the vestigial `.fb_setcolreg = NULL` is still sitting in the
unused `mtkfb1_ops` dual-display table.

### fbcon does not take over by itself

The boot log reports `Console: colour dummy device 80x25` and never the
`switching to colour frame buffer device 90x100` line that
`do_bind_con_driver()` prints. `stage-1/display-task.rb` forces an
unbind/rebind of the fbcon vtconsole to make `tty1` real.

### The backlight is a DSI command, and it lies

The panel's init table leaves DCS `0x51` at `0x00`; Android's lights HAL raises
it, so stage-1 has to. Two MediaTek behaviours then fight back:
`primary_display_setbacklight()` keeps a `static unsigned int last_level` and
early-returns when the value is unchanged, and the idle manager parks the DSI
link in ULPS. The task alternates between two adjacent brightness values and
pushes `idletime` to its clamped maximum.

### There is no KMS

`/sys/class/drm/card0` is `pvrsrvkm`, a PowerVR *render* node with zero
connectors. Display is fbdev-only through `mtkfb`. Phosh, Plasma Mobile, sway
and weston cannot run on this device as it stands.

Related trap: Mobile NixOS' `Tasks::Graphics` is satisfied by *either* FBDev or
DRM, and the PowerVR node resolves it about four seconds before the framebuffer
exists. Anything needing a framebuffer must depend on `Tasks::Graphics::FBDev`.

### The session: TTY by default, sxmo on request

Stage-2 has two modes, both booting to `multi-user.target` with a getty
autologin as `mobile`:

1. **tty-only** (default). A shell on `tty1`. Nothing graphical starts.
2. **sxmo**. `sxmo_xinit.sh` from that shell, or set
   `mobile.session.graphical.autostart = true` to `exec` it from `tty1`'s login
   shell at boot.

sxmo — not swmo. swmo is sway, sway needs KMS, and there is none here (above).
`services.xserver.videoDrivers = [ "fbdev" ]` is the only Xorg driver that does
not need one. That driver writes into the mmap'd framebuffer and never issues
`FBIOPAN_DISPLAY`, which is the exact failure fbcon had, so it depends on
`mobile.quirks.fb-refresher`. Untested.

sxmo is a touch UI and touch has never been exercised on this device. There is
also no `dandelion` device profile in sxmo-utils, so its hooks, button bindings
and screen geometry are unconfigured.

Packages come from [`wentam/sxmo-nix`](https://github.com/wentam/sxmo-nix), a
tree last touched in 2022. Only the six it uniquely carries are built from it
(`sxmo-utils`, `sxmo-dwm`, `sxmo-st`, `sxmo-dmenu`, `vvmd`,
`codemadness-frontends`); `mmsd-tng`, `superd`, `mnc` and `wayout` come from
Nixpkgs, which has newer ones. Its NixOS modules are not imported at all — they
target option paths Nixpkgs renamed years ago, and their display-manager half
exists to toggle dwm against sway. See `modules/sxmo.nix`.

### Tailscale has a real TUN device

Read off the running kernel: `CONFIG_TUN=y`, and `/dev/net/tun` exists as
`crw------- 10, 200`. `CONFIG_NF_TABLES` and `CONFIG_IP_NF_IPTABLES` are set
too, which is what `tailscaled` needs for its own rules. So the daemon gets a
`tailscale0` interface rather than falling back to `--tun=userspace-networking`,
which would leave the device able to reach the tailnet but not be reached from
it.

No auth key is committed. The node is enrolled once by hand with `doas tailscale
up`; state then lives in `/var/lib/tailscale`. Nothing can be enrolled yet —
Wi-Fi is untested and the RNDIS link only reaches the build host, so `tailscaled`
will sit in `NeedsLogin`.

### systemd 261 does not run on a 4.9 kernel

Four patches under `patches/systemd/` restore fallbacks for `STATX_MNT_ID`
(Linux 5.8), `pidfd_open()` (5.3) and `kobject_synth_uevent()` (4.13), plus the
`SIGCHLD` blocking the pidfd path made implicit. Each was found by booting and
reading the failure. Expect more. The alternative is pinning Nixpkgs back to a
systemd old enough for this kernel, which trades a handful of local patches for
a very large downgrade across the whole system.

## Toolchain deviation

Droidian builds this tree with AOSP clang 6.0. This port uses GCC 13, the newest
release in Nixpkgs that still only *warns* on the implicit function declarations
a 2019 vendor tree is full of. `enableRemovingWerror` strips `-Werror=` out of
the makefiles, because a blanket `-Wno-error` does not cancel the specific
`-Werror=<name>` form GCC emits.

This is a real deviation and it is not proven harmless. A successful compile
with a different compiler is not ABI compatibility, and this port has not been
compared against a clang-built kernel.
