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
| Mainline 6.18 kernel | builds; flashed once, **reset in a loop with no channel** — see below |
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
| Wi-Fi | driver built in and firmware deployed — **awaiting a `recovery` flash**, see below |
| Vendor firmware (wlan, bt, fm, touch) | extracted and installed, 32 blobs |
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

Do **not** run the `flash-critical.sh` that Mobile NixOS drops next to the
fastboot images. It writes `boot` as well as `recovery`, and `boot` is the way
back.

A kernel change is the one change this port cannot undo over ssh, and the store
does not keep what is already on the device — a generation that is no longer a
GC root takes its `recovery.img` with it. Take the partition, not the image, and
verify it against the device rather than against the file you just wrote:

```sh
ssh dandelion 'dd if=/dev/mmcblk0p2 bs=1M count=64' > recovery-p2-<what-it-is>.img
ssh dandelion 'dd if=/dev/mmcblk0p2 bs=1M count=64 | sha256sum'
```

The dump for the kernel that predates the wlan driver is
`~/.local/state/dandelion/recovery-p2-before-wlan.img`, sha256
`fcefe29a1747bd18dc95ef9ca494a8611917f1163e0245631fb09a19df56408b`.

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
nix run .#dandelion-bcb          # what LK boots next; `clear` falls back to Android
```

`dandelion-bcb` is the counterpart to `dandelion-flash-bootimg`: that one writes
the image, this one writes the field that decides whether the image is entered.
`clear` zeroes the 32-byte command in `para` so the next reset lands on `boot`
and stock Android, which is the only fallback an untested kernel on `recovery`
has — see *Trying the mainline arm without losing the device* below. It backs the
first 4096 bytes of `para` up to `~/.local/state/dandelion` before writing, reads
the field back afterwards, and refuses any command other than `boot-recovery` or
`bootonce-bootloader`, because LK ignores what it does not recognise and a
misspelling would read as a successful write.

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
  all set, which should make that buffer survive a reset. After a power cut,
  `/proc/last_kmsg` and `/sys/fs/pstore` were both empty.

  An earlier revision of this section read that as **"it does not work on this
  SoC"**. That does not follow, and the claim is withdrawn. A RAM-backed pstore
  survives a *warm* reset — DRAM rails held up, SoC back through its boot ROM —
  and is expected to come back empty from a power-off, which is the only
  condition it was ever tested under here. What rules it out for a *hanging*
  stage-2 is narrower: a log that only becomes readable after a reset cannot be
  read while the boot it describes is still up. The flash ring can be read live.

  The mainline arm is the case where the reset does happen, and pstore there is
  still unexplored: see *What the mainline arm can and cannot report* below.
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

### What the mainline arm can and cannot report

All three mechanisms above belong to the vendor-kernel arm. None of them reaches
the mainline 6.18 arm, and until patch 0092 the panel may not have either — so a
mainline boot attempt that reports nothing is the expected outcome of the
configuration, and says nothing about how far the kernel got.

Everything in this section was established host-side, from the built artifacts
and the 6.18 source. Nothing here has been checked against the device.

**The UART is out, twice over.** Both `serial@11002000` and `serial@11003000`
are `status = "disabled"` in the mainline tree — read out of
`dtbs/mediatek/mt6762g-xiaomi-dandelion.dtb` in
`.#xiaomi-dandelion-mainline-kernel` — so `mobile.boot.serialConsole`'s
`console=ttyS0,921600n1` resolves to a port the 8250 core never populated. And
`earlycon`, the form that would not need a populated port, is the documented
cause of this port's watchdog resets: see `boot.kernelParams` in `default.nix`.

**The panel is the whole channel, and it was failing before it started.** The
device tree hands simplefb the framebuffer `lk` already set up:

```
chosen {
    stdout-path = "/chosen/framebuffer@7ec50000";
    framebuffer@7ec50000 {
        compatible = "simple-framebuffer";
        reg = <0x00 0x7ec50000 0x00 0xfb0000>;
        ...
```

`simplefb_probe()` maps that with `ioremap_wc()`, and arm64 refuses:

```c
/* Don't allow RAM to be mapped. */
if (WARN_ON(pfn_is_map_memory(__phys_to_pfn(phys_addr))))
        return NULL;
```

