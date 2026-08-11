# Huawei P30 Lite — `huawei-marie`

This port targets one physical `MAR-LX3Bm`, hardware SKU `MAR-L03B`, Android
device `HWMAR`. It is an inventory and userspace skeleton. It does not produce
or install an image.

## Measured target

The values below were collected through authorized, read-only ADB on
2026-08-05, and re-read on 2026-08-11 in a second authorized read-only pass that
agreed with all of them — see *Second read-only pass* below for what it added.
The machine-readable record is [`profile.nix`](profile.nix).

| Field | Observed value |
|---|---|
| SoC / architecture | Kirin 710 / AArch64, 4096-byte pages |
| Board identity | `MAR_LX3m_VF`, board ID `7829`, hardware `HL5MARM` |
| Runtime DTBO index | `26`, from `ro.boot.dtbo_idx` — build-specific, see below |
| RAM | 5,826,156 KiB visible to Linux; marketed as 6 GB |
| Display | 1080 × 2312 physical pixels |
| Product build | `10.0.0.564(C605E6R1P1)`, SPL 2022-04-01 |
| Base Android layer | `10.0.0.285(C605E5R1P1)`, SPL 2020-08-01 |
| Firmware set | base `.564`; CUST `.6(C605)`; PRELOAD `.1(C605R1)` |
| Operator layer | `ENTEL.PE 10.0.0.1(CT)`, `C178/D1`, `entel/pe` |
| Kernel | downstream 4.14.116; `/proc/config.gz` is readable |
| Storage | UFS at `ff3c0000.ufs.hi_mci.0` |
| Stock userdata | F2FS; AES-256-XTS contents and AES-256-CTS filenames |
| Verified boot | AVB 1.1, green, enforcing, bootloader locked |
| Partition model | dynamic `super`; not A/B — the table has no `_a`/`_b` name and no pair |
| Bootloader revision | not exposed: `ro.bootloader` is literally `unknown` |

The Huawei layout is not a conventional combined Android boot partition:

- `boot` and `recovery` both resolve to the `kernel` partition (`sdd44`);
- the normal ramdisk is a separate `ramdisk` partition (`sdd17`);
- recovery has separate `recovery_ramdisk`, `recovery_vendor`, and
  `recovery_vbmeta` partitions;
- eRecovery has another kernel/ramdisk/vendor/vbmeta set that shares no partition
  with either other path;
- device trees use separate `dts` and `dto` partitions.

Capacities are no longer candidates. The real UFS table was recovered from
firmware and is [`partitions.nix`](partitions.nix): 24 MiB for `kernel`, 2 MiB
for `ramdisk`, 32 MiB for `recovery_ramdisk`, 16 MiB for `recovery_vendor`,
8 MiB for `dts`, 24 MiB for `dto`, 4 MiB for `vbmeta`, and the erecovery set
sized identically to recovery with its own 24 MiB kernel. See *Recovered
partition table* below.

At pinned revision `2c132754323fc1915e8d21dcfc0ef68ab084c6fb`, Mobile NixOS
`modules/system-types/android/bootimg.nix` always combines kernel and initrd
through `mkbootimg`. Its Android output module then emits a combined `boot.img`
and a script with `boot` and `recovery` fastboot targets. That model cannot
represent this split layout, and the firmware now proves why: stock ships the
kernel and the initrd as two separate Android boot images, each independently
AVB-signed with a different key. [`boot-contract.nix`](boot-contract.nix)
records the mismatch in machine-readable form. The device stays outside the
flake's build registry until there is a kernel and an initrd to package.

## Current gates

