let
  firmware = import ./firmware.nix;
  sourceEvidence = import ./kernel/source-evidence.nix;
  sizes = firmware.partitionGeometry.sizesKiB;
  containers = firmware.bootContainers;
  table = (import ./partitions.nix).partitions;
in {
  complete = false;

  mobileNixos = {
    revision = "2c132754323fc1915e8d21dcfc0ef68ab084c6fb";
    systemType = "android";
    implementation = {
      bootImage = "modules/system-types/android/bootimg.nix";
      outputs = "modules/system-types/android/default.nix";
    };
    producedLayout = "combined-mkbootimg";
    initrdOutput = {
      option = "mobile.outputs.initrd";
      format = "compressed-cpio";
      defaultCompression = "gzip";
      exactStockCompatibility = false;
    };
    generatedFastbootTargets = [
      "boot"
      "recovery"
    ];
    compatible = false;
  };

  sourceDeviceTree = sourceEvidence;

  splitOutputScaffold = {
    implementation = "devices/huawei-marie/split-images.nix";
    instantiated = false;
    producedLayout = "huawei-split";
    producedFiles = [
      "kernel"
      "ramdisk"
      "manifest.json"
    ];
    copiesInputsByteForByte = true;
    requiresCapacityAndFormatEvidence = true;
    includesFlashCommands = false;
    # Capacities and formats are now known exactly, so what remains before
    # instantiation is a kernel and an initrd to feed it.
    requiredBeforeInstantiation = [
      "a built aarch64 kernel image for this board"
      "a built Mobile NixOS initrd"
    ];
    requiredBeforeUse = [
      "bootloader unlock"
      "bootloader image acceptance evidence"
      "coherent AVB plan"
      "exact stock restore artifacts"
    ];
    # The scaffold's `kernelFormat`/`ramdiskFormat` options can now be pinned
    # from evidence rather than guessed.
    resolvedFormats = {
      kernelFormat = "huawei-wrapper";
      ramdiskFormat = "huawei-wrapper";
      ramdiskCompression = "gzip";
    };
  };

  # Three independent verified-boot roots, from firmware.nix `avbChain`. Which
  # partitions each root needs decides what a write breaks and what survives.
  stockBootPaths = {
    normal = {
      root = "vbmeta";
      needs = ["kernel" "ramdisk"];
      kernelContainer = "huawei-wrapper + android boot header v1";
      initrdContainer = "android boot header v0, gzip newc cpio";
      initrdIsFullRoot = false;
    };
    recovery = {
      root = "recovery_vbmeta";
      # Shares the `kernel` partition with normal boot; there is no
      # recovery_kernel partition and no such packet in the base.
      needs = ["kernel" "recovery_ramdisk" "recovery_vendor"];
      sharesKernelWithNormal = true;
      initrdIsFullRoot = true;
    };
    erecovery = {
      root = "erecovery_vbmeta";
      needs = ["erecovery_kernel" "erecovery_ramdisk" "erecovery_vendor"];
      sharesKernelWithNormal = false;
      initrdIsFullRoot = true;
    };
    # Writing `kernel` moves normal boot and recovery together. Only erecovery
    # names none of the partitions the other two name.
    onlyPathIndependentOfKernelPartition = "erecovery";

    # `needs` above lists what each AVB root covers, which is not the same as
    # what a boot consumes. Every path also consumes the device trees, and the
    # kernel is a bare Image.gz with nothing appended, so it cannot boot without
    # them. They are recorded separately because they behave differently: no
    # root chains them and no root carries a hash descriptor for either, so AVB
    # says nothing about their contents at all - verified against every entry of
    # all three roots. Consequences, in both directions: a device-tree write
    # needs no re-signing and invalidates no vbmeta, unlike `kernel` (chained
    # under `vbmeta` at index 1, with a recomputed descriptor); and their
    # integrity is therefore guaranteed by nothing this port can inspect, so a
    # bad write here is not caught by verified boot, it just fails to boot.
    # `flashLocked` still gates writing them.
    deviceTreesEveryPathConsumes = {
      partitions = ["dts" "dto"];
      coveredByAnyAvbRoot = false;
      baseCarriesBoardIdentity = false;
      overlayResolvedBy = "board-id";
    };
  };

  # Where a Mobile NixOS initrd can physically go. `ramdisk` is 2 MiB in total,
  # which no Mobile NixOS initrd fits, so the port cannot use the normal boot
  # path's initrd slot at all. The two recovery-class slots are 32 MiB each and
  # stock already stores a complete root filesystem in them.
  initrdSlotCapacity = {
    ramdisk = {
      capacityBytes = table.ramdisk.sizeKiB * 1024;
      stockOccupiedBytes = containers.stockOccupiedBytes.ramdisk;
      viableForMobileNixos = false;
      reason = "2 MiB total; a Mobile NixOS initrd is an order of magnitude larger";
    };
    recovery_ramdisk = {
      capacityBytes = table.recovery_ramdisk.sizeKiB * 1024;
      stockOccupiedBytes = containers.stockOccupiedBytes.recovery_ramdisk;
      viableForMobileNixos = true;
      reason = "32 MiB, and stock already stores a full root here";
    };
    erecovery_ramdisk = {
      capacityBytes = table.erecovery_ramdisk.sizeKiB * 1024;
      # Byte-identical to recovery_ramdisk in stock.
      stockOccupiedBytes = containers.stockOccupiedBytes.recovery_ramdisk;
      viableForMobileNixos = true;
      reason = "32 MiB, and its boot path needs no partition the other two need";
    };
  };

  # The softest first write, and the reason the whole erecovery slot was
  # mapped. erecovery is the only path whose partitions are all its own, and it
  # is sized identically to recovery, kernel included. Writing it leaves both
  # Android normal boot and Android recovery bit-for-bit intact, so two
  # independent routes back survive a failed attempt. Taking the recovery path
  # instead would mean writing `kernel`, which normal boot also loads, and one
  # write would then take out both Android paths at once.
  preferredFirstTarget = {
    path = "erecovery";
    writes = {
      erecovery_kernel = table.erecovery_kernel.sizeKiB * 1024;
      erecovery_ramdisk = table.erecovery_ramdisk.sizeKiB * 1024;
    };
    leavesIntact = ["kernel" "ramdisk" "recovery_ramdisk" "recovery_vendor"];
    survivingAndroidPaths = ["normal" "recovery"];
    # What it costs: the stock emergency-OTA path, and entry depends on a
    # bootloader command this repository has not established.
    sacrifices = ["stock erecovery function"];
    blockedBy = ["bootloader unlock" "acceptedBootloaderCommand"];
  };

  observedAvb = {
    version = "1.1";
    state = "green";
    deviceState = "locked";
    hashAlgorithm = "sha256";
    vbmetaDigest = "f92b36af6c26afbd654fa19a73d96cac4639294ed08dc5836e02e4f5653bde5e";
    huaweiVbmetaDigest = "ad5ccc965d280aceab5ffcddc03f3168dd4e369eef49731d8095e34f3fe812a2";
    vbmetaSizeBytes = 27264;
    invalidateOnError = true;
    verifiedPartitionPropertyValues = {
      cust = 2;
      hw_product = 2;
      odm = 2;
      preas = 2;
      preavs = 2;
      preload = 2;
      system = 2;
      vendor = 2;
      version = 2;
    };
  };

  researchLeads.communityRecovery = {
    source = "https://github.com/Iceows/shrp_android_device_huawei_marie/tree/a0f7d9227d6c15d80ed4227b2aaf8cfc6d36c4bc";
    revision = "a0f7d9227d6c15d80ed4227b2aaf8cfc6d36c4bc";
    inspectedAt = "2026-08-05";
    exactStockProof = false;
    buildModel = {
      container = "mkbootimg";
      kernelBytes = 0;
      kernelSha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
      ramdiskCompression = "gzip";
      configuredBootImagePageSize = 2048;
      configuredRecoverySizeBytes = 33554432;
      configuredAvbKey = "AOSP test RSA-4096 key";
      configuredSecurityPatch = "2099-12-31";
    };
    targetAmbiguity = {
      aboutMetadataClaimsAb = true;
      liveSlotPropertiesAvailable = false;
      androidRecoveryAlias = "kernel";
      shrpRecoveryDevice = "erecovery_ramdisk";
    };
    usableAsFlashContract = false;
  };

  target = {
    layout = "huawei-split";
    board = {
      id = 7829;
      name = "MAR_LX3m_VF";
      hardwareVersion = "HL5MARM";
      # Reported by the build that was installed at collection time. It is not a
      # portable address: in `.563` entry 26 is board 7408 and this board is at
      # 329. Anything selecting an overlay must match on `id` above.
      dtboIndex = 26;
    };
    observedAliases = {
      boot = "kernel";
      recovery = "kernel";
    };
    partitions = {
      kernel = {
        role = "kernel";
        sizeKiB = sizes.kernel;
        observedBlockDevice = "/dev/block/sdd44";
      };
      ramdisk = {
        role = "normal-initrd";
        sizeKiB = sizes.ramdisk;
        observedBlockDevice = "/dev/block/sdd17";
      };
      recovery_ramdisk = {
        role = "recovery-initrd";
        sizeKiB = sizes.recoveryRamdisk;
        observedBlockDevice = "/dev/block/sdd46";
      };
      recovery_vendor = {
        role = "recovery-vendor";
        sizeKiB = sizes.recoveryVendor;
        observedBlockDevice = "/dev/block/sdd47";
      };
      dts = {
        role = "device-tree";
        sizeKiB = sizes.dts;
        observedBlockDevice = "/dev/block/sdd48";
      };
      dto = {
        role = "device-tree-overlay";
        sizeKiB = sizes.dto;
        observedBlockDevice = "/dev/block/sdd49";
      };
      vbmeta = {
        role = "verified-boot-metadata";
        sizeKiB = sizes.vbmeta;
        observedBlockDevice = "/dev/block/sdd57";
      };
    };

    # erecovery is a full second recovery slot, not a reduced one, and it is
    # structurally independent: its own kernel partition, its own ramdisk, its
    # own vendor overlay and its own signed vbmeta root, sized identically to
    # recovery throughout. In stock each payload is byte-identical to the image
    # it shadows - note that its kernel mirrors the normal-boot `kernel`,
    # because no recovery kernel partition exists to mirror.
    recoveryFallback = {
      partitions = {
        erecovery_kernel = {
          sizeKiB = table.erecovery_kernel.sizeKiB;
          observedBlockDevice = "/dev/block/sdd41";
          stockMirrorOf = "kernel";
        };
        erecovery_ramdisk = {
          sizeKiB = table.erecovery_ramdisk.sizeKiB;
          observedBlockDevice = "/dev/block/sdd42";
          stockMirrorOf = "recovery_ramdisk";
        };
        erecovery_vendor = {
          sizeKiB = table.erecovery_vendor.sizeKiB;
          observedBlockDevice = "/dev/block/sdd43";
          stockMirrorOf = "recovery_vendor";
        };
        erecovery_vbmeta = {
          sizeKiB = table.erecovery_vbmeta.sizeKiB;
          observedBlockDevice = "/dev/block/sdd56";
          stockMirrorOf = null;
        };
      };
      mirrorsRecoveryInStock = true;
      sharesNoPartitionWithOtherPaths = true;
      evidence = "firmware.nix candidates.nearestVersion.erecoveryMirrorsRecovery, avbChain.roots.erecovery_vbmeta";
      # See avbChain.erecoveryDescriptorNameMismatch: because the payloads are
      # byte-identical, each carries a hash descriptor naming the partition it
      # was copied from. Independence is proven at the partition and vbmeta
      # level, inferred at the descriptor-resolution level.
      independenceFullyVerified = false;
    };
  };

  missingEvidence = {
    exactStockBase = true;

    # Retired by firmware.nix `partitionGeometry`: the full 67-entry UFS table,
    # agreeing with the running unit's block-device slots, four padded payload
    # lengths and the published kernel header.
    exactPartitionSizes = false;

    # Retired by firmware.nix `bootContainers`, parsed from the `.563` payloads:
    # a 4096-byte Huawei wrapper around an Android boot header v1 for `kernel`,
    # a bare header v0 for the three ramdisk-side images, pageSize 2048
    # throughout, gzipped newc cpio in all three.
    kernelContainerFormat = false;
    ramdiskContainerFormat = false;
    ramdiskCompression = false;

    # Retired by firmware.nix `deviceTreeEvidence`: board 7829's DTBO overlay
    # plus the kirin710 base DTB. Note `sourceDeviceTree` still reports no MAR
    # target, which stays true - that is the published kernel source, and this
    # evidence came out of the firmware instead.
    exactDeviceTreeTargets = false;

    # Retired by firmware.nix `avbChain`: three roots, thirteen plus six chained
    # partitions with their rollback index locations, a distinct pinned key per
    # partition class, and all four boot-side hash descriptors recomputed and
    # matched. The topology is no longer unknown. What blocks a signed write is
    # not missing evidence but a missing key, tracked below.
    avbSigningChain = false;

    acceptedBootloaderCommand = true;
  };

  # Separate from `missingEvidence`, because no further research closes these.
  blockers = {
    # firmware.nix `avbChain.signingPossible`. Every partition's required key is
    # known; none of the private halves is obtainable.
    noPrivateSigningKey = true;
    # Whether the bootloader accepts an unsigned or self-signed image once
    # unlocked is unobserved, and observing it needs the unlock first.
    bootloaderAcceptanceUnobserved = true;
    # Gate 1. Every free Kirin 710 unlock route is version-locked below the
    # running EMUI, so this is a hardware and tooling decision, not a research
    # one.
    bootloaderLocked = true;
  };
}
