# Xiaomi Redmi 9A — `dandelion`

**This is not a usable phone.** Stage-1 boots, lights the panel, prints a console
and serves key-authenticated SSH over the USB gadget. A root filesystem is
written and hash-verified, and `switch_root` happens — but systemd has never
reached a service manager, so there is no session, no touch and no graphical
shell. Flashing it replaces your recovery partition.

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
| Stage-2 rootfs written to `userdata` | written and hash-verified, see below |
| Stage-2 / switch_root | works — `is-system-running` reports `running`, no failed units |
| TTY session on `tty1` | works |
| sxmo | builds, off by default — costs 1.6 GiB of closure, see `mobile.session.sxmo` |
| Activating a new generation without a reflash | works — `nix run .#dandelion-switch`, guarded |
| Bounded journal and store growth | works — `mobile.services.maintenance` |
| Tailscale daemon | enrolled as `thompson`, rules install, reachable — but rides the cable, see below |
| Wi-Fi | **no driver** — the defconfig never builds one, `nmcli` reports `WIFI-HW missing` |
| Touch, audio, modem, suspend | **untested** |
| Charging | charges from a wall charger; net-drains on a PC port |
| KMS / Wayland compositor | **impossible as-is**, see below |

`boot` has never been written on the development unit. Neither have `dtbo`,
`vbmeta`, `super`, `lk`, `preloader_*`, `seccfg`, `nvram`, `nvdata`, or the
partition table. `userdata` and `para` have: see "Where the rootfs lives" below.

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

## Working on the port

Once the device boots to stage-2 and answers over ssh, changing its
configuration does not need the latch, an image, or a reboot:

```sh
nix run .#dandelion-switch
```

That builds, copies and activates, and then holds the change to account: it arms
the deadman switch in [`../../modules/deploy-guard.nix`](../../modules/deploy-guard.nix)
first, and only confirms once the device answers ssh again as the new
generation. A switch that breaks rndis0 is never confirmed, so the device rolls
itself back after five minutes instead of waiting for someone to walk over to it
with a cable. It also refuses to run when `config.systemd.package` differs from
what PID 1 is already running: `switch` runs `daemon-reexec`, and re-execing PID
1 across two systemd builds hangs in `manager_new()`. Flash an image and reboot
for those.

The plain form still works and is still guarded — the guard arms itself from the
activation script — but nothing confirms it, so the deploy has five minutes to
be confirmed by hand with `ssh dandelion deploy-guard confirm`:

```sh
nixos-rebuild switch --flake .#xiaomi-dandelion --target-host dandelion
```

