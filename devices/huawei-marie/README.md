# Huawei P30 Lite — `huawei-marie`

This port targets one physical `MAR-LX3Bm`, hardware SKU `MAR-L03B`, Android
device `HWMAR`. It is an inventory and userspace skeleton. It does not produce
or install an image.

## Measured target

The values below were collected through authorized, read-only ADB on
2026-08-05. The machine-readable record is [`profile.nix`](profile.nix).

| Field | Observed value |
|---|---|
| SoC / architecture | Kirin 710 / AArch64, 4096-byte pages |
| Board identity | `MAR_LX3m_VF`, board ID `7829`, hardware `HL5MARM`, DTBO index `26` |
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
| Partition model | dynamic `super`; no slot properties reported |

The Huawei layout is not a conventional combined Android boot partition:

- `boot` and `recovery` both resolve to the `kernel` partition (`sdd44`);
- the normal ramdisk is a separate `ramdisk` partition (`sdd17`);
- recovery has separate `recovery_ramdisk`, `recovery_vendor`, and
  `recovery_vbmeta` partitions;
- eRecovery has another independent kernel/ramdisk/vendor/vbmeta set;
- device trees use separate `dts` and `dto` partitions.

The official source partition table matches the observed UFS partition numbers.
It gives candidate capacities of 24 MiB for `kernel`, 2 MiB for `ramdisk`,
32 MiB for `recovery_ramdisk`, 16 MiB for `recovery_vendor`, 8 MiB for `dts`,
24 MiB for `dto`, and 4 MiB for `vbmeta`. These remain candidates until exact
stock GPT or bootloader output confirms them.

At pinned revision `2c132754323fc1915e8d21dcfc0ef68ab084c6fb`, Mobile NixOS
`modules/system-types/android/bootimg.nix` always combines kernel and initrd
through `mkbootimg`. Its Android output module then emits a combined `boot.img`
and a script with `boot` and `recovery` fastboot targets. That model cannot
represent this split layout. [`boot-contract.nix`](boot-contract.nix) records
the mismatch and missing format evidence in machine-readable form. The device
stays outside the flake's build registry until exact stock images prove the
packaging and targets.

## Current gates

1. Establish an unlock route for this exact unit. Stock reports
   `ro.boot.vbmeta.device_state=locked` and `ro.boot.flash.locked=1`. Huawei no
   official consumer unlock route has been found. PotatoNV explicitly does not
   support Kirin 710. Unlock-code brute-force tools depend on the fastboot OEM
   unlock command and their own documentation limits them to EMUI 9 or older;
   this unit runs EMUI 10. Paid test-point/service tooling remains unverified.
   No unlock attempt has been made.
2. Acquire the exact base package `MAR-LGRP2-OVS 10.0.0.564`, then hash and
   inspect `kernel`, `ramdisk`, recovery, DT, and vbmeta artifacts. Exact CUST
   and PRELOAD packages are already identified and hash-verified; the base and
   possible Entel C178 COTA package remain missing.
3. Match Huawei's official `MAR_10_EMUI10.0.0` source release to the running
   4.14.116 kernel and locate the exact MAR DT targets. The supplied
   `merge_kirin710_defconfig` differs from the running configuration by five
   source-only and 23 stock-only lines. Stock forces SHA-512 module signatures
   using unpublished `huawei_signing_key.pem`. Resolving the published
   defconfig also drops 37 requested assignments whose Kconfig symbols are not
   present in the released tree.
4. Promote the experimental kernel build into the device configuration only
   after source revision, configuration, toolchain, output name, compression,
   DT inputs, and partition fit are known.
5. Add a Huawei split-image output. First boot target is stage-1 console, ADB,
   and key-only SSH. Graphical session, modem, camera, suspend, and persistent
   installation come later.
6. Define recovery before any write: exact stock artifacts, hashes, accepted
   bootloader mode, rollback/AVB implications, and a tested return to stock.

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

## Stock recovery state

[`firmware.nix`](firmware.nix) records the exact component tuple and artifact
metadata. Huawei CDN file lists supplied SHA-256 hashes for both available
packages; downloaded copies matched them byte-for-byte.

The normal, base, and downgrade datasets in the public firmware index were
audited at revision `a511283e6e13c2a25da82e722e92e3704671f17d`. None contains
the exact `.564` base. The nearest same-region entry is `.514` (ROM ID 594102),
which is recorded only as negative evidence and must not be used for restore.

| Component | State |
|---|---|
| Base `MAR-LGRP2-OVS 10.0.0.564` | missing; older `.514` archive entry rejected as a restore substitute |
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

## Repository state

[`configuration.nix`](configuration.nix) contains only facts that do not depend
on unverified boot geometry: identity, SoC, RAM, display, TTY/SSH bring-up, and
USB networking. It intentionally has no kernel package, partition destination,
boot-image offsets, or flash application.

[`split-images.nix`](split-images.nix) is the uninstantiated host-side output
builder for Huawei's split layout. It copies supplied kernel and ramdisk bytes
without repacking, rejects files larger than caller-supplied exact capacities,
and emits hashes and format metadata. It contains no flash command. The current
source-derived capacities are not accepted as exact inputs, so the flake exposes
the builder as `lib.huaweiSplitImagesFor` but creates no split image package yet.
Mobile NixOS produces a gzip-compressed cpio initrd by default; whether stock
firmware accepts that directly in `ramdisk` remains unknown.

Inspect the profile without evaluating a device build:

```sh
nix eval --json .#lib.deviceProfiles.huawei-marie
nix eval --json .#lib.firmwareProfiles.huawei-marie
nix eval --json .#lib.bootProfiles.huawei-marie
nix eval --json .#lib.kernelProfiles.huawei-marie
nix eval --raw .#lib.researchConfigurations.huawei-marie
```