1. Establish an unlock route for this exact unit. Stock reports
   `ro.boot.vbmeta.device_state=locked`, `ro.boot.flash.locked=1`, and
   `sys.oem_unlock_allowed=0`. Every route surveyed so far is version-locked
   below this unit:

   - Huawei's official unlock-code service ended in 2018; there is no code to
     request.
   - PotatoNV explicitly does not support Kirin 710 and points elsewhere.
   - Kirin-Tool, the alternative PotatoNV names, documents EMUI 9.1 and older.
   - Software test point needs a firmware security patch level of 2021-01 or
     older. This unit's firmware layer is `.564` / 2022-04-01, so the window is
     closed.

   Do not read `ro.build.version.security_patch` as evidence that the software
   test point window is open. That property reports the Android framework layer
   (2020-08-01 here); the relevant value is the firmware layer recorded as
   `huaweiBuild.securityPatch` in [`profile.nix`](profile.nix). The bootloader
   revision itself is unreadable rather than unread: `ro.bootloader` is the
   literal string `unknown`, `ro.boot.bootloader` is empty, and nothing else in
   `ro.boot.*` carries a version, so `boot.bootloaderRevision = null` is the
   observation. Getting it means `fastboot getvar`, i.e. a bootloader session.

   What remains is a hardware test point plus paid service tooling, which is
   invasive and unverified. No unlock attempt has been made. Independently of
   unlock, mainline Linux carries no Kirin 710 support at all, so an unlock
   alone would not produce a bootable Linux.
2. Acquire the exact base package `MAR-LGRP2-OVS 10.0.0.564`, then hash and
   inspect `kernel`, `ramdisk`, recovery, DT, and vbmeta artifacts. Exact CUST
   and PRELOAD packages are already identified and hash-verified; the base and
   the Entel C178 COTA package remain missing. The COTA package is not optional
   for a full restore: `ro.hw.custPath` is `/cust/cota/cust/entel/pe`, so the
   running system resolves customization through that layer. The base is confirmed to be
   a real Huawei build carrying this unit's exact component tuple, but it is
   published in no downloadable dataset. Two non-exact base packages are located
   and manifest-verified; they are device-tree and geometry evidence for gates 3
   and 5, never restore artifacts for gate 6. The nearer of the two, `.563`, is
   fetched and hash-verified, and it closed the device-tree and geometry halves
   of gates 3 and 5.
3. Match Huawei's official `MAR_10_EMUI10.0.0` source release to the running
   4.14.116 kernel. The DT half of this gate is closed: the exact MAR device tree
   is not in the published source, but it is in the firmware, and board 7829's
   overlay is now identified — see *Recovered device tree* below. What remains is
   the kernel configuration. The supplied `merge_kirin710_defconfig` differs from
   the running configuration by five source-only and 23 stock-only lines. Stock
   forces SHA-512 module signatures using unpublished
   `huawei_signing_key.pem`. Resolving the published defconfig also drops 37
   requested assignments whose Kconfig symbols are not present in the released
   tree.
4. Promote the experimental kernel build into the device configuration only
   after source revision, configuration, toolchain, output name, compression,
   DT inputs, and partition fit are known.
5. Add a Huawei split-image output. First boot target is stage-1 console, ADB,
   and key-only SSH. Graphical session, modem, camera, suspend, and persistent
   installation come later. Neither capacity nor container format is a blocker
   here any more: the full 67-entry table is in
   [`partitions.nix`](partitions.nix) and both container layouts are recorded in
   `firmware.nix` `bootContainers`, so a produced image can be size-checked and
   correctly wrapped before it is ever written. What remains is a kernel and an
   initrd to feed the scaffold.
6. Define recovery before any write: exact stock artifacts, hashes, accepted
   bootloader mode, AVB implications, and a tested return to stock. The
   `erecovery_*` set is both the contingency slot and the first write target —
   see *Boot paths and the softest first write* below. Restore to stock still
   needs the exact `.564` artifacts, which gate 2 has not produced, so the
   contingency is "Android still boots" rather than "the phone can be reflashed".
   Note also that [`partitions.nix`](partitions.nix) covers one LUN: `persist`
   lives on `sdc` and is in no version of that table, so a restore plan derived
   from it omits this unit's calibration data by construction.

## Recovered partition table