nyx builds it (cross, from `binfmt`'s `aarch64-linux`) and copies the store
delta over the gadget — around 100 MiB for a one-module change, against 2.2 GiB
for an image. `boot` instead of `switch` stages the generation for the next boot
without touching the running one; the "do not know how to make this
configuration bootable" warning is expected, because stage-1 picks the
generation out of `/nix/var/nix/profiles/system` and the boot image is flashed
separately. Rollback by hand is `nix-env -p /nix/var/nix/profiles/system
--rollback` on the device.

Reflash `recovery` only when the kernel, the initrd or the cmdline changed —
`boot.img` is byte-identical across changes that touch only stage-2. Write a
full image only to install onto a blank partition or to recover one.

Everything that touches the device from stage-1 is a flake app. Each one refuses to run
unless `HADAHAORHAV8YHB6` appears in the device's `/proc/cmdline`, checked before
every destructive step rather than once at startup, because the device drops off
the bus and returns between steps routinely.

```sh
nix run .#dandelion-latch        # then power-cycle: parks the device in stage-1
nix run .#dandelion-log          # read the bring-up log, no mount needed
nix run .#dandelion-deploy -- result-dandelion/system.img
nix run .#dandelion-verify -- result-dandelion/system.img
nix run .#dandelion-flash-bootimg -- result-dandelion/boot.img   # targets recovery
nix run .#dandelion-unlatch      # let the next boot proceed to stage-2
nix run .#dandelion-resize-rootfs   # grow to the block below the log ring
nix run .#dandelion-reboot       # sysrq; `adb reboot` fails in stage-1
```

`dandelion-resize-rootfs` runs after `dandelion-unlatch`, not before: it needs a
readable superblock, and unlatching only decides what the *next* boot does, so
the stage-1 session it runs in survives it. Order matters the other way too —
the image is deliberately narrower than the partition, so a deploy undoes the
resize and it has to be redone afterwards.

`dandelion-latch` is the one that makes the rest possible. A normal boot exposes
adb for about sixteen seconds before stage-2 tears the gadget down, which is not
enough time to do anything. Zeroing the ext4 superblock magic at byte 1080 makes
stage-1 fail to mount root and fall into its `shellOnFail` shell, which blocks on
`/dev/console` forever — so adbd stays up indefinitely. `dandelion-deploy`
re-arms that latch for the duration of a write and restores it last, by writing
chunk 0 after every other chunk: an interrupted write then re-parks the device
instead of handing stage-1 a valid superblock over a half-written filesystem.

Build outputs must use `--out-link`. `nix build --no-link --print-out-paths`
creates no GC root, and a `nix-gc` run has already deleted a finished 3 GB image
mid-session.

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
autologin as `mobile`. The only difference in the entire system is one guard in
`environment.loginShellInit`:

1. **tty-only**. A shell on `tty1`. Nothing graphical starts.
2. **sxmo**. `tty1`'s login shell runs `sxmo_xinit.sh`.

This device selects mode 2 (`mobile.session.graphical.autostart = true`), unlike
the module default, because it has no keyboard: mode 1 assumes someone can type
on the panel, and the only USB port is taken by the gadget carrying adb and ssh,
so an OTG keyboard would cost the session its own lifeline.

Switching back does not need a keyboard either. sxmo's own menu grows a **"TTY
mode (leave sxmo)"** entry under Scripts, which sets the flag below and kills
dwm. It is shipped as a package with a `share/sxmo/appscripts/` entry rather than
a dotfile, because `environment.pathsToLink = [ "/share" ]` merges that directory
across packages and `sxmo_hook_scripts.sh` reads whatever it finds there.

sxmo's built-in `sxmo_power.sh logout` is not that entry and does not work here:
it chooses how to end the session by reading
`/var/lib/tinydm/default-session.desktop`, and this device has no display
manager, so neither of its branches matches and the call is a no-op.

The login hook deliberately does not `exec` —
replacing the login shell would leave nothing to return to, so quitting sxmo, or
X failing to start at all, would end the shell, getty would respawn it, autologin
would fire and the session would restart forever. Falling through to the shell
makes "quit" mean tty until the next login. For something that survives a reboot:

```sh
session-mode tty       # plain shell from the next login on
session-mode gui       # back to sxmo
session-mode status    # -> tty | gui
```

That toggles `mobile.session.graphical.overrideFlag`
(`/var/lib/mobile-session/tty-only`), whose directory is owned by the session
user on purpose — needing `doas` to leave a graphical session means typing a
password on the on-screen keyboard being escaped.

The `tty1` test in the guard is what keeps ssh on a plain shell in both modes, so
enabling the GUI can never cost the remote shell.

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

### Where the rootfs lives, and how to get back

There is no `misc` partition on this GPT. MediaTek's LK reads the Android boot
control block out of **`para` (`mmcblk0p3`)** instead, and it honours it: `para`
was found already holding `bootonce-bootloader`. Writing the 32-byte command
`boot-recovery` at offset 0 is therefore how stage-1 is re-entered without a
key combination, and — because nothing in this port clears it — how the device
keeps coming back to stage-1 after every reset. Back `para` up before writing
it. That property is the whole safety net here: `boot` (`p33`) still holds stock
Android and has never been touched.

The rootfs goes to **`userdata` (`mmcblk0p41`, 24 353 160 704 bytes)**, streamed
over `adb exec-out`/SSH with `dd`, not fastboot. It is outside AVB, so nothing
about `vbmeta` or rollback changes.

`switch_root` drops USB, and that is expected rather than a fault:
`boot.postBootCommands` in mobile-nixos' `modules/adb.nix` pkills `adbd` before
`exec`ing systemd, which tears down the functionfs backing `ffs.adb` and unbinds
the UDC. `modules/adb.nix` re-enables the gadget from
`systemd.services.adbd` — but that unit is `wantedBy = multi-user.target`. So
**USB returning is a signal that stage-2 reached `multi-user.target`, and USB
staying dark says nothing more precise than "it did not"**. The same is true of
the network: `modules/usb-network.nix` replaces the stage-1 `ifconfig` + `udhcpd`
pair, and it is equally late.

On the development unit the host bus saw exactly one enumeration after the
reboot — stage-1, thirteen seconds, then disconnect — and nothing since. One
enumeration means no reboot loop and no watchdog reset: the kernel is alive and
stage-2 is stuck somewhere ahead of `multi-user.target`. Which is unsurprising,
because systemd has never actually run as PID 1 on this device; stage-1 is mruby,
and the only part of systemd exercised so far is udev.

### Reading a stage-2 that never came back

The panel carries `console=tty1` and is the only live channel. Three mechanisms
were added for this, in the order they were tried, and the first two are
documented here because their failure is what motivates the third:

- `systemd.log_target=kmsg` puts PID 1's log in the kernel ring buffer.
  `CONFIG_MTK_RAM_CONSOLE`, `CONFIG_PSTORE_RAM` and `CONFIG_PSTORE_CONSOLE` are
  all set, which should make that buffer survive a reset. **It does not on this
  SoC.** After a power cut, `/proc/last_kmsg` and `/sys/fs/pstore` are both
  empty. Setting the config symbols was not sufficient.
- `services.journald.storage = "persistent"` puts the journal on the rootfs.
  Useless for the failure actually being chased: PID 1 freezes in
  `mount_setup()`, long before journald is started, so there is no journal.
- `modules/bringup-log` writes the kernel ring buffer to a **raw offset inside
  `mmcblk0p41`, past the end of its filesystem**, every two seconds, in two
  alternating 64 MiB slots. Nothing about reading it depends on systemd, on
  journald, on adb surviving, or on the partition being mountable — which
  matters more than it sounds, because the only way to hold this device still
  long enough to read anything is to zero its ext4 superblock magic, and that is
  precisely the state in which no file on it can be opened.

  `nix run .#dandelion-log > stage2.log`. The offsets live in
  `modules/bringup-log/layout.nix`, imported by both the writer and the reader.
  Growing the rootfs past 16 GiB would overwrite the log.

A userspace loop writing to `/dev/console` never enters the kernel ring buffer,
so none of the above can see one. That class of bug is found by photographing
the panel, and one was: see `stage-1/display-task.rb`.

### The tailnet, and how much of a second channel it really is

Read off the running kernel: `CONFIG_TUN=y`, and `/dev/net/tun` exists as
`crw------- 10, 200`. `CONFIG_NF_TABLES` and `CONFIG_IP_NF_IPTABLES` are set
too, which is what `tailscaled` needs for its own rules. So the daemon gets a
`tailscale0` interface rather than falling back to `--tun=userspace-networking`,
which would leave the device able to reach the tailnet but not be reached from
it.

What it does not have is `CONFIG_IP_NF_MATCH_RPFILTER` — only the IPv6 variant
is built — and `net.ipv4.conf.*.rp_filter` reads 0. That rules out
`services.tailscale.useRoutingFeatures = "client"`, which exists solely to set
`networking.firewall.checkReversePath = "loose"`; NixOS asserts on it, and there
is no reverse-path filtering here to loosen anyway. Exit nodes and subnet routes
would need that config symbol added and the kernel rebuilt.

No auth key is committed. The node is enrolled once by hand with `doas tailscale
up`; state then lives in `/var/lib/tailscale`. It is enrolled, as `thompson`,
`100.80.122.40`.

Enrolling exposed a second backend problem, in the opposite direction from the
one above. `networking.firewall.package` decides what *NixOS* runs, and this port
already points it at `iptables-legacy`; `tailscaled` runs its own. nixpkgs wraps
the daemon with `--prefix PATH` over its own closure, and a prefix beats anything
`systemd.services.tailscaled.path` appends — so the daemon reached for the
nft-backed binary, every rule insert failed with `RULE_INSERT failed (No such
file or directory)`, and `iptables -S | grep -c ts-` was 0. The node was up,
enrolled, and answered nothing: no `ts-input` chain, no rule to accept an inbound
connection. The fix has to go inside the package —
`pkgs.tailscale.override { iptables = pkgs.iptables-legacy; }` — and `iptables`
being a named argument of that derivation is the only reason it is one line. With
it, 13 filter rules and 3 nat rules install, and `tailscale status` prints no
health block.

What this does **not** yet buy is a channel independent of the cable. The device
has no Wi-Fi driver (see below), so its only route to the internet is the HTTP
CONNECT tunnel on the build host, and `tailscale ping` from that host answers
`via 172.16.42.1:41641` — the RNDIS link. The tailnet is a genuine second channel
for every *other* peer, and it survives sshd or the firewall being reconfigured
in a way the cable would not, but the phone still depends on the build host being
plugged into it. Wi-Fi is what closes that gap.

One host-side gotcha, not a device fault. `Host dandelion` in `~/.ssh/config`
pins `IdentityFile`, and its `ControlMaster` keeps a session authenticated for
ten minutes, so the cable never re-signs. The tailnet address matches no `Host`
block, so every connection re-signs through `gpg-agent`, which refuses under
`BatchMode` because it cannot open a pinentry — the connection hangs at
`Server accepts key` and then dies with `agent refused operation`. Give the
tailnet address its own `Host` block with the same `IdentityFile`,
`IdentitiesOnly yes` and `IdentityAgent none`, and it behaves like the cable.

The deploy tool takes the destination from the environment, so once that block
exists nothing else changes:

    HOST=thompson-ts nix run .#dandelion-switch

### systemd 261 does not run on a 4.9 kernel

Five patches under `patches/systemd/` restore fallbacks for `STATX_MNT_ID`
(Linux 5.8), `pidfd_open()` (5.3) and `kobject_synth_uevent()` (4.13), the
`SIGCHLD` blocking the pidfd path made implicit, and — the only one from full
systemd as PID 1 — `statx()` itself (4.11) together with `STATX_ATTR_MOUNT_ROOT`
(5.8). Each was found by booting and reading the failure. Expect more. The
alternative is pinning Nixpkgs back to a systemd old enough for this kernel,
which trades a handful of local patches for a very large downgrade across the
whole system.

The list is `patches/systemd/default.nix`, imported both by
`modules/systemd-linux-4.9.nix` and by `checks.<system>.systemd-patches`, so
`nix flake check` proves the set still applies against the current Nixpkgs
without cross-compiling anything or touching the device.

## Toolchain deviation

Droidian builds this tree with AOSP clang 6.0. This port uses GCC 13, the newest
release in Nixpkgs that still only *warns* on the implicit function declarations
a 2019 vendor tree is full of. `enableRemovingWerror` strips `-Werror=` out of
the makefiles, because a blanket `-Wno-error` does not cancel the specific
`-Werror=<name>` form GCC emits.

This is a real deviation and it is not proven harmless. A successful compile
with a different compiler is not ABI compatibility, and this port has not been
compared against a clang-built kernel.
