{
  collectedAt = "2026-08-05T20:10:22Z";
  collectionMethod = "authorized read-only adb";

  identity = {
    manufacturer = "HUAWEI";
    model = "MAR-LX3Bm";
    product = "MAR-LX3Bm";
    androidDevice = "HWMAR";
    board = "MAR";
    boardId = 7829;
    boardName = "MAR_LX3m_VF";
    hardwareVersion = "HL5MARM";
    hardwareSku = "MAR-L03B";
    soc = "kirin710";
    architecture = "aarch64";
    abi = "arm64-v8a";
  };

  software = {
    androidRelease = "10";
    androidSdk = 29;

    androidBuild = {
      displayId = "MAR-L03B 10.0.0.285(C605E5R1P1)";
      fingerprint = "HUAWEI/MAR-LX3Bm/HWMAR:10/HUAWEIMAR-L03B/10.0.0.285C605:user/release-keys";
      buildId = "HUAWEIMAR-L03B";
      incremental = "10.0.0.285C605";
      securityPatch = "2020-08-01";
      baseOsFingerprint = "HUAWEI/MAR-LX3Bm/HWMAR:10/HUAWEIMAR-L03B/10.0.0.251C605:user/release-keys";
    };

    huaweiBuild = {
      displayId = "MAR-L03B 10.0.0.564(C605E6R1P1)";
      fingerprint = "HUAWEI/MAR-LX3Bm/HWMAR:10/HUAWEIMAR-L03B/10.0.0.564C605:user/release-keys";
      incremental = "10.0.0.564C605";
      securityPatch = "2022-04-01";
    };

    components = {
      base = "MAR-LGRP2-OVS 10.0.0.564";
      cust = "MAR-L03B-CUST 10.0.0.6(C605)";
      preload = "MAR-L03B-PRELOAD 10.0.0.1(C605R1)";
      operator = "ENTEL.PE 10.0.0.1(CT)";
    };

    customization = {
      cVersion = "C178";
      dVersion = "D1";
      vendorCountry = "entel/pe";
      region = "la";
    };

    vendor = {
      fingerprint = "kirin710/kirin710/kirin710:10/QP1A.190711.020/root202007311032:user/test-keys";
      securityPatch = "2018-06-19";
    };
  };

  hardware = {
    memoryKiB = 5826156;
    pageSize = 4096;
    screen = {
      width = 1080;
      height = 2312;
    };
    storageController = "ff3c0000.ufs.hi_mci.0";
    stockFilesystems = {
      userdata = {
        type = "f2fs";
        encryption = "aes-256-xts:aes-256-cts";
      };
      cache = "ext4";
      zramBytes = 536870912;
    };
    vendorFstab = {
      path = "/vendor/etc/fstab.kirin710";
      sha256 = "0063d46bf14568150519109f0dfe77136d1d9420d93e96e90b34d5d57193bf1b";
    };
  };

  kernel = {
    release = "4.14.116";
    build = {
      version = "#1 SMP PREEMPT";
      timestamp = "Tue Apr 12 22:13:18 CST 2022";
      clangRevision = "r346389c";
      clangVersion = "8.0.7";
      clangCommit = "b55f2d4ebfd35bf643d27dbca1bb228957008617";
      llvmCommit = "3c393fe7a7e13b0fba4ac75a01aa683d7a5b11cd";
    };
    configAvailableAtProc = true;
    configComparison = import ./kernel/config-comparison.nix;
    relevantBuiltins = [
      "CONFIG_ARM64"
      "CONFIG_BLK_DEV_INITRD"
      "CONFIG_DEVTMPFS"
      "CONFIG_EXT4_FS"
      "CONFIG_F2FS_FS"
      "CONFIG_FB"
      "CONFIG_OVERLAY_FS"
      "CONFIG_SCSI_UFSHCD"
      "CONFIG_SECURITY_SELINUX"
      "CONFIG_TMPFS"
      "CONFIG_USB_CONFIGFS"
      "CONFIG_USB_CONFIGFS_F_FS"
      "CONFIG_USB_CONFIGFS_RNDIS"
      "CONFIG_USB_GADGET"
    ];
    relevantDisabled = [ "CONFIG_DRM" ];
  };

  boot = {
    bootloaderRevision = null;
    basebandRevision = "21C20B388S000C000";
    slotSuffix = null;
    slotCount = null;
    dynamicPartitions = true;
    dtboIndex = 26;
    avbVersion = "1.1";
    verifiedBootState = "green";
    vbmetaDeviceState = "locked";
    vbmeta = {
      digest = "f92b36af6c26afbd654fa19a73d96cac4639294ed08dc5836e02e4f5653bde5e";
      huaweiDigest = "ad5ccc965d280aceab5ffcddc03f3168dd4e369eef49731d8095e34f3fe812a2";
      hashAlgorithm = "sha256";
      sizeBytes = 27264;
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
    flashLocked = true;
    verityMode = "enforcing";
    selinux = "Enforcing";
    shellReadAccess = {
      rawBootPartitions = false;
      sysfsPartitionGeometry = false;
      procPartitions = false;
      flattenedDeviceTree = false;
    };
  };

  partitions = {
    bootAlias = "kernel";
    recoveryAlias = "kernel";
    kernel = "sdd44";
    ramdisk = "sdd17";
    recoveryRamdisk = "sdd46";
    recoveryVendor = "sdd47";
    recoveryVbmeta = "sdd55";
    erecoveryKernel = "sdd41";
    erecoveryRamdisk = "sdd42";
    erecoveryVendor = "sdd43";
    erecoveryVbmeta = "sdd56";
    dts = "sdd48";
    dto = "sdd49";
    vbmeta = "sdd57";
    super = "sdd64";
    userdata = "sdd67";
  };

  unknown = [
    "boot image header and Huawei image wrappers"
    "GPT-confirmed partition sizes; official source only supplies candidates"
    "bootloader revision and accepted unlock path"
    "exact MAR-LGRP2-OVS 10.0.0.564 base archive and image hashes"
    "whether the Entel C178 COTA layer is required for full recovery"
    "kernel source revision and MAR-L03B defconfig"
    "slot scheme; absent Android properties are not proof of non-A/B"
    "temporary-boot support"
  ];
}