The `.563` base package carries a `HISIUFS_GPT` packet holding the real UFS
partition table. It contains three GPT copies describing one geometry two ways:
a 71-entry table in 512-byte LBAs, and a 67-entry table in 4096-byte LBAs whose
block spans are therefore exactly an eighth as large and whose byte sizes are
identical. The 67-entry variant omits `frp`, `persist`, `reserved1` and
`reserved6`.

The 67-entry variant is this unit's, and the match is now complete rather than
sampled. `ls -l /dev/block/by-name` on the running phone yields 70 named
partitions; **all 67 on `sdd` agree with the table on both name and slot, with
no mismatch and nothing extra on either side** — `kernel` on 44, `ramdisk` on 17,
`super` on 64, `userdata` on 67. Against the 71-entry variant every one is off by
four. The remaining three are `frp` (`sdc1`), `persist` (`sdc2`) and `reserved1`
(`sdc3`): a sibling LUN, and precisely three of the four names the 67-entry
variant was already known to omit. The omission is a LUN boundary, not a gap.

Two further sources agree on the sizes: Huawei pads the `KERNEL`, `RAMDISK`,
`RECOVERY_RAMDISK` and `RECOVERY_VENDOR` payloads out to the full partition, and
all four packet lengths equal the GPT span exactly; and the nine sizes previously
carried from `libra_partition.h` in the published kernel source agree with no
disagreements.

**Anything restoring from this table restores one LUN.** `persist` is not in it
and holds per-unit calibration, which is the one class of data no download can
replace. `profile.nix` records the three under `storage.outsideReconstructedTable`
and the flake asserts the table never starts claiming them.

The table is [`partitions.nix`](partitions.nix), generated — do not hand-edit:

```sh
nix run .#huawei-marie-firmware-extract -- update_full_base.zip \
  --packet HISIUFS_GPT --output-dir ./out
```

`DTS`, `DTO` and both vbmeta payloads are stored *unpadded*, so their packet
lengths say nothing about partition capacity. Only the GPT does.

One residual risk: the table comes from `.563` while the unit runs `.564`. The
slot match is device-side evidence of composition and ordering, not of sizes, so
a resize between the two builds would not show up.

Reading the unit's own GPT would close it, and an earlier version of this file
said that needed only ADB. It does not. Every route to a size is denied to the
shell domain on this unit: `/proc/partitions`, `/sys/block/*/size`,
`/proc/cmdline`, and raw reads of the partitions themselves. The by-name
symlinks are the whole of the geometry an unprivileged read can see, and they
carry names and slots only. Closing this needs root, not just ADB.

## Recovered device tree

The published `MAR_10_EMUI10.0.0` source ships no MAR device tree; the firmware
does. This does not contradict
[`kernel/source-evidence.nix`](kernel/source-evidence.nix), which still records
`exactMarTargetAvailable = false` — that is a statement about the source
release, and this evidence came out of a binary instead.

The `DTO` packet is a 4096-byte Huawei wrapper around a standard Android DTBO
container (magic `0xd7b7ab1e`) holding 367 gzipped overlays with unique board
IDs. Board 7829 occurs exactly once, at table index 329, and its
`fragment@157` carries `hisi,boardname = "MAR_LX3m_VF"`,
`hisi,product_name = "MAR-LX3m"`, `hardware_version = "HL5MARM"` and
`hisi,boardid = <0x07 0x08 0x02 0x09>` — the board ID as one decimal digit per
cell. That independently confirms all four identity fields in
[`profile.nix`](profile.nix). The `DTS` packet is a 10240-byte wrapper around a
single gzipped FDT: the `hisilicon,kirin710` SoC base tree, which carries no
board identity of its own.

**Select the device tree by board ID, never by index.** `ro.boot.dtbo_idx`
reports `26`, which is the index the bootloader picked in the DTO installed on
this unit. In `.563`, index 26 is board 7408 — an unrelated STK model — and this
board sits at 329. Both numbers are correct; the index is per-build. Each entry
also self-declares `hisi,dtbo_idx` equal to its own table position, and carries
a family-wide board descriptor list, so `MAR_LX3m_VF` also appears inside the
overlays for boards 7958 and 7886. Only 7829 is this unit.