— `arch/arm64/mm/ioremap.c`. So if `lk` reports that range as part of
`/memory`, the map returns `NULL`, the probe fails `-ENOMEM`, no fbdev is
registered, and `console=tty1` binds a VT with nothing behind it. The
`request_mem_region()` above it does not catch the mistake either: its failure
is downgraded to a `dev_warn()` and the driver maps the resource anyway
(`drivers/video/fbdev/simplefb.c`). A silent boot is the expected outcome of
this configuration, not a symptom of whatever the kernel then went on to do.

Patch 0092 carves the range out with `no-map`, which is the reservation the
`reg` above always implied. **Whether it changes anything is not known**, and
the device tree says so itself:

```
memory@40000000 {
    device_type = "memory";
    reg = <0x00 0x40000000 0x00 0x00>;
};
```

A declared size of zero. `lk` fills that in at boot, so which pages end up in
the linear map is entirely `lk`'s decision and is not knowable from this tree —
the vendor device tree leaves `/memory` to `lk` in exactly the same way, so
neither arm can answer it.

What can be settled is the *ordering*, and it turns the one thing that was
observed into evidence. The whole chain is verifiable from the 6.18 source and
the built artifacts, without the device:

1. `arch_initcall_sync` — `of_platform_default_populate_init()` in
   `drivers/of/platform.c` special-cases this node by hand:
   `of_get_compatible_child(of_chosen, "simple-framebuffer")`, then
   `sysfb_disable()` and `of_platform_device_create()`. A `simple-framebuffer`
   under `/chosen` is one of the few things outside a `simple-bus` that becomes a
   platform device at all, and it does.
2. `device_initcall` (level 6) — `simplefb.c` ends in
   `module_platform_driver(simplefb_driver)`, so built in it registers here and
   probes immediately. The probe `ioremap`s the range in `reg`. On arm64 that is
   where `pfn_is_map_memory` refuses any page that is part of the linear map;
   `no-map` on a `reserved-memory` range is what carves it out and makes the
   mapping legal. **Without patch 0092 this probe is the thing that fails**, and a
   failed probe means no fbdev, so no fbcon, so a black panel.
3. `late_initcall_sync` (level 7s) — `clk_disable_unused()`, the suspected reset,
   strictly *after* the framebuffer would have come up.

So the observed black screen is not neutral. If the kernel reached level 7s — which
is what the `clk_disable_unused` theory and the reset landing at the userspace
handoff both assert — then it also reached level 6, and a panel that stayed black
means the `ioremap` was refused, which means those pages *were* in the linear map,
which means they are inside `/memory` and **patch 0092 is load-bearing rather than
cosmetic**. The inference is conditional on that reach and nothing more: a kernel
that died before level 6 would also show black, and would say nothing about the
memory map. The reservation is harmless in every case, because an
out-of-`/memory` `reserved-memory` range is simply ignored.

Nothing else competes for the panel. `DRM_MEDIATEK=y` and mtk_drm is compiled in,
which would normally evict simplefb through the aperture-conflict path once a real
DRM device registers — but `dsi@14014000` in the built DTB is
`status = "disabled"` with an empty `port`/`endpoint` and there is no panel node
anywhere in the tree, so that pipeline cannot come up and cannot take the display
away.

**`clk_ignore_unused` was being dropped on the floor.**
`mt6765-xiaomi-garden-common.dtsi` sets `chosen/bootargs = "clk_ignore_unused"`
and calls it load-bearing — "keeps getting watchdog rebooted without it for
now!" — and the built DTB does carry it. MediaTek's `lk` then overwrites
`/chosen/bootargs` with the boot image header's cmdline before entering the
kernel, so the property never arrives. That is established on this unit, not
assumed from `lk` source: the vendor `mt6765.dts` carries its own
`chosen/bootargs` naming `console=ttyS0,921600n1` and nothing else, the vendor
build sets `CONFIG_CMDLINE_FROM_BOOTLOADER=y` so `/chosen/bootargs` *is* the
entire cmdline — and the panel demonstrably owns `/dev/console`. It could not,
unless that property had been replaced wholesale. `boot.kernelParams` now adds
the parameter on the mainline arm.

