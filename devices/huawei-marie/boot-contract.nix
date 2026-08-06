let
  firmware = import ./firmware.nix;
  sourceEvidence = import ./kernel/source-evidence.nix;
  sizes = firmware.partitionGeometryCandidate.sizesKiB;
in
{
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
    requiredBeforeInstantiation = [
      "exact kernel partition capacity"
      "exact ramdisk partition capacity"
      "accepted kernel container format"
      "accepted ramdisk container format"
      "accepted ramdisk compression"
    ];
    requiredBeforeUse = [
      "bootloader unlock"
      "bootloader image acceptance evidence"
      "coherent AVB plan"
      "exact stock restore artifacts"
    ];
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
      };
      recovery_vendor = {
        role = "recovery-vendor";
        sizeKiB = sizes.recoveryVendor;
      };
      dts = {
        role = "device-tree";
        sizeKiB = sizes.dts;
      };
      dto = {
        role = "device-tree-overlay";
        sizeKiB = sizes.dto;
      };
      vbmeta = {
        role = "verified-boot-metadata";
        sizeKiB = sizes.vbmeta;
      };
    };
  };

  missingEvidence = {
    exactStockBase = true;
    exactPartitionSizes = true;
    kernelContainerFormat = true;
    ramdiskContainerFormat = true;
    ramdiskCompression = true;
    exactDeviceTreeTargets = true;
    avbSigningChain = true;
    acceptedBootloaderCommand = true;
  };
}
