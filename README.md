# mobile-config

[Mobile NixOS](https://mobile.nixos.org/) ports for phones and tablets I am
bringing back to life. None of these is a daily driver, and none of them is
finished.

## Devices

| Device | SoC | Kernel | State |
|---|---|---|---|
| [`xiaomi-dandelion`](devices/xiaomi-dandelion) — Redmi 9A, M2006C3LG | MT6762G (Helio G25) | downstream 4.9.190 | stage-1 only: console, backlight, adb, SSH |

Each device directory has its own README with the exact hardware tuple it was
written against, what works, and how to flash it. Read that one before building
anything.

## Build

```sh
nix build .#xiaomi-dandelion-boot-img
nix build .#xiaomi-dandelion-kernel
nix develop                              # adb, fastboot, dtc, python3
```

Outputs are `<device>-{boot-img,recovery-img,fastboot-images,kernel}` for
`x86_64-linux` and `aarch64-linux`. x86_64 cross-compiles.

Everything is pinned: Mobile NixOS by flake input, Nixpkgs by that tree's own
`npins`, each kernel by revision and hash. Vendor kernel trees are large; a cold
build fetches on the order of a gigabyte per device and compiles for a while.

## Layout

```
flake.nix                 device registry, pinned inputs, outputs
authorized-keys.nix       who may SSH in as root during stage-1
modules/                  reusable across devices
  soc/                    per-SoC kernel configuration
devices/<vendor>-<codename>/
  default.nix             identity, boot image geometry, cmdline, USB
  kernel/                 source pin, toolchain, defconfig
  stage-1/                device-specific stage-1 tasks
patches/
  mobile-nixos/           applied to the Mobile NixOS tree
  systemd/                applied to nixpkgs' systemd
  linux/<soc>/            applied to a vendor kernel tree
```

A file goes in `modules/` only once something other than one device needs it.
Patch numbering is global; the directory says which tree the patch belongs to.
Every patch header records the measurement that motivated it.

## Adding a device

1. `devices/<vendor>-<codename>/` with `default.nix` and `kernel/`.
2. Register it in the `devices` attrset in `flake.nix`.
3. Write the device README before the first flash, not after.

## Safety

Flash to a partition you can restore, keep stock firmware hashed and on hand,
and change one variable per boot attempt. A build is not a boot, a boot is not
an installation, and one hardware revision proves nothing about another.

## Licence

Patches under `patches/linux/` and `patches/systemd/` are derivative works of
GPL-2.0 projects and carry those terms. The Nix expressions and stage-1 Ruby
tasks are MIT, matching Mobile NixOS.
