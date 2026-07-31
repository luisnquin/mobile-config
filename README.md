# Mobile NixOS — Xiaomi Redmi 9A (`dandelion`)

An in-progress [Mobile NixOS](https://mobile.nixos.org/) port for the Xiaomi
Redmi 9A / M2006C3LG, MediaTek MT6762G (Helio G25), on the downstream 4.9.190
vendor kernel.

**This is not a usable phone.** It is a stage-1 initramfs that boots, lights the
panel, prints a console, and serves key-authenticated SSH over the USB gadget.
There is no stage-2, no root filesystem, no touch, no graphical shell. Flashing
this replaces your recovery partition. Read [Safety](#safety) before building.

## Target

This port is written against one exact hardware/firmware tuple. A Redmi 9A that
differs in any of these is a different device for porting purposes.

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
| Touch, Wi-Fi, audio, modem, charging, suspend | **untested** |
| KMS / Wayland compositor | **impossible as-is**, see below |

`boot` has never been written on the development unit. Neither have `dtbo`,
`vbmeta`, `super`, `userdata`, `lk`, `preloader_*`, `seccfg`, `nvram`, `nvdata`,
or the partition table.

## Build

```sh
nix build github:<you>/mobile-nixos-dandelion#boot-img
```

Everything is pinned: the Mobile NixOS tree by flake input, its Nixpkgs by that
tree's own `npins`, and the kernel by revision and hash. The kernel is a full
downstream vendor tree; the first build fetches roughly 1.3 GB and compiles for
a while.

Other outputs:

```sh
nix build .#kernel             # the kernel derivation on its own
nix build .#fastboot-images    # what Mobile NixOS considers flashable
nix develop                    # adb, fastboot, dtc, python3
```

## Flash and connect

The image is written to **`recovery`**, deliberately. That keeps a working
Android `boot` on the device as the recovery route for every experiment.

```sh
adb shell 'reboot bootloader'     # `adb reboot bootloader` fails on this device
fastboot flash recovery result/boot.img
fastboot reboot recovery          # `fastboot oem reboot-recovery` is not a command here
```

Once it is up, the host sees an RNDIS interface and takes a lease from the
device's `udhcpd`:

```sh
ssh root@172.16.42.1              # device is .1, host is leased .2
adb shell                         # adb stays available alongside
```

Password authentication is refused outright — dropbear runs with `-s`, and the
stage-1 `/etc/passwd` locks the account. Put your key in
[`authorized-keys.nix`](authorized-keys.nix) before building; it is the one file
a fork must edit.

## Layout

```
flake.nix                     pinned inputs and the buildable outputs
authorized-keys.nix           who may SSH in as root
devices/xiaomi-dandelion/
  default.nix                 identity, boot image geometry, kernel cmdline, USB
  kernel/default.nix          source pin, toolchain, defconfig, build flags
  kernel/config.aarch64       normalized dandelion_halium_defconfig
modules/
  hardware-mediatek-mt6765.nix   kernel config that the MT6765 vendor stack needs
  systemd-linux-4.9.nix          systemd patched down to a 4.9 kernel
  stage2-build-fixes.nix         nixpkgs fixes needed to evaluate a full system
  display-mtk-fbdev.nix          wires in the display task below
  stage-1/tasks/dandelion-display-task.rb
  stage-1-ssh.nix                key-only dropbear over RNDIS
patches/
  mobile-nixos/                  applied to the Mobile NixOS tree
  systemd/                       applied to nixpkgs' systemd
  kernel/                        applied to the vendor kernel
```

Patch numbering is global and stable; the directory says which tree a patch
belongs to. Every patch header records the measurement that motivated it, not
just the change.

## Notable findings

### The panel was never broken

`mtkfb` implements neither `.fb_setcolreg` nor `.fb_setcmap`. `fb_set_cmap()`
returns `-EINVAL` early when both are absent, so `fbcon_set_palette()` is a
no-op and `pseudo_palette` stays as `framebuffer_alloc()` left it: all zeroes.
The generic blitters index that array directly (`cfbimgblt.c:290`,
`cfbfillrect.c:292`), so every console colour resolves to `0x00000000`. fbcon
ran correctly the whole time and drew black on black.

`patches/kernel/0006-mtkfb-implement-fb_setcolreg.patch` supplies the missing
28-line callback. The alpha channel matters: the overlay format is
`ARGB8888`/`BGRA8888` with `var.transp` 8 bits at offset 24, so a palette
written without opaque alpha produces a second, equally invisible render.

MediaTek appears to have inherited the omission by copy-paste from the OMAP
fbdev skeleton — the vestigial `.fb_setcolreg = NULL` is still sitting in the
unused `mtkfb1_ops` dual-display table.

### fbcon does not take over by itself

The boot log reports `Console: colour dummy device 80x25` and never the
`switching to colour frame buffer device 90x100` line that
`do_bind_con_driver()` prints. `dandelion-display-task.rb` forces an
unbind/rebind of the fbcon vtconsole to make `tty1` real.

### The backlight is a DSI command, and it lies

The panel's own init table leaves DCS `0x51` at `0x00`. Android's lights HAL
raises it; stage-1 has to. Two MediaTek behaviours then fight back:
`primary_display_setbacklight()` keeps a `static unsigned int last_level` and
early-returns when the value is unchanged, and the idle manager parks the DSI
link in ULPS. The task alternates between two adjacent brightness values and
pushes `idletime` to its clamped maximum.

### There is no KMS

`/sys/class/drm/card0` is `pvrsrvkm`, a PowerVR *render* node with zero
connectors. Display is fbdev-only through `mtkfb`. Phosh, Plasma Mobile, sway
and weston cannot run on this device as it stands.

A related trap: Mobile NixOS' `Tasks::Graphics` is satisfied by *either* FBDev
or DRM, and the PowerVR node resolves it about four seconds before the
framebuffer exists. Anything that needs a framebuffer must depend on
`Tasks::Graphics::FBDev` specifically.

### systemd 261 does not run on a 4.9 kernel

Four patches under `patches/systemd/` restore fallbacks for `STATX_MNT_ID`
(Linux 5.8), `pidfd_open()` (5.3), and `kobject_synth_uevent()` (4.13), plus the
`SIGCHLD` blocking that the pidfd path made implicit. Each was found by booting
and reading the failure. Expect more. The alternative is pinning Nixpkgs back to
a systemd old enough for this kernel, which trades a handful of local patches
for a very large downgrade across the whole system.

## Toolchain deviation

Droidian builds this tree with AOSP clang 6.0. This port uses GCC 13, the newest
release in Nixpkgs that still only *warns* on the implicit function declarations
a 2019 vendor tree is full of. `enableRemovingWerror` strips `-Werror=` out of
the makefiles, because a blanket `-Wno-error` does not cancel the specific
`-Werror=<name>` form GCC emits.

This is a real deviation and it is not proven harmless. A successful compile
with a different compiler is not ABI compatibility, and this port has not been
compared against a clang-built kernel.

## Safety

- Flash to `recovery` only. Keep stock Android on `boot` as the way back.
- Have the exact stock `V12.0.22.0.QCDMIXM` fastboot package and a hashed stock
  `recovery.img` before the first write.
- `recovery` on this device measures 67108864 bytes. Check the fit.
- Do not touch `preloader_*`, `lk`, `lk2`, `seccfg`, `nvram`, `nvdata`, `nvcfg`,
  `protect1`, `protect2`, `proinfo`, `persist`, or the partition table.
- A build is not a boot, and a boot is not an installation. One hardware
  revision proves nothing about another.

## Licence

The `patches/kernel/` and `patches/systemd/` contents are derivative works of
GPL-2.0 projects and carry those terms. The Nix expressions and the stage-1 Ruby
task are MIT, matching Mobile NixOS.