The applied tree on the running phone confirms the split from the other side.
`ls /proc/device-tree` enumerates root properties `hisi,boardid`,
`hisi,boardname`, `hisi,product_name`, `hisi,chipid`, `hisi,modem_id`, `model`
and `compatible` — and the base tree carries none of the identity ones, so an
identity-bearing overlay demonstrably got merged into the SoC-generic base before
Linux saw it. Every one of those property *values* is `EACCES` to the shell
domain, and the merged tree carries no `hisi,dtbo_idx` at all, so which table
entry was used remains the bootloader's own unverifiable claim. Reading node
names is permitted; reading any of their contents is not.

## Recovered boot containers

Four `.563` payloads were parsed byte by byte. They do not share one shape, and
the difference is why a combined `mkbootimg` image cannot work here.

| Payload | Wrapper | Header | Page | Kernel | Ramdisk |
|---|---|---|---|---|---|
| `KERNEL` | 4096 B Huawei | `ANDROID!` v1, 1648 B | 2048 | 18,661,866 B gzip @ 6144 | none |
| `RAMDISK` | none | `ANDROID!` v0 | 2048 | none | 796,503 B gzip @ 2048 |
| `RECOVERY_RAMDISK` | none | `ANDROID!` v0 | 2048 | none | 27,962,135 B gzip @ 2048 |
| `RECOVERY_VENDOR` | none | `ANDROID!` v0 | 2048 | none | 11,313,251 B gzip @ 2048 |

The `kernel` partition's first 4096 bytes are a Huawei wrapper that is not part
of the boot image and not covered by AVB; its only content is the ASCII string
`kernel` three times. Every ramdisk-side payload decompresses to a `newc` cpio.
`RAMDISK` is a minimal 1.8 MiB Android 10 first-stage ramdisk of eleven entries;
`RECOVERY_RAMDISK` is a complete 65.6 MiB root with its own `init.rc`, sepolicy
and fstabs; `RECOVERY_VENDOR` is 221 entries all under `/vendor`.

Two useful consequences. Mobile NixOS's default initrd compression is gzip,
which is exactly what stock uses, so the split scaffold needs no recompression
step — the flake asserts the two values are equal rather than assuming it. And
the stock kernel command line is now known:

```
loglevel=4 page_tracker=on unmovable_isolate1=2:192M,3:224M,4:256M
printktimer=0xfff0a000,0x534,0x538 androidboot.selinux=enforcing buildvariant=user
```

There is no `console=` in it, so a serial or framebuffer console has to be added
deliberately rather than inherited.

## Verified boot topology

There are three independent AVB roots, not one, each a separately signed vbmeta
partition:

| Root | Chains | Notes |
|---|---|---|
| `vbmeta` | `kernel`, `ramdisk` + 11 more | normal boot; pure chaining, no hash descriptor of its own |
| `recovery_vbmeta` | `kernel`, `recovery_ramdisk`, `recovery_vendor` | **reuses the normal-boot `kernel`** |
| `erecovery_vbmeta` | `erecovery_kernel`, `erecovery_ramdisk`, `erecovery_vendor` | names nothing the other two name |

Keys are per partition class rather than one key for everything — eleven distinct
520-byte RSA-2048 public keys across nineteen chained partitions. `kernel`,
`ramdisk` and `erecovery_kernel` share one; `recovery_ramdisk` and
`erecovery_ramdisk` share another; and so on.

All four boot-side images carry an `AVBf` footer in their last 64 bytes and an
embedded vbmeta. Every one of the four hash descriptors was recomputed here as
`sha256(salt ++ image[start .. start + image_size])` and matched, and each
image's own embedded key equals the key its root pins for that partition. So the
chain is proven from every root down to the bytes. The one link this repository
cannot check is the bootloader's own verification of the three root keys.