**USB is a real second channel here, and it is a different controller.** The
mainline tree drives `usb@11200000` as `mediatek,mt6765-musb` with
`dr_mode = "peripheral"`, not as the `mtu3` the vendor kernel uses;
`USB_MUSB_HDRC`, `USB_MUSB_MEDIATEK` and `USB_MUSB_DUAL_ROLE` are all `=y`, the
`phy-mtk-tphy` behind it is built in, and `&usb2`/`&u2phy` are enabled in
`mt6765-xiaomi-garden-common.dtsi`. `CONFIG_USB_MTU3=y` is inherited dead weight:
no node in this tree is compatible with it. Stage-1 does not care which of the
two wins — `modules/stage-1/tasks/usb-gadget-task.rb` writes
`Dir.children("/sys/class/udc").first` into `g1/UDC`, so it binds whatever UDC
registered, under whatever name.

That matters for reading a mainline attempt: enumeration is *not* silent by
construction the way the console is, so a host bus that sees nothing is evidence
about the kernel rather than about the configuration. Watch `dmesg -w` on the
host across the whole attempt: on the vendor arm one enumeration that lives
about thirteen seconds and then disconnects is stage-1 handing off, and a second
one is stage-2 reaching `multi-user.target` — see *Where the rootfs lives* above.
The same timings read the same way here.

**pstore is the next channel, and it needs one number off the device.** A
watchdog reset is a warm reset, so it is exactly the case a RAM-backed pstore is
built for — unlike the power-off that produced the empty `/sys/fs/pstore` above.
The mainline config is already complete for it (`PSTORE_RAM`, `PSTORE_CONSOLE`,
`PSTORE_PMSG`, `PSTORE_COMPRESS`, all `=y`) and `reserved-memory` in the built
DTB holds no `ramoops` node, so the driver has nothing to bind.

What blocks it is the address, and it cannot be read out of any source file —
this was checked rather than assumed. The vendor DTB pulled out of the TWRP image
for this device (`out/dtb`, an AOSP `dt_table` with magic `0xd7b7ab1e` wrapping a
single FDT) declares a `reserved-memory` node holding exactly six children:
`reserve-memory-sspm_share`, `reserve-memory-scp_share`,
`consys-reserve-memory`, `wifi-reserve-memory`, `ion-carveout-heap` and
`soter-shared-mem`. There is no `ram_console`, `pstore` or `ramoops` node in it,
and no `memory@` node either. So the vendor arm does not know the address at
build time any more than the mainline arm does; both learn it from `lk`.

That is because MediaTek does not declare the region in the device tree: `lk`
injects a `/chosen/ram_console` property holding a four-`u32` `mem_desc_t`, and
`mtk_ram_console.c` then reads a second table out of that region's header to
find `pstore_addr`, `pstore_size`, `pstore_console_size` and `pstore_pmsg_size`,
which it hands to `fs/pstore/ram.c` through `pstore_set_addr_size()`. Those land
in module parameters that are world-readable on the running vendor kernel:

```sh
grep . /sys/module/pstore_ram/parameters/*
```

Take those four values from the vendor arm, put them in a `reserved-memory`
`ramoops` node with matching `console-size`/`record-size` on the mainline arm,
and the two kernels compute the same zone layout — so a mainline kernel that
dies writes into the region the vendor kernel reads back on the next boot. The
node is enough on its own: `reserved_mem_matches` in
`of_platform_default_populate_init()` lists `ramoops` explicitly, so a
`reserved-memory` child with that compatible becomes a platform device even
though nothing else under `/reserved-memory` does. No cmdline parameter and no
patch outside the DTS. Until
that reading exists, guessing an address would mean writing into DRAM belonging
to `lk`, the TEE or ATF, which is a new failure mode dressed as a diagnostic.

### Trying the mainline arm without losing the device

It has been tried once, at 91 patches: written to `recovery`, rebooted, and the
device went Redmi logo → black → Redmi logo, forever. No adb, no `rndis0`, no
USB gadget of any kind. Since then it has gained patch 0092 and
`clk_ignore_unused`, neither of which has been on the device.

**The loop was `para`, not the kernel.** LK draws that logo, so logo → black →
logo is LK running, loading `recovery`, dying, resetting, and LK running again.
It comes back to `recovery` every time for the reason in *Where the rootfs
lives* above: the boot control block in `para` still says `boot-recovery`, and
nothing in this port clears it. Clear it and the same dead kernel resets straight
into `boot` — stock Android, adb, a way back. The bootloop is avoidable and the
recovery cost of the last attempt was paid for nothing.

