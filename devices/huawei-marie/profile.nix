{
  collectedAt = "2026-08-05T20:10:22Z";
  collectionMethod = "authorized read-only adb";

  # A second authorized read-only pass, run to close entries in `unknown` rather
  # than to recollect. Everything it re-read agreed with what is above: the whole
  # `ro.boot.*` set, both vbmeta digests, and /proc/config.gz still hashing to
  # the value `kernel/config-comparison.nix` records. What it added is below,
  # under `storage`, `boot.bootloaderRevision` and `software.customization`.
  reverifiedAt = "2026-08-11";

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
      # `ro.hw.custPath`. The running system resolves its customization through
      # the COTA tree rather than through `cust` directly, which settles whether
      # the C178 layer is optional: it is not, it is the live path. Note the two
      # C-versions are different layers and both are real - C178 identifies the
      # carrier variant here, while the cust and preload *packages* are C605.
      custPath = "/cust/cota/cust/entel/pe";
      hwinitCustExists = false;
      hwinitPreloadExists = false;
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
    relevantDisabled = ["CONFIG_DRM"];
  };

  boot = {
    # Not "not collected" - not exposed. `ro.bootloader` reads the literal string
    # `unknown` and `ro.boot.bootloader` is empty, and no other property in the
    # full `ro.boot.*` set carries a version. So no amount of read-only adb can
    # supply this; it would take `fastboot getvar`, which means rebooting into
    # the bootloader.
    bootloaderRevision = null;
    basebandRevision = "21C20B388S000C000";
    slotSuffix = null;
    slotCount = null;
    dynamicPartitions = true;
    # An index into the dto table of the build that was running when this was
    # collected, and nothing else. It does not address the `.563` table, where
    # entry 26 is board 7408 and this board (7829) sits at 329 - see
    # firmware.nix `deviceTreeEvidence.runtimeIndexIsNotPortable`. Resolve the
    # overlay by boardId, never by this number.
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
      procCmdline = false;
      # Denied per property, not per directory: `ls /proc/device-tree` enumerates
      # node and property *names* fine, while reading any of `model`, `compatible`,
      # `hisi,boardid`, `hisi,boardname`, `hisi,chipid` gives EACCES. Enough to
      # prove which properties exist, never their values.
      flattenedDeviceTree = false;
      deviceTreeNamesEnumerable = true;
      # The one geometry read that works, and how the 67-entry table was
      # confirmed against the unit. Symlink targets only, so no size information.
      blockByNameSymlinks = true;
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
    # Two device trees, not one. `dts` is the base FDT and is SoC-generic:
    # compatible `hisilicon,kirin710`, model `kirin710`, and
    # `carriesBoardIdentity = false`. Every MAR-specific property arrives from
    # the separate AOSP dtbo container in `dto`, which the bootloader indexes by
    # boardId. So a boot definition has to reproduce both, and a base tree alone
    # describes no board this repo cares about.
    dts = "sdd48";
    dto = "sdd49";
    vbmeta = "sdd57";
    super = "sdd64";
    userdata = "sdd67";
  };

  storage = {
    # `partitions.nix` was reconstructed from a firmware package's HISIUFS_GPT
    # packet, so its 67 entries were an inference about this unit until they were
    # read off it. `ls -l /dev/block/by-name` now confirms all 67 names and all
    # 67 slot numbers with no mismatch and nothing extra on either side.
    tableConfirmedOnDevice = true;
    partitionedLuns = ["sdc" "sdd"];
    # The reconstruction covers `sdd` only. These three live on a sibling LUN and
    # appear in no version of the table, so any restore plan built from
    # partitions.nix silently omits them - including `persist`, which is where
    # per-unit calibration lives and is exactly what you cannot regenerate.
    outsideReconstructedTable = {
      frp = "sdc1";
      persist = "sdc2";
      reserved1 = "sdc3";
    };
    # `/sys/block/*/size` and `/proc/partitions` are both denied to the shell
    # domain, so by-name symlinks are the only geometry an unprivileged read
    # gets: names and slots, never sizes.
    lunSizesReadable = false;
  };

  # Only what is still open. Three entries were retired against evidence now in
  # the tree, and are listed here so they are not re-opened: the boot header and
  # wrapper layout (firmware.nix `bootContainers.exact`), the partition table
  # (`partitionGeometry.exact`, 67 entries), and the slot scheme - the table has
  # no `_a`/`_b` name and no complete pair, which is the direct evidence the
  # absent Android properties could not supply. boot-contract.nix
  # `missingEvidence` carries the same retirements with their reasoning.
  unknown = [
    # Narrowed to the unlock path alone. The revision half is not an open
    # question any more, it is an unanswerable one over adb - see
    # `boot.bootloaderRevision`.
    "accepted unlock path"
    "exact MAR-LGRP2-OVS 10.0.0.564 base archive and image hashes"
    # Retired: `software.customization.custPath` shows the live system resolving
    # customization through the COTA tree, so the C178 layer is not an optional
    # decoration on top of a C605 base - it is the path in use.
    # The published source ships `merge_kirin710_defconfig`, an SoC-wide merge
    # with no MAR target in it. It regenerates reproducibly and builds, but 28
    # assignments still differ from the running unit's /proc/config.gz -
    # concentrated in module signing and trusted keyrings - so no configuration
    # here is the stock one.
    "MAR-L03B defconfig; source supplies only the merged kirin710 one"
    # Still open, and now known to be closed to unprivileged reads rather than
    # merely uncollected. The live tree does prove an identity-bearing overlay
    # was applied - its root carries `hisi,boardid` and `hisi,boardname`, which
    # the SoC-generic base does not - but every one of those property values is
    # denied to the shell domain, and the applied tree carries no
    # `hisi,dtbo_idx`. So `ro.boot.dtbo_idx = 26` stays the bootloader's own
    # unverifiable claim, and it does not address the `.563` table.
    "which dto entry the live bootloader selects"
    # Needs fastboot, so it is out of reach of read-only adb by construction.
    "temporary-boot support"
  ];
}