**There is no AVB rollback protection in force.** All seven vbmetas parsed —
three roots and four per-partition — carry `rollbackIndex = 0`. The locations
are assigned and distinct, but every index is zero. Earlier notes in this repo
attributed the candidates' unusability as restore artifacts partly to rollback;
that attribution was wrong. They are unusable because a restore has to reproduce
the exact bytes `.564` signed, and no private key exists to sign anything else.

## Boot paths and the softest first write

`erecovery` is not merely a byte-identical spare. It is the only boot path whose
every partition is its own, and it is sized identically to recovery — 24 MiB
kernel, 32 MiB ramdisk, 16 MiB vendor. Recovery, by contrast, loads the same
`kernel` partition normal boot does, so one write there takes out both Android
paths at once.

That fixes the first target. Writing `erecovery_kernel` and `erecovery_ramdisk`
leaves `kernel`, `ramdisk`, `recovery_ramdisk` and `recovery_vendor` bit-for-bit
intact, so both Android normal boot and Android recovery survive a failed
attempt. The cost is the stock emergency-OTA function.

It also rules the normal boot path out on size alone: `ramdisk` is 2 MiB in
total, an order of magnitude below any Mobile NixOS initrd. The 32 MiB
recovery-class slots are the only viable initrd destinations, and stock already
stores a full root filesystem in them, which is the shape this port produces.

One honest limit. Because each stock erecovery payload is a byte-identical copy
of the image it shadows, its embedded hash descriptor names the partition it was
copied from rather than the erecovery one its root chained. Whether Huawei's
bootloader resolves a descriptor name to the partition it loaded or to the
literal name is not observable from firmware. The pattern's consistency across
all three argues for the former — the latter would make erecovery verify
recovery's partitions and defeat its purpose — but it is recorded as an
inference, and `recoveryFallback.independenceFullyVerified` stays `false`.

## Research sources