**And the reset itself has a named suspect whose timing fits.** The garden DTSI
sets `clk_ignore_unused` and annotates it "keeps getting watchdog rebooted
without it for now!". That attempt did not have it, because LK had overwritten
the property it was set in; `boot.kernelParams` now passes it on the cmdline,
where LK cannot reach it.

What makes that more than an appeal to the author's comment is *when* the
parameter matters. It gates `clk_disable_unused()`, which `drivers/clk/clk.c`
registers as `late_initcall_sync` — the last initcall level there is, run
immediately before `kernel_init` hands over to userspace. A clock turned off
there that something still needs makes the next register access on that block
hang the bus, and every observed detail follows from that one event: the panel
goes black with the kernel still up, the reset arrives at the point where
userspace would have started, and there is no USB gadget of any kind because
stage-1 configures the gadget from userspace and never ran. The watchdog is the
kernel's own by then, not LK's — see below — and a wedged bus stops its ping
worker just as effectively.

Still a hypothesis: nothing was read off the device. But it is mechanistically
complete, it accounts for the symptom without residue, and it costs one boot to
test.

**What has been ruled out, so it is not re-audited.** All host-side, from the
built artifacts:

- *The watchdog handover.* `mtk_wdt` binds — the DT node's
  `compatible = "mediatek.mt6765-wdt", "mediatek,mt6589-wdt"` has a dot instead
  of a comma in the first string, an upstream typo, but the second string is in
  the driver's match table. `mtk_wdt_init()` reads `WDT_MODE`, sees LK's
  `WDT_MODE_EN` still set and claims it with `WDOG_HW_RUNNING`, and the mainline
  config has `WATCHDOG_HANDLE_BOOT_ENABLED=y` with `WATCHDOG_OPEN_TIMEOUT=0`, so
  the core pings it from a kernel worker with no deadline for userspace to take
  over. A device that never reaches userspace is not reset for that reason.
- *The initrd.* The ramdisk in `.#xiaomi-dandelion-mainline-boot-img` is gzip
  (`1f 8b 08`), and `BLK_DEV_INITRD`, `RD_GZIP` and `DECOMPRESS_GZIP` are all
  `=y`. `SQUASHFS=n` on this arm is not a gap: the rootfs is ext4 and the
  handful of `squashfs` strings in the initrd are one entry in a generic
  filesystem list, alongside `erofs` and `f2fs`, which are equally unused.
- *The cmdline actually shipping.* Read out of the boot image header rather than
  from the Nix evaluation — all twelve tokens, in order:

  ```
  console=ttyS0,921600n1 console=tty1 bootopt=64S3,32N2,64N2 buildvariant=user
  clk_ignore_unused ignore_loglevel systemd.log_target=kmsg systemd.log_level=info
  systemd.show_status=true consoleblank=0 loglevel=4 lsm=landlock,yama,bpf
  ```

  `clk_ignore_unused` is in it. So is `ignore_loglevel`, and the `loglevel=4` that
  follows it does *not* defeat it: `ignore_loglevel` is its own `bool` and
  `suppress_message_printing()` is `level >= console_loglevel && !ignore_loglevel`,
  so the flag short-circuits whatever `console_loglevel` ends up as. Order does not
  matter here, which is worth knowing because it looks like it should.
- *`console=ttyS0` hanging the bus.* This was the real hazard worth checking, since
  writing to a gated UART is exactly how nine earlier boots died — and the token is
  first on the command line. It cannot fire on this arm: both
  `serial@11002000` and `serial@11003000` in the built mainline DTB are
  `status = "disabled"`, so `mediatek,mt6577-uart` never probes and `ttyS0` is never
  registered. The token resolves to nothing. That also answers where the output
  went: `console=tty1` is then the *only* console, `DUMMY_CONSOLE=y` means tty1
  exists and renders nowhere without an fbdev, so with simplefb unbound every
  `printk` went into the ring buffer and no further.
- *The reset being a kernel panic.* `CONFIG_PANIC_TIMEOUT=0`, and
  `CONFIG_PANIC_ON_OOPS` is unset. A panic with `panic_timeout` 0 spins forever
  instead of rebooting, and an oops does not escalate. The device demonstrably
  *reset*, so whatever killed it did not go through `panic()` — which is what puts
  the watchdog, and therefore a wedged CPU or bus, at the centre of the remaining
  theory rather than a software fault the kernel noticed.
