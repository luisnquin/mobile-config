{
  description = "Mobile NixOS ports for phones and tablets";

  inputs = {
    mobile-nixos = {
      url = "github:mobile-nixos/mobile-nixos/2c132754323fc1915e8d21dcfc0ef68ab084c6fb";
      flake = false;
    };

    sxmo-nix = {
      url = "github:wentam/sxmo-nix/74129afef2e5ebc874fc3b02bbda863c8c2a0cdc";
      flake = false;
    };

    black-terminal.url = "github:luisnquin/black-terminal/8f5e97bbfbe96cf9c4ef6736b17fd4b42f7b0100";

    home-manager.url = "github:nix-community/home-manager/bf9ce9fec78f95f374e8dd3b503863a3ec128ebe";
  };

  outputs = {
    self,
    mobile-nixos,
    sxmo-nix,
    black-terminal,
    home-manager,
  }: let
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

    forEachSystem = f:
      builtins.listToAttrs (
        map (system: {
          name = system;
          value = f system;
        })
        buildSystems
      );

    pkgsFor = system: import "${mobile-nixos}/pkgs.nix" {inherit system;};

    # Host-side device operations. Exposed as both packages and apps: as apps
    # so they are one command, as packages so `--out-link` can hold them
    # against the garbage collector that has already eaten this port's build
    # outputs once.
    toolsFor = system: import ./tools {pkgs = pkgsFor system;};

    firmwareArtifactsFor = system: let
      pkgs = pkgsFor system;
    in
      import ./devices/huawei-marie/firmware-packages.nix {
        inherit
          (pkgs)
          fetchurl
          python3
          runCommand
          unzip
          writeShellApplication
          ;
      };

    huaweiSplitImagesFor = system: let
      pkgs = pkgsFor system;
    in
      import ./devices/huawei-marie/split-images.nix {
        inherit
          (pkgs)
          coreutils
          jq
          lib
          runCommand
          ;
      };

    kernelArtifactsFor = system: let
      pkgs = pkgsFor system;
    in
      import ./devices/huawei-marie/kernel/packages.nix {
        inherit
          (pkgs)
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
    mobileNixosFor = system:
      (pkgsFor system).applyPatches {
        name = "mobile-nixos-patched";
        src = mobile-nixos;
        patches = [./patches/mobile-nixos/0001-android-bootimg-header-v2.patch];
      };

    # `system` must be explicit: Mobile NixOS otherwise falls back to
    # `builtins.currentSystem`, which pure flake evaluation forbids.
    evalDeviceFor = system: device: configuration:
      import (mobileNixosFor system) {
        inherit system configuration;
        inherit device;
        # How non-flake sources reach a module's argument set. Device files
        # are paths, so a flake input can only reach them from here.
        additionalConfiguration = {
          imports = [
            black-terminal.nixosModules.default
            home-manager.nixosModules.home-manager
          ];
          _module.args = {inherit sxmo-nix black-terminal;};
        };
      };

    evalFor = system: device: evalDeviceFor system devices.${device};

    evalResearchFor = system: device: evalDeviceFor system researchConfigurations.${device};

    outputsFor = system: device: let
      eval = evalFor system device {};

      # The same device with the graphical session turned back on. It is the
      # exception rather than the default because it has never started: X dies
      # before writing a log, and the closure it adds -- mesa, xorg-server,
      # gtk4, gstreamer, ffmpeg -- is what makes a systemd patch cost hours,
      # since systemdMinimal is libudev and mesa links it. Build this one when
      # the job is debugging X. Same kernel, same initrd, same patched systemd,
      # same networking.
      graphical = evalFor system device {mobile.session.sxmo.enable = true;};

      # Linux 6.18 LTS instead of the vendor 4.9.190 tree. Compiles and
      # produces a device tree; never booted on hardware. Only the kernel and
      # the boot image are exposed -- the rootfs is the same closure either
      # way, and building it here would only duplicate it.
      mainline = evalFor system device {
        mobile.hardware.socs.mediatek-mt6765.kernelTree = "mainline";
      };
    in {
      "${device}-boot-img" = eval.outputs.android.android-bootimg;
      "${device}-recovery-img" = eval.outputs.android.android-recovery;
      "${device}-fastboot-images" = eval.outputs.android.android-fastboot-images;
      "${device}-kernel" = eval.config.mobile.boot.stage-1.kernel.package;
      "${device}-system" = eval.config.system.build.toplevel;

      "${device}-graphical-fastboot-images" = graphical.outputs.android.android-fastboot-images;
      "${device}-graphical-system" = graphical.config.system.build.toplevel;

      "${device}-mainline-kernel" = mainline.config.mobile.boot.stage-1.kernel.package;
      "${device}-mainline-boot-img" = mainline.outputs.android.android-bootimg;
    };
  in {
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

    # `nixos-rebuild --flake` only looks under this attribute, and mobile-nixos
    # hands back a bare eval that never lands there. Naming it buys the
    # incremental path: `nixos-rebuild switch --target-host` copies the store
    # delta over the gadget instead of writing 2.2 GiB of image through the
    # stage-1 latch.
    #
    # Cross from x86_64-linux rather than forEachSystem, because the attribute
    # takes no system argument and every image this port has produced was built
    # that way. Before switching, check that `config.systemd.package` matches
    # what PID 1 is already running: re-execing across two systemd builds hangs
    # in manager_new(), and the whole point of these ports is a patched systemd.
    nixosConfigurations = builtins.foldl' (
      acc: device:
        acc
        // {
          ${device} = evalFor "x86_64-linux" device {};
          "${device}-graphical" = evalFor "x86_64-linux" device {
            mobile.session.sxmo.enable = true;
          };
        }
    ) {} (builtins.attrNames devices);

    apps = forEachSystem (
      system:
        builtins.mapAttrs (name: drv: {
          type = "app";
          program = "${drv}/bin/${name}";
          # The flake app schema carries its own meta; the derivation's is not
          # consulted, and `nix flake check` warns about every app without one.
          meta = drv.meta or {};
        }) (toolsFor system)
    );

    # Cheap enough to run on every change, and it covers the failure that is
    # most expensive to discover late: a nixpkgs bump moving systemd far enough
    # that the 4.9 compatibility patches no longer apply. Native source, no
    # cross-compilation, no device.
    checks = forEachSystem (
      system: let
        pkgs = pkgsFor system;
        huaweiMarie = evalResearchFor system "huawei-marie" {};
        huaweiMarieBoot = bootProfiles.huawei-marie;
        huaweiMarieFirmware = firmwareProfiles.huawei-marie;
        huaweiMarieKernel = kernelProfiles.huawei-marie;
        huaweiMariePartitions = import ./devices/huawei-marie/partitions.nix;

        # profile.nix names the block device a write actually lands on
        # (`kernel = "sdd44"`); partitions.nix carries the slot numbers. Nothing
        # connected the two, and partitions.nix says to regenerate it rather than
        # hand-edit it -- so a regenerated table that renumbers a slot would leave
        # profile.nix aiming a flash at whatever moved into the old index, on a
        # device with a locked bootloader whose only independent recovery path is
        # one partition wide. This attrset is that missing contract: the GPT entry
        # each logical role in profile.nix is required to resolve to.
        huaweiMarieDeviceRoles = {
          kernel = "kernel";
          ramdisk = "ramdisk";
          recoveryRamdisk = "recovery_ramdisk";
          recoveryVendor = "recovery_vendor";
          recoveryVbmeta = "recovery_vbmeta";
          erecoveryKernel = "erecovery_kernel";
          erecoveryRamdisk = "erecovery_ramdisk";
          erecoveryVendor = "erecovery_vendor";
          erecoveryVbmeta = "erecovery_vbmeta";
          dts = "dts";
          dto = "dto";
          vbmeta = "vbmeta";
          super = "super";
          userdata = "userdata";
        };
        huaweiMarieSplitFixture = (huaweiSplitImagesFor system) {
          kernel = pkgs.writeText "huawei-marie-split-fixture-kernel" "kernel";
          ramdisk = pkgs.writeText "huawei-marie-split-fixture-ramdisk" "ramdisk";
          kernelCapacityBytes = 1024;
          ramdiskCapacityBytes = 1024;
          kernelFormat = "raw-image.gz";
          ramdiskFormat = "compressed-cpio";
          ramdiskCompression = "gzip";
          # The payloads are synthetic but the device-tree pair is not: taken
          # from the firmware evidence so the fixture cannot describe a board
          # this port never proved, and so a change in that evidence has to be
          # answered here.
          deviceTrees = {
            base = {
              partition = huaweiMarieDeviceRoles.dts;
              compatible = huaweiMarieFirmware.deviceTreeEvidence.base.compatible;
              wrapperBytes = huaweiMarieFirmware.deviceTreeEvidence.base.wrapperBytes;
              written = false;
            };
            overlay = {
              partition = huaweiMarieDeviceRoles.dto;
              selectedBy = "board-id";
              boardId = huaweiMarieFirmware.deviceTreeEvidence.overlay.selected.boardId;
              container = huaweiMarieFirmware.deviceTreeEvidence.overlay.container;
              wrapperBytes = huaweiMarieFirmware.deviceTreeEvidence.overlay.wrapperBytes;
              written = false;
            };
          };
          evidence = {
            kernelCapacity = "synthetic evaluation fixture";
            kernelFormat = "synthetic evaluation fixture";
            ramdiskCapacity = "synthetic evaluation fixture";
            ramdiskFormat = "synthetic evaluation fixture";
          };
        };
      in {
        huawei-marie-research-eval = assert huaweiMarie.config.mobile.device.supportLevel == "broken";
        assert huaweiMarie.config.mobile.hardware.soc == "hisilicon-kirin710";
        assert huaweiMarie.config.mobile.system.system == "aarch64-linux";
        assert huaweiMarieFirmware.complete == false;
        assert huaweiMarieFirmware.observed.base == "MAR-LGRP2-OVS 10.0.0.564";
        assert huaweiMarieFirmware.artifacts.base.publicIndexAudit.exactMatch == false;
        assert huaweiMarieFirmware.artifacts.base.publicIndexAudit.buildConfirmedByV2.downloadable == false;
        assert builtins.all (c: c.restoreCompatible == false) (
          builtins.attrValues huaweiMarieFirmware.artifacts.base.publicIndexAudit.candidates
        );
        assert huaweiMarieFirmware.partitionGeometry.exact == true;
        assert huaweiMarieFirmware.partitionGeometry.entryCount == 67;
        assert huaweiMarieFirmware.partitionGeometry.logicalBlockBytes == 4096;
        # Every padded payload length must still equal its partition's size, so
        # a regenerated partitions.nix cannot silently drift.
        assert builtins.all (
          name:
            (builtins.getAttr name huaweiMariePartitions.partitions).sizeKiB
            * 1024
            == builtins.getAttr name huaweiMarieFirmware.partitionGeometry.validation.paddedPayloads
        ) (builtins.attrNames huaweiMarieFirmware.partitionGeometry.validation.paddedPayloads);
        # Every `sddNN` in profile.nix must still be the slot of the GPT entry it
        # claims to be, so renumbering cannot redirect a write silently.
        assert builtins.all (
          role:
            builtins.getAttr role deviceProfiles.huawei-marie.partitions
            == "sdd"
            + toString
            (builtins.getAttr (builtins.getAttr role huaweiMarieDeviceRoles) huaweiMariePartitions.partitions).slot
        ) (builtins.attrNames huaweiMarieDeviceRoles);
        # And a role added to profile.nix without a contract entry must not slip
        # through unchecked. `bootAlias`/`recoveryAlias` name other roles, not
        # devices, so they are the only permitted exclusions.
        assert builtins.attrNames huaweiMarieDeviceRoles
        == builtins.filter
        (n: !(builtins.elem n ["bootAlias" "recoveryAlias"]))
        (builtins.attrNames deviceProfiles.huawei-marie.partitions);
        # The table is now confirmed against the unit, name and slot for all 67
        # entries, so a regeneration that drifts from the device is a defect
        # rather than new information.
        assert deviceProfiles.huawei-marie.storage.tableConfirmedOnDevice == true;
        # It covers one LUN. These three partitions are on the sibling and in no
        # version of the table, so if a regeneration ever starts naming them the
        # claim above has changed meaning and this must be revisited - `persist`
        # in particular holds per-unit calibration that cannot be regenerated.
        assert builtins.all (
          name: !(builtins.hasAttr name huaweiMariePartitions.partitions)
        ) (builtins.attrNames deviceProfiles.huawei-marie.storage.outsideReconstructedTable);
        assert huaweiMarieFirmware.deviceTreeEvidence.exactMarTargetAvailable == true;
        # The device tree found in the firmware must be the board the profile
        # recorded, and must not be selected by the non-portable runtime index.
        assert huaweiMarieFirmware.deviceTreeEvidence.overlay.selected.boardId
        == huaweiMarieBoot.target.board.id;
        assert huaweiMarieFirmware.deviceTreeEvidence.overlay.selected.matchesProfile.boardName
        == huaweiMarieBoot.target.board.name;
        assert huaweiMarieFirmware.deviceTreeEvidence.runtimeIndexIsNotPortable.deviceReported
        == huaweiMarieBoot.target.board.dtboIndex;
        assert huaweiMarieFirmware.deviceTreeEvidence.runtimeIndexIsNotPortable.thisBoardIndexIn563
        != huaweiMarieBoot.target.board.dtboIndex;
        assert huaweiMarieFirmware.bootContainers.exact == true;
        assert huaweiMarieFirmware.bootContainers.kernel.header.version == 1;
        assert huaweiMarieFirmware.bootContainers.kernel.wrapperBytes == 4096;
        assert huaweiMarieFirmware.bootContainers.ramdiskSideCommon.headerVersion == 0;
        assert huaweiMarieFirmware.bootContainers.ramdiskSideCommon.wrapperBytes == 0;
        # No stock payload may claim more room than its partition has. Catches a
        # regenerated partitions.nix that shrinks a boot-side slot.
        assert builtins.all (
          name:
            builtins.getAttr name huaweiMarieFirmware.bootContainers.stockOccupiedBytes
            + huaweiMarieFirmware.bootContainers.avbTailOverheadBytes
            <= (builtins.getAttr name huaweiMariePartitions.partitions).sizeKiB * 1024
        ) (builtins.attrNames huaweiMarieFirmware.bootContainers.stockOccupiedBytes);
        assert huaweiMarieFirmware.avbChain.exact == true;
        assert huaweiMarieFirmware.avbChain.rollbackIndexesAllZero == true;
        assert huaweiMarieFirmware.avbChain.signingPossible == false;
        # Every boot-side digest was recomputed from the payload and every image
        # carries the key its root pins for that partition.
        assert builtins.all (
          d: d.recomputed == true && d.embeddedKeyMatchesPin == true
        ) (builtins.attrValues huaweiMarieFirmware.avbChain.hashDescriptors);
        # Recovery and normal boot share `kernel`; erecovery shares nothing with
        # either. This is what makes erecovery the softest first write.
        assert huaweiMarieBoot.stockBootPaths.recovery.sharesKernelWithNormal == true;
        assert huaweiMarieBoot.stockBootPaths.erecovery.sharesKernelWithNormal == false;
        assert huaweiMarieBoot.stockBootPaths.onlyPathIndependentOfKernelPartition == "erecovery";
        assert builtins.all (
          p: !(builtins.elem p huaweiMarieBoot.stockBootPaths.erecovery.needs)
        )
        huaweiMarieBoot.preferredFirstTarget.leavesIntact;
        assert huaweiMarieBoot.preferredFirstTarget.path == "erecovery";
        assert huaweiMarieBoot.initrdSlotCapacity.ramdisk.viableForMobileNixos == false;
        assert huaweiMarieBoot.initrdSlotCapacity.erecovery_ramdisk.viableForMobileNixos == true;
        assert huaweiMarieBoot.target.recoveryFallback.sharesNoPartitionWithOtherPaths == true;
        assert huaweiMarieBoot.target.recoveryFallback.independenceFullyVerified == false;
        assert builtins.all (b: b == true) (builtins.attrValues huaweiMarieBoot.blockers);
        assert huaweiMarieBoot.complete == false;
        assert huaweiMarieBoot.missingEvidence.exactPartitionSizes == false;
        assert huaweiMarieBoot.missingEvidence.exactDeviceTreeTargets == false;
        assert huaweiMarieBoot.missingEvidence.kernelContainerFormat == false;
        assert huaweiMarieBoot.missingEvidence.ramdiskContainerFormat == false;
        assert huaweiMarieBoot.missingEvidence.ramdiskCompression == false;
        assert huaweiMarieBoot.missingEvidence.avbSigningChain == false;
        assert huaweiMarieBoot.mobileNixos.compatible == false;
        # Mobile NixOS's default initrd compression happens to be what stock
        # uses, so the split scaffold needs no recompression step.
        assert huaweiMarieBoot.mobileNixos.initrdOutput.defaultCompression
        == huaweiMarieFirmware.bootContainers.ramdiskSideCommon.compression;
        assert huaweiMarieBoot.splitOutputScaffold.resolvedFormats.ramdiskCompression
        == huaweiMarieFirmware.bootContainers.ramdiskSideCommon.compression;
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
        # A boot set for this device is four partitions, not two: the kernel is a
        # bare Image.gz, so `dts` and `dto` are boot dependencies even though
        # nothing here writes them. Assert the pair is declared, that the overlay
        # resolves by board ID, and that the ID is the one the boot contract
        # targets -- the runtime `dtbo_idx` addresses a different board in the
        # firmware package this port was reconstructed from.
        assert huaweiMarieSplitFixture.contract.deviceTrees.base.partition == "dts";
        assert huaweiMarieSplitFixture.contract.deviceTrees.overlay.partition == "dto";
        assert huaweiMarieSplitFixture.contract.deviceTrees.overlay.selectedBy == "board-id";
        assert huaweiMarieSplitFixture.contract.deviceTrees.overlay.boardId
        == huaweiMarieBoot.target.board.id;
        assert huaweiMarieFirmware.deviceTreeEvidence.base.carriesBoardIdentity == false;
        # The claim in boot-contract.nix `deviceTreesEveryPathConsumes`: neither
        # device tree is chained by, or hash-described in, any of the three AVB
        # roots. Checked against every root rather than just `vbmeta`.
        assert huaweiMarieBoot.stockBootPaths.deviceTreesEveryPathConsumes.coveredByAnyAvbRoot
        == false;
        assert builtins.all (
          name:
            !(builtins.elem name (
              builtins.attrNames huaweiMarieFirmware.avbChain.hashDescriptors
              ++ builtins.concatMap (
                root: builtins.attrNames root.chainedPartitions
              ) (builtins.attrValues huaweiMarieFirmware.avbChain.roots)
            ))
        )
        huaweiMarieBoot.stockBootPaths.deviceTreesEveryPathConsumes.partitions;
        assert huaweiMarieFirmware.deviceTreeEvidence.runtimeIndexIsNotPortable.boardAtThatIndexIn563
        != huaweiMarieBoot.target.board.id;
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
      system: let
        pkgs = pkgsFor system;
      in {
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