- [Huawei Open Source Release Center](https://consumer.huawei.com/en/opensource/)
  publishes `MAR_10_EMUI10.0.0` (525.15 MB). It is the primary source candidate,
  but its page describes `nova 4e`; tree inspection must prove applicability to
  `MAR-L03B`. [`kernel/source.nix`](kernel/source.nix) pins the official archive.
  It contains Linux 4.14.116, `merge_kirin710_defconfig`, and build instructions
  for Android GCC 4.9 plus Clang `r346389c`.
- [Mobile NixOS device list](https://mobile.nixos.org/devices/index.html) has no
  Huawei or Kirin target. This is a new port.
- [SHRP `huawei_marie` tree](https://github.com/Iceows/shrp_android_device_huawei_marie)
  is a community lead for the codename and recovery geometry, not compatibility
  proof. Its reported base, offsets, sizes, and AVB settings must be compared to
  exact stock images.
- [PotatoNV support matrix](https://github.com/kitsuned/PotatoNV) explicitly
  excludes Kirin 710 and points to separate alternatives.
- [Huawei bootloader tools](https://github.com/lilianalillyy/huawei-bootloader-tools)
  is a community brute-force implementation. Its documented EMUI 9-or-older
  requirement makes it evidence against treating a code search as an EMUI 10
  unlock route, not an executable plan for this unit.
- The public firmware index at
  [professorjtj.github.io](https://github.com/ProfessorJTJ/professorjtj.github.io)
  republishes Huawei CDN locations across four `firmwards.hash` datasets. It is a
  location index, not an authority: every artifact it points at is still checked
  against the `filelist.xml` hashes Huawei serves alongside it.
- `arch/arm64/boot/dts/hisilicon` in mainline Linux carries only hi3660, hi3670,
  hi6220 and server parts, and pmaports has no Kirin device at all. There is no
  upstream Kirin 710 device tree to start from, which is why the Huawei source
  release and a stock base package are the only identified DT paths.

## Stock recovery state

[`firmware.nix`](firmware.nix) records the exact component tuple and artifact
metadata. Huawei CDN file lists supplied SHA-256 hashes for both available
packages; downloaded copies matched them byte-for-byte.

All four datasets in the public firmware index were audited at revision
`a511283e6e13c2a25da82e722e92e3704671f17d`. The datasets are compressed, not
text, so grepping a downloaded `firmwards.hash` reports zero matches whatever it
contains; [`tools/decode-firmware-index.py`](tools/decode-firmware-index.py)
documents the four stacked transforms and decodes and queries them:

```sh
python3 tools/decode-firmware-index.py firmwards.hash --match MAR-L03B --match C605
python3 tools/decode-firmware-index.py v2/firmwards.hash --match 10.0.0.564
```

The decoder is validated against this file: it reproduces the ROM IDs, versions,
and `filelist.xml` URLs already recorded for CUST (467371), PRELOAD (396408),
and the `.514` base (594102).

Two dataset families exist and they answer different questions. The `normal`,
`base-archive`, and `downgrade` datasets carry CDN locations. The `v2` dataset
carries model-to-component tuples and no locations, so it can only prove that a
build exists.

`v2` confirms that `MAR-L03B` / `C605` / `hw-la` pairs
`MAR-LGRP2-OVS 10.0.0.564` with exactly the CUST and PRELOAD recorded in
[`firmware.nix`](firmware.nix), and that it is the newest base for this region.
The observed identity is therefore correct and the base is genuinely
unpublished, not mistranscribed. No download dataset contains `.564`.

Two non-exact base packages are located and verified against their own
`filelist.xml`:

| Candidate | ROM ID | Date | Behind `.564` | Size | Notes |
|---|---|---|---|---|---|
| `.563` | 638956 | 2022-07-05 | 1 | 3,199,648,722 | row reads `hw-eea`; manifest declares 11 groups including `hw-la` |
| `.514` | 594102 | 2021-10-21 | 50 | 3,178,550,002 | newest base whose own row is `MAR-L03B` / `C605` / `hw-la` |

A Huawei base package is region-independent; region lives in CUST and PRELOAD.
A dataset row's region is the region of that row, not the set of groups the
package serves, which is why `.563` reads as `hw-eea` while serving `hw-la` too.
`.563` is therefore the better device-tree and geometry source, one increment
from stock, with `.514` as the fallback if it carries no `MAR-L03B` target.

Neither is a restore artifact. A restore has to reproduce the exact bytes `.564`
signed, so both remain negative evidence for gate 6 — not for rollback reasons,
since every vbmeta in `.563` carries `rollbackIndex = 0`. `.563` has been
downloaded and hash-verified, and every one of its 44 packets hashed; it supplied
the partition table, the device tree, the boot containers and the AVB topology.
`.514` has not been downloaded.

| Component | State |
|---|---|
| Base `MAR-LGRP2-OVS 10.0.0.564` | confirmed real, unpublished; `.563` and `.514` rejected as restore substitutes |
| CUST `10.0.0.6(C605)` | verified: `565d07fef72af9e64cf5e34c8a4ccd82a3b6de04e2c467c55a933d601b3fe006` |
| PRELOAD `10.0.0.1(C605R1)` | verified: `ffd5dc8653b2dff0f7cf72a38219a45a883e346da92a00ac70c3e2b3bab0afb4` |
| Operator COTA `C178/D1` | role in full recovery unknown |

The verified components are fixed-output packages. Building them fetches the
Huawei CDN objects and rejects content that does not match the recorded hash:

```sh
nix build .#huawei-marie-stock-cust
nix build .#huawei-marie-stock-preload
nix build .#huawei-marie-stock-audit
```

The audit decompresses each `UPDATE.APP`, verifies its entry CRC, checks exact
`VERSION.mbn` identities, then emits immutable store paths as JSON. Whole-ZIP
testing is intentionally avoided because Huawei's SignApk output contains a
zero-length extra field that Info-ZIP rejects before checking payloads.

Inspect a candidate base package without extracting or modifying it:

```sh
nix run .#huawei-marie-firmware-inspect -- \
  --expected-version 'MAR-LGRP2-OVS 10.0.0.564' path/to/update.zip
```

The report includes whole-file and `UPDATE.APP` hashes, `UPDATE.APP` ZIP-entry
CRC verification, exact version identity, packet offsets, Huawei packet names,
sizes, sequence bytes, and payload hashes. It also accepts a raw `UPDATE.APP`;
version matching then remains unavailable because `VERSION.mbn` belongs to the
outer OTA ZIP.

The official source archive and its audit are also fixed-output packages:

```sh
nix build .#huawei-marie-kernel-source
nix build .#huawei-marie-kernel-config
nix build .#huawei-marie-kernel-source-audit
nix build .#huawei-marie-clang-r346389c
nix build .#huawei-marie-gcc-4-9
nix build .#huawei-marie-kernel-toolchain-audit
```

The source audit verifies the defconfig and partition-header hashes, Linux
4.14.116 version fields, Kirin 710 platform selection, UFS candidate geometry,
documented Android GCC/Clang revisions, and the documented `Image.gz` output.
It also confirms that no DT source filename under `arch/arm64/boot/dts` names
`kirin710`, `libra`, `mar`, or `marie`. More importantly, the ARM64 `dtbs`
target calls `auto-generate/config` and `auto-generate/overlay`, but both
directories are absent from the archive. The published defconfig builds a
standalone `Image.gz` with no appended DT. The exact MAR `dts` and `dto`
inputs must therefore come from the exact stock base package or another
proven vendor source. The archive contains MAR display tables and its Miami
modem version shares `C20B388` with the running baseband; those facts support
family relevance, not an exact MAR-L03B source match.

[`kernel/config-comparison.nix`](kernel/config-comparison.nix) records the live
`/proc/config.gz` hashes, exact source/stock line delta, resolved-config hash,
and missing production signing key. The config package runs Huawei's real
`merge_kirin710_defconfig` target in a Nix sandbox; it is build input evidence,
not a bootable kernel.

The toolchain audit executes the pinned Android Clang and GCC packages. Clang
reports the same `5220042`, `r346389c`, Clang commit, and LLVM commit embedded in
the running kernel. GCC 4.9 comes from the immutable Android 10 release tree,
but the running kernel does not expose a GCC/binutils commit, so that package
remains a candidate. Kconfig host utilities use Nixpkgs Clang; the Android
Clang package is used by an experimental build-feasibility derivation.

That derivation now completes. On 2026-08-06 it built the published source with
patch 0008, the pinned Android Clang `r346389c` and GCC 4.9, and emitted
`arch/arm64/boot/Image.gz` — 18,523,241 bytes,
`d3b8569c4bfbe5ef6ffc280a59ab049ecb1e1f065207ea48c5bbafc069d1efd4`, 73.6% of the
candidate 24 MiB `kernel` capacity. `modpost` reported one section mismatch and
declined to version several vendor block-layer exports; neither is fatal.

That result proves the toolchain and configuration are sufficient to produce a
kernel image. It proves nothing about booting this unit. The image is not stock
equivalent — the resolved defconfig still drops 37 assignments, module signing
uses a key Huawei did not publish, and the archive carries no MAR device tree,
so the separate `dts` and `dto` partitions have no source here. The derivation
remains disconnected from the device configuration.

The current SHRP community tree was also pinned at
`a0f7d9227d6c15d80ed4227b2aaf8cfc6d36c4bc`. It packages a gzip recovery
ramdisk with `mkbootimg` and an empty dummy kernel, using a 32 MiB limit that
matches the candidate `recovery_ramdisk` size. It also uses an AOSP test AVB
key, a synthetic 2099 security patch, labels the device A/B, and points its
recovery target at `erecovery_ramdisk`; meanwhile the live Android `recovery`
alias resolves to `kernel`. This is useful format evidence only. It is not a
stock-compatible image or flash target contract.

## Second read-only pass

A second authorized read-only ADB pass on 2026-08-11, run to close entries in
`profile.nix`'s `unknown` list rather than to recollect. Nothing it re-read
disagreed with the 2026-08-05 record: the whole `ro.boot.*` set, both vbmeta
digests, `avb_version 1.1`, `flash.locked 1`, `veritymode enforcing`,
`dtbo_idx 26`, and `/proc/config.gz` still decompressing to 6142 lines hashing to
`39e8fe73…`, the value `kernel/config-comparison.nix` records and the flake
asserts.

What it settled:

- **The bootloader revision is not collectable, not merely uncollected.**
  `ro.bootloader` reads the literal string `unknown`, `ro.boot.bootloader` is
  empty, and no other property in the `ro.boot.*` set carries a version. Only
  `fastboot getvar` could answer it, which means a reboot into the bootloader.
- **The Entel C178 layer is live, not optional.** `ro.hw.custPath` is
  `/cust/cota/cust/entel/pe`, so the running system resolves customization
  through the COTA tree. The two C-versions are different layers and both are
  real: C178 identifies the carrier variant, while the CUST and PRELOAD
  *packages* are C605.
- **The partition table is device-confirmed for all 67 entries**, and the three
  partitions it omits are on a second LUN. See *Recovered partition table*.
- **An identity-bearing DTBO is provably applied.** See *Recovered device tree*.
- `/proc/version` gives the full toolchain string: clang `8.0.7svn` from Android
  build `5220042` based on `r346389c`, kernel built `Tue Apr 12 22:13:18 CST 2022`.

What it could not reach, and why: partition *sizes* (every route denied to the
shell domain), which DTBO entry is live (property values denied), and
temporary-boot support (needs fastboot, so out of read-only scope by
construction). None of these is closable without either root or a bootloader
session.

## Repository state

[`configuration.nix`](configuration.nix) contains only facts that do not depend
on unverified boot geometry: identity, SoC, RAM, display, TTY/SSH bring-up, and
USB networking. It intentionally has no kernel package, partition destination,
boot-image offsets, or flash application.

[`split-images.nix`](split-images.nix) is the uninstantiated host-side output
builder for Huawei's split layout. It copies supplied kernel and ramdisk bytes
without repacking, rejects files larger than caller-supplied exact capacities,
and emits hashes and format metadata. It contains no flash command. Its inputs
are now all known: capacities from [`partitions.nix`](partitions.nix), and
`kernelFormat = "huawei-wrapper"`, `ramdiskFormat = "huawei-wrapper"`,
`ramdiskCompression = "gzip"` from `firmware.nix` `bootContainers`, recorded as
`splitOutputScaffold.resolvedFormats`. Mobile NixOS's default initrd compression
is gzip, which matches stock. What the builder still lacks is content — no kernel
image and no initrd exist for this board — so the flake exposes it as
`lib.huaweiSplitImagesFor` and instantiates only a synthetic fixture in `checks`.

It also requires a `deviceTrees` argument naming both trees, and refuses to
build without it. A normal boot on this device needs four partitions, not the
two this builder writes: the kernel is a bare `Image.gz` with no appended DT, so
`dts` and `dto` are boot dependencies of any kernel written here even though
both stay stock. They appear in `manifest.json` (schema 2) under
`requiredNotWritten.deviceTrees`, and the overlay must declare
`selectedBy = "board-id"` — an index is rejected outright, for the reason in
*Recovered device tree* above.

Inspect the profile without evaluating a device build:

```sh
nix eval --json .#lib.deviceProfiles.huawei-marie
nix eval --json .#lib.firmwareProfiles.huawei-marie
nix eval --json .#lib.bootProfiles.huawei-marie
nix eval --json .#lib.kernelProfiles.huawei-marie
nix eval --raw .#lib.researchConfigurations.huawei-marie
```