- *The missing vendor carveouts.* The mainline tree declares none of the six
  `reserved-memory` regions the vendor DTB does, and one of them is
  `soter-shared-mem` — a TEE's shared window, which is the kind of thing that
  sounds like it would fault the moment Linux allocated over it. It would not:
  every one of the six is declared with `size` plus `alignment` plus
  `alloc-ranges`, never a fixed `reg`, so the *kernel* chooses where each lands
  and hands the address to its consumer afterwards. Nothing that survives from
  `lk` holds a pointer into them. Their absence on the mainline arm loses those
  peripherals, which are not in use anyway; it cannot reset the device.

So, in order, and with the vendor image the whole way until the last step:

1. **Charge from a wall charger first.** Not a PC port: this device net-drains on
   one. A reboot loop costs far more than the flash does, and an unenumerated
   device is capped at 100 mA and cannot charge out of a brown-out.
2. **Clear the BCB and confirm the device boots stock Android on a reset.** That
   is the fallback, and it is worth proving before it is needed rather than
   after.

   ```sh
   nix run .#dandelion-bcb -- clear
   nix run .#dandelion-reboot
   ```
3. **Try `fastboot boot` before writing anything.** With `para` zeroed this is
   the softest test that exists: the image is loaded into RAM and jumped to,
   nothing on flash changes, `recovery` keeps the known-good vendor image, and a
   kernel that dies is one power-cycle from stock Android.

   ```sh
   nix build .#xiaomi-dandelion-mainline-boot-img
   fastboot boot result
   ```

   Whether this LK implements the command is not known — MediaTek's support for
   it is inconsistent, and `fastboot oem reboot-recovery` is already known not to
   be a command here. If it works it makes steps 4 and 5 unnecessary for
   *diagnosis*, though not for proof: a temporary boot skips whatever LK does
   differently when it loads from a partition, so a mainline kernel that lives
   this way still has to be flashed to be believed.
4. **Otherwise, find out whether `fastboot reboot recovery` writes `para`.** This
   is the unknown that decides whether flashing the mainline arm is safe at all.
   If LK implements it as a one-shot in-memory decision, the fallback from step 2
   holds and a dead kernel gets exactly one attempt before the device returns to
   Android. If LK implements it by writing `boot-recovery` into `para`, the
   fallback is erased by the very command that starts the test. Prove it with the
   known-good vendor image: clear the BCB, `fastboot reboot recovery`, and once
   stage-1 is up read the field back.

   ```sh
   nix run .#dandelion-bcb          # zeroes means one-shot, boot-recovery means persisted
   ```
5. **If step 4 says LK persists the BCB, put TWRP on `recovery` first** —
   `~/Downloads/xiaomi-a9/v1/twrp-3.7.0_11-0-dandelion-brigudav.img` — and
   confirm it boots. A real recovery with its own adb is a better safety net than
   a raw kernel, because it can rewrite `recovery` from the device itself,
   without a host bootloader session.
6. **Then the mainline image**, and judge it only by the two channels that exist:
   the host bus (`dmesg -w`, see the USB paragraph above) and a photograph of the
   panel. Nothing else on that arm can report anything.

   The panel is not a coin flip any more, and it is worth knowing in advance which
   of the two outcomes is being looked at, because they point in very different
   directions. The cmdline is already right for it — `ignore_loglevel` is set,
   `console=tty1` is last, and `FB_SIMPLE`, `FRAMEBUFFER_CONSOLE` and `VT_CONSOLE`
   are all `=y` on this arm:

   - **Text on the panel.** simplefb bound, so patch 0092 did what it was written
     for and the panel is now a real console. Photograph the last screen before
     the reset: with `ignore_loglevel` the driver that hung is named on it. This is
     a log channel that needs neither pstore nor USB, and it is the first one this
     arm has ever had.
   - **Still black.** simplefb did not bind, and since patch 0092 has removed the
     `ioremap` refusal as the reason, the remaining one is that the kernel never
     reached `device_initcall` at all. That is a far earlier death than
     `clk_disable_unused` at `late_initcall_sync`, so the leading theory is wrong
     and the next thing to suspect is the decompressor, the DTB handover, or the
     memory map — not a clock.
   - **Text scrolling, then a reset partway through it.** This one is a trap worth
     recognising on sight, because it looks like progress and is actually the
     diagnostic biting. Registering a console replays the whole ring buffer to it,
     `ignore_loglevel` makes that every message at every level, and fbcon on a
     720×1600 fbdev scrolls slowly — while `mtk_wdt` is still 307 initcalls away
     from claiming LK's watchdog (see step 7). A reset *during* the replay is the
     rendering cost tripping a watchdog nobody is petting yet, not a clock and not
     the kernel. The response is to make the replay cheaper — drop
     `ignore_loglevel` for `loglevel=7` — not to go looking for a driver.

   All three outcomes return information, which is what the previous attempt did
   not.

