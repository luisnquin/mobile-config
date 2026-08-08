{
  description = "Mobile NixOS ports for phones and tablets";

  # Mobile NixOS is not a flake. Consumed as a source tree and given its own
  # `system`, it uses the Nixpkgs it pins under npins/, which is the one every
  # device here was validated against.
  inputs.mobile-nixos = {
    url = "github:mobile-nixos/mobile-nixos/2c132754323fc1915e8d21dcfc0ef68ab084c6fb";
    flake = false;
  };

  # Packages only. Its NixOS modules are not imported; see modules/sxmo.nix.
  # Pinned by revision because the tree has not moved since 2022 and a silent
  # update would be a change nobody asked for.
  inputs.sxmo-nix = {
    url = "github:wentam/sxmo-nix/74129afef2e5ebc874fc3b02bbda863c8c2a0cdc";
    flake = false;
  };

  outputs =
    { self, mobile-nixos, sxmo-nix }:
    let
      devices = {
        xiaomi-dandelion = ./devices/xiaomi-dandelion;
      };

      deviceProfiles = {
        huawei-marie = import ./devices/huawei-marie/profile.nix;
      };

      firmwareProfiles = {
        huawei-marie = import ./devices/huawei-marie/firmware.nix;
      };

      bootProfiles = {
        huawei-marie = import ./devices/huawei-marie/boot-contract.nix;
      };

      kernelProfiles = {
        huawei-marie = import ./devices/huawei-marie/kernel/config-comparison.nix;
      };

      researchConfigurations = {
        huawei-marie = ./devices/huawei-marie/configuration.nix;
      };

      buildSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forEachSystem =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) buildSystems
        );

      pkgsFor = system: import "${mobile-nixos}/pkgs.nix" { inherit system; };

      # Host-side device operations. Exposed as both packages and apps: as apps
      # so they are one command, as packages so `--out-link` can hold them
      # against the garbage collector that has already eaten this port's build
      # outputs once.
      toolsFor = system: import ./tools { pkgs = pkgsFor system; };

      firmwareArtifactsFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        import ./devices/huawei-marie/firmware-packages.nix {
          inherit (pkgs)
            fetchurl
            python3
            runCommand
            unzip
            writeShellApplication
            ;
        };

      huaweiSplitImagesFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        import ./devices/huawei-marie/split-images.nix {
          inherit (pkgs)
            coreutils
            jq
            lib
            runCommand
            ;
        };

      kernelArtifactsFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        import ./devices/huawei-marie/kernel/packages.nix {
          inherit (pkgs)
            bc
            bison
            clang
            coreutils
            cpio
            fetchzip
            fetchurl
            file
            findutils
            flex
            gnugrep
            gnumake
            gnutar
            gzip
            lib
            openssl
            patch
            patchelf
            perl
            python3
            rsync
            runCommand
            stdenv
            which
            zlib
            ;
        };

      # Android boot header v2 is not expressible upstream, and dandelion's
      # bootloader rejects v0 and v1. A patch fails loudly; an overlay would
      # silently no-op.
      mobileNixosFor =
        system:
        (pkgsFor system).applyPatches {
          name = "mobile-nixos-patched";
          src = mobile-nixos;
          patches = [ ./patches/mobile-nixos/0001-android-bootimg-header-v2.patch ];
        };

      # `system` must be explicit: Mobile NixOS otherwise falls back to
      # `builtins.currentSystem`, which pure flake evaluation forbids.
      evalDeviceFor =
        system: device: configuration:
        import (mobileNixosFor system) {
          inherit system configuration;
          inherit device;
          # How non-flake sources reach a module's argument set.
          additionalConfiguration = {
            _module.args = { inherit sxmo-nix; };
          };
        };

      evalFor = system: device: evalDeviceFor system devices.${device};

      evalResearchFor =
        system: device: evalDeviceFor system researchConfigurations.${device};

      outputsFor =
        system: device:
        let
          eval = evalFor system device { };

          # The same device with no graphical session. Every systemd patch
          # invalidates the whole closure below it, and with sxmo enabled that
          # closure includes gtk4, gstreamer and the native halves of both --
          # none of which is on the path anyone is debugging on a 4.9 kernel.
          # Same kernel, same initrd, same patched systemd, same networking.
          headless = evalFor system device { mobile.session.sxmo.enable = false; };
        in
        {
          "${device}-boot-img" = eval.outputs.android.android-bootimg;
          "${device}-recovery-img" = eval.outputs.android.android-recovery;
          "${device}-fastboot-images" = eval.outputs.android.android-fastboot-images;
          "${device}-kernel" = eval.config.mobile.boot.stage-1.kernel.package;
          "${device}-system" = eval.config.system.build.toplevel;

          "${device}-headless-fastboot-images" = headless.outputs.android.android-fastboot-images;
          "${device}-headless-system" = headless.config.system.build.toplevel;
        };
    in
    {
      lib = {
        inherit
          devices
          bootProfiles
          deviceProfiles
          evalFor
          evalResearchFor
          firmwareArtifactsFor
          firmwareProfiles
          huaweiSplitImagesFor
          kernelArtifactsFor
          kernelProfiles
          researchConfigurations
          ;
      };

      packages = forEachSystem (
        system:
        builtins.foldl' (acc: device: acc // outputsFor system device) (
          toolsFor system // firmwareArtifactsFor system // kernelArtifactsFor system
        ) (
          builtins.attrNames devices
        )
      );

      apps = forEachSystem (
        system:
        builtins.mapAttrs (name: drv: {
          type = "app";
          program = "${drv}/bin/${name}";
          # The flake app schema carries its own meta; the derivation's is not
          # consulted, and `nix flake check` warns about every app without one.
          meta = drv.meta or { };
        }) (toolsFor system)
      );

      # Cheap enough to run on every change, and it covers the failure that is
      # most expensive to discover late: a nixpkgs bump moving systemd far enough
      # that the 4.9 compatibility patches no longer apply. Native source, no
      # cross-compilation, no device.
      checks = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          huaweiMarie = evalResearchFor system "huawei-marie" { };
          huaweiMarieBoot = bootProfiles.huawei-marie;
          huaweiMarieFirmware = firmwareProfiles.huawei-marie;
          huaweiMarieKernel = kernelProfiles.huawei-marie;
          huaweiMarieSplitFixture = (huaweiSplitImagesFor system) {
            kernel = pkgs.writeText "huawei-marie-split-fixture-kernel" "kernel";
            ramdisk = pkgs.writeText "huawei-marie-split-fixture-ramdisk" "ramdisk";
            kernelCapacityBytes = 1024;
            ramdiskCapacityBytes = 1024;
            kernelFormat = "raw-image.gz";
            ramdiskFormat = "compressed-cpio";
            ramdiskCompression = "gzip";
            evidence = {
              kernelCapacity = "synthetic evaluation fixture";
              kernelFormat = "synthetic evaluation fixture";
              ramdiskCapacity = "synthetic evaluation fixture";
              ramdiskFormat = "synthetic evaluation fixture";
            };
          };
        in
        {
          huawei-marie-research-eval =
            assert huaweiMarie.config.mobile.device.supportLevel == "broken";
            assert huaweiMarie.config.mobile.hardware.soc == "hisilicon-kirin710";
            assert huaweiMarie.config.mobile.system.system == "aarch64-linux";
            assert huaweiMarieFirmware.complete == false;
            assert huaweiMarieFirmware.observed.base == "MAR-LGRP2-OVS 10.0.0.564";
            assert huaweiMarieFirmware.artifacts.base.publicIndexAudit.exactMatch == false;
            assert huaweiMarieFirmware.artifacts.base.publicIndexAudit.closestSameRegion.restoreCompatible == false;
            assert huaweiMarieBoot.complete == false;
            assert huaweiMarieBoot.mobileNixos.compatible == false;
            assert huaweiMarieBoot.mobileNixos.initrdOutput.defaultCompression == "gzip";
            assert huaweiMarieBoot.target.observedAliases.boot == "kernel";
            assert huaweiMarieBoot.target.partitions.ramdisk.sizeKiB == 2 * 1024;
            assert huaweiMarieBoot.sourceDeviceTree.deviceTree.generatedInputs.presentInArchive == false;
            assert huaweiMarieBoot.sourceDeviceTree.deviceTree.exactMarTargetAvailable == false;
            assert huaweiMarieBoot.researchLeads.communityRecovery.usableAsFlashContract == false;
            assert huaweiMarieBoot.splitOutputScaffold.instantiated == false;
            assert huaweiMarieBoot.splitOutputScaffold.includesFlashCommands == false;
            assert builtins.isFunction (huaweiSplitImagesFor system);
            assert huaweiMarieSplitFixture.contract.layout == "huawei-split";
            assert huaweiMarieSplitFixture.contract.flashCommandsIncluded == false;
            assert huaweiMarieKernel.observed.decompressedSha256 == "39e8fe7311c7af288e344fa1b98315597e57ca5fee3f1c250dc16b265a379bf3";
            assert huaweiMarieKernel.sourceVsObserved.exact == false;
            assert huaweiMarieKernel.buildFeasibility.exactStockEquivalentKernelReady == false;
            pkgs.writeText "huawei-marie-research-eval.json" (
              builtins.toJSON {
                inherit (huaweiMarie.config.mobile.device) identity supportLevel;
                inherit (huaweiMarie.config.mobile.hardware) ram screen soc;
                inherit (huaweiMarie.config.mobile.system) system type;
                firmware = huaweiMarieFirmware;
                boot = huaweiMarieBoot;
                kernel = huaweiMarieKernel;
              }
            );

          systemd-patches = pkgs.applyPatches {
            name = "systemd-linux-4.9-patches-apply";
            src = pkgs.systemd.src;
            patches = import ./patches/systemd;
          };
        }
      );

      devShells = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.android-tools
              pkgs.dtc
              pkgs.python3
            ];
          };
        }
      );
    };
}