7. **Only if step 6 shows text but does not name the culprit, add `initcall_debug`.**
   This is deliberately a separate boot, and the reason is not the usual
   one-variable-at-a-time caution. `clk_disable_unused()` prints nothing when it
   hangs, so the last line on the panel would be whatever unrelated driver logged
   most recently — suggestive, not conclusive. `initcall_debug` prints
   `calling X+0x0/0x...` *before* each initcall, so the last line on a wedged
   screen is the name of the function that never returned. That is the difference
   between a suspect and an answer.

   The hazard is specific, it is measured rather than assumed, and it is why this
   does not go on the first attempt. Registering a console replays the entire
   accumulated ring buffer to it, so the moment simplefb binds, fbcon renders
   everything printed since boot — and `initcall_debug` makes that several thousand
   lines on a slow fbdev. Both simplefb and `mtk_wdt` are `device_initcall`, so link
   order decides which runs first, and the initcall table in `System.map` is laid
   out in link order:

   ```
   __initcall__kmod_simplefb__708_689_simplefb_driver_init6   entry 524
   __initcall__kmod_mtk_wdt__568_528_mtk_wdt_driver_init6     entry 831
   ```

   simplefb wins, by 307 initcalls. So the replay lands in a window where nothing
   has yet claimed LK's watchdog — `mtk_wdt_init()` has not run, so nothing is
   petting it — and LK's window is on the order of 30–44 s here, from the HWT
   timings in the `earlycon` table above. A diagnostic that causes the reset it was
   added to explain is the worst possible outcome, so it gets its own boot, with the
   step 6 result already in hand to compare against.

**What it costs if the fallback fails anyway** is the reason for all of the
above: with no BCB fallback and no USB gadget, the only route left is BROM or
preloader over USB, which means `mtkclient`, which on this unit dies at
`DRAM setup failed` from BROM and needs a preloader supplied by hand.

**Land pstore before the next attempt.** The failure mode is a *reset loop*, and
a reset is the warm reset a RAM-backed pstore is built to survive — the vendor
kernel on the next boot would read back what the mainline kernel printed before
it died. That is the difference between another blind attempt and a log. It needs
one reading off the running vendor kernel: see the end of the previous section.

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

### Wi-Fi: two halves, one of them already on the device

The driver was never built. `CONFIG_WLAN=y` and `CONFIG_MTK_COMBO_WIFI=y` are
both set in the vendor defconfig and neither of them builds anything —
`drivers/misc/mediatek/connectivity/Makefile` descends into `wlan/core/gen4m/`
only under `CONFIG_WLAN_DRV_BUILD_IN`, which the defconfig leaves unset because
Droidian builds `wmt_drv.ko` and `wmt_chrdev_wifi.ko` out of tree instead. That
symbol is now set; `wlanProbe` and `glRegisterBus` are in `System.map`, and
`Image.gz` grew from 12.26M to 13.41M.

The second half is firmware, which the driver has none of. It lives on the stock
`vendor` partition and is now installed from there — see
`modules/vendor-firmware.nix` for where it comes from and why it is not in this
repository. That half needs no reflash and is already live: `/vendor/firmware`
resolves to the store and lists 32 files.

So the sequence is: switch first, flash second. The rootfs already carries the
firmware, so the reboot that brings up the new kernel brings up both halves
together. Until that flash, `nmcli general` keeps reporting `WIFI-HW missing`,
correctly — the running kernel has no driver.

After it, the network is joined by hand on the device, which is what keeps the
credential out of this repository:

    nmcli device wifi connect <ssid> --ask

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
