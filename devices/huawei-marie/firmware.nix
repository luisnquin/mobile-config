let
  partitionTable = import ./partitions.nix;
in {
  complete = false;

  observed = {
    build = "MAR-L03B 10.0.0.564(C605E6R1P1)";
    base = "MAR-LGRP2-OVS 10.0.0.564";
    cust = "MAR-L03B-CUST 10.0.0.6(C605)";
    preload = "MAR-L03B-PRELOAD 10.0.0.1(C605R1)";
    operator = "ENTEL.PE 10.0.0.1(CT)";
  };

  artifacts = {
    base = {
      available = false;
      version = "MAR-LGRP2-OVS 10.0.0.564";
      publicIndexAudit = {
        auditedAt = "2026-08-10";
        revision = "a511283e6e13c2a25da82e722e92e3704671f17d";
        source = "https://github.com/ProfessorJTJ/professorjtj.github.io/tree/a511283e6e13c2a25da82e722e92e3704671f17d";
        decoder = "tools/decode-firmware-index.py";
        datasets = [
          "normal"
          "base-archive"
          "downgrade"
          "v2"
        ];
        exactMatch = false;

        # `v2` carries model -> (base, cust, preload) tuples but no CDN
        # locations, so it can only prove a build exists. It confirms this
        # unit's tuple exactly, which rules out a transcription error in
        # `observed` as the reason the artifact cannot be found.
        buildConfirmedByV2 = {
          model = "MAR-L03B";
          region = "C605";
          gbcGroup = "hw-la";
          tuple = [
            "MAR-LGRP2-OVS 10.0.0.564"
            "MAR-L03B-CUST 10.0.0.6(C605)"
            "MAR-L03B-PRELOAD 10.0.0.1(C605R1)"
          ];
          downloadable = false;
          latestForRegion = true;
        };

        # Neither candidate is the observed `.564`. Both are usable as device
        # tree, partition-geometry and container evidence, never as a restore
        # artifact: they are older builds, and a restore has to reproduce the
        # exact bytes `.564` signed. Not for AVB rollback reasons - every
        # vbmeta in `.563` carries `rollbackIndex = 0`, see `avbChain`.
        #
        # A base package is region-independent; region lives in CUST/PRELOAD.
        # A dataset row's region is the region of that *row*, so `.563` reads
        # as `hw-eea` while its own `filelist.xml` declares `hw-la` too.
        candidates = {
          nearestVersion = {
            indexRomId = 638956;
            indexDataset = "normal";
            indexRow = "MAR-L01B - C431 (hw-eea)";
            version = "MAR-LGRP2-OVS 10.0.0.563";
            releaseDate = "2022-07-05";
            versionsBehindObserved = 1;
            declaredGbcGroups = [
              "hw-eu"
              "hw-jp"
              "hw-ca"
              "vodacom-za"
              "hw-meafnaf"
              "hw-ru"
              "hw-cea"
              "hw-spcseas"
              "hw-eea"
              "iusacell-mx"
              "hw-la"
              "other"
            ];
            fileName = "update_full_base.zip";
            fileListUrl = "http://update.dbankcdn.com/download/data/pub_13/HWHOTA_hota_900_9/87/v3/MusNp0g5QOy-M29YWERUSA/full/filelist.xml";
            url = "http://update.dbankcdn.com/download/data/pub_13/HWHOTA_hota_900_9/87/v3/MusNp0g5QOy-M29YWERUSA/full/update_full_base.zip";
            size = 3199648722;
            hash = "sha256-xIU7oNIgJTDMqMdsl0cGN6E+Mab5+lm/J5VqMlj22G4=";
            downloaded = true;
            restoreCompatible = false;

            # Hashes computed from the fetched archive, independently of the
            # fixed-output check, by tools/inspect-ota.py.
            localVerification = {
              inspectedAt = "2026-08-10";
              declaredVersion = "MAR-LGRP2-OVS 10.0.0.563";
              zipSha256 = "c4853ba0d2202530cca8c76c97470637a13e31a6f9fa59bf27956a3258f6d86e";
              updateAppSha256 = "ff001adddd4f436e153648c5e8e784df3d7406d8c9f594502360470b97646394";
              updateAppSize = 3895734896;
              packetCount = 44;
              zipCrcVerified = true;
              # Every packet header carries this, ASCII "HW7x27" then 0xffff.
              hardwareId = "485737783237ffff";
              # The header's name field is sixteen bytes, so longer names are
              # truncated in place: ERECOVERY_RAMDIS, VBMETA_HW_PRODUC.
              packetNamesTruncatedAt = 16;
              # No RECOVERY_KERNEL packet exists, and `partitions.nix` has no
              # such partition. Recovery boots the `kernel` partition; only
              # erecovery carries its own copy.
              recoveryKernelPacketPresent = false;
            };

            # Packets this candidate was inspected for. `sha256` is the payload,
            # matching what tools/extract-ota-packet.py writes out. Every packet
            # in the archive was hashed, so the identities below are exhaustive.
            evidencePackets = {
              HISIUFS_GPT = {
                size = 200704;
                sha256 = "229ee3d6c9f0b31acef06f68a0a49aa6baa62837f094cb41a23617cb60620b4e";
                yields = "partitions.nix";
              };
              DTO = {
                size = 14253952;
                sha256 = "80ac5babf8df92fa67a8b59d069fcd45227b930b487608609691942416cae9ef";
                yields = "deviceTreeEvidence.overlay";
              };
              DTS = {
                size = 102400;
                sha256 = "a0ce8fd3ac8d80625bdc8a8047d3a9b8e46492b29cd9834b3c12eda4c2d79b81";
                yields = "deviceTreeEvidence.base";
              };
              KERNEL = {
                size = 25165824;
                sha256 = "4e66f43989d235de062d57e1e6cc13d754cb6223f9e01f4ad1fb7a1241f8d5e0";
                yields = "bootContainers.kernel";
              };
              RAMDISK = {
                size = 2097152;
                sha256 = "8f46991d6f6eca846423f2cc34b5faec30203b72ed84743984a98b5b1790dd00";
                yields = "bootContainers.ramdisk";
              };
              RECOVERY_RAMDISK = {
                size = 33554432;
                sha256 = "aa1e8cbfa56803db377b4180923fafd60d47b790d605e0cda6c240811138a378";
                yields = "bootContainers.recovery_ramdisk";
              };
              RECOVERY_VENDOR = {
                size = 16777216;
                sha256 = "df827b440717ca605882424a66627920b54295224322441c90855c7f710320ae";
                yields = "bootContainers.recovery_vendor";
              };
              VBMETA = {
                size = 16384;
                sha256 = "6e4b88363ccf6506125bdfde6b14cc1a10e4ca0e93e484408868dfc29b804e48";
                yields = "avbChain.roots.vbmeta";
              };
              RECOVERY_VBMETA = {
                size = 7104;
                sha256 = "0d3d2e8761a6229b622974b1e346332dcc68db773736fc954cad3160c0618820";
                yields = "avbChain.roots.recovery_vbmeta";
              };
              ERECOVERY_VBMETA = {
                size = 7104;
                sha256 = "b4425c0d990297777a433ce935dd97b08e9521c676dd3358b5bb348b6518068b";
                yields = "avbChain.roots.erecovery_vbmeta";
              };
            };

            # In `.563` each erecovery payload is byte-identical to the payload
            # it shadows, and only the vbmeta differs. Note what erecovery's
            # kernel mirrors: the normal-boot `kernel`, because there is no
            # recovery kernel to mirror.
            erecoveryMirrorsRecovery = {
              mirrors = {
                ERECOVERY_KERNEL = "KERNEL";
                ERECOVERY_RAMDIS = "RECOVERY_RAMDISK";
                ERECOVERY_VENDOR = "RECOVERY_VENDOR";
              };
              kernelSha256 = "4e66f43989d235de062d57e1e6cc13d754cb6223f9e01f4ad1fb7a1241f8d5e0";
              ramdiskSha256 = "aa1e8cbfa56803db377b4180923fafd60d47b790d605e0cda6c240811138a378";
              vendorSha256 = "df827b440717ca605882424a66627920b54295224322441c90855c7f710320ae";
              vbmetaDiffers = true;
            };
          };

          closestSameRegion = {
            indexRomId = 594102;
            indexDataset = "base-archive";
            indexRow = "MAR-L03B - C605 (hw-la)";
            version = "MAR-LGRP2-OVS 10.0.0.514";
            releaseDate = "2021-10-21";
            versionsBehindObserved = 50;
            newestWithSameRegionRow = true;
            declaredGbcGroups = [
              "hw-la"
              "tigo-la"
              "other"
            ];
            fileName = "update_full_base.zip";
            fileListUrl = "http://update.dbankcdn.com/download/data/pub_13/HWHOTA_hota_900_9/9/v3/SvU6LxS0T4ybUPd8kJOd7g/full/filelist.xml";
            url = "http://update.dbankcdn.com/download/data/pub_13/HWHOTA_hota_900_9/9/v3/SvU6LxS0T4ybUPd8kJOd7g/full/update_full_base.zip";
            size = 3178550002;
            hash = "sha256-B0r9sxfbOAWKuIzu2n78HWK4IQnOl/L14QiogJZm0JY=";
            downloaded = false;
            restoreCompatible = false;
          };
        };
      };
    };

    cust = {
      available = true;
      indexRomId = 467371;
      fileName = "update_full_cust_MAR-L03B_hw_la.zip";
      fileListUrl = "https://update.dbankcdn.com/download/data/pub_13/HWHOTA_hotaMigrate_900_9/53/v3/6979fda4f3fb451b8e0959f629b82052/full/filelist.xml";
      url = "https://update.dbankcdn.com/download/data/pub_13/HWHOTA_hotaMigrate_900_9/53/v3/6979fda4f3fb451b8e0959f629b82052/full/update_full_cust_MAR-L03B_hw_la.zip";
      size = 24360;
      hash = "sha256-Vl0H/vcq+eZM9eNMikzNgqO23gTixGfFWpM9YBs/4AY=";
    };

    preload = {
      available = true;
      indexRomId = 396408;
      fileName = "update_full_preload_MAR-L03B_hw_la_R1.zip";
      fileListUrl = "https://update.dbankcdn.com/download/data/pub_13/HWHOTA_hotaMigrate_900_9/c7/v3/1aeb73a3d177453fb8a08c1c1091b2df/full/filelist.xml";
      url = "https://update.dbankcdn.com/download/data/pub_13/HWHOTA_hotaMigrate_900_9/c7/v3/1aeb73a3d177453fb8a08c1c1091b2df/full/update_full_preload_MAR-L03B_hw_la_R1.zip";
      size = 134819498;
      hash = "sha256-/9XchlOy3/D3z3KjghmkWog+NG2pKgCscMPis7qwr7Q=";
    };
  };

  # Recovered from the `.563` base package's HISIUFS_GPT packet, which holds
  # three GPT copies describing one geometry two ways: a 71-entry table in
  # 512-byte LBAs, and a 67-entry table in 4096-byte LBAs whose spans are
  # therefore exactly an eighth as large in blocks and identical in bytes. The
  # 67-entry variant drops frp, persist, reserved1 and reserved6.
  partitionGeometry = {
    exact = true;
    storage = "UFS";
    source = "candidates.nearestVersion evidencePackets.HISIUFS_GPT, 67-entry variant";
    table = "partitions.nix";
    inherit (partitionTable) logicalBlockBytes entryCount;

    # Three independent agreements, none of which shares an input with another.
    validation = {
      # `profile.nix` recorded fourteen /dev/block names from the running unit.
      # Every one lands on its own name's entry slot in the 67-entry variant, so
      # this is the unit's layout and not a family template. The 71-entry
      # variant is uniformly four slots higher and matches none of them.
      deviceEntrySlots = {
        checked = 14;
        matched = 14;
        variantOffsetIfWrongTable = 4;
      };

      # Huawei pads these four payloads out to the full partition, so their
      # packet lengths are the partition sizes. All four equal the GPT span.
      paddedPayloads = {
        kernel = 25165824;
        ramdisk = 2097152;
        recovery_ramdisk = 33554432;
        recovery_vendor = 16777216;
      };

      # The nine sizes previously carried here, taken from the published kernel
      # source, all agree with the GPT.
      openSourceHeader = {
        path = "MAR_10_EMUI10.0.0: Code_Opensource/kernel/include/linux/hisi/libra_partition.h";
        valuesChecked = 9;
        disagreements = 0;
      };
    };

    # DTS, DTO and both VBMETA payloads are stored unpadded, so their packet
    # lengths say nothing about partition capacity. Only the GPT does.
    unpaddedPayloads = [
      "DTS"
      "DTO"
      "VBMETA"
      "RECOVERY_VBMETA"
      "ERECOVERY_VBMETA"
    ];

    # The table comes from `.563` while the unit runs `.564`. The slot match is
    # device-side evidence of composition and ordering, not of sizes, so a
    # resize between the two builds would not show up here. Reading the unit's
    # own GPT would close this; it needs only adb, not an unlocked bootloader.
    residualRisk = "derived from .563, not the running .564";

    sizesKiB = {
      ramdisk = partitionTable.partitions.ramdisk.sizeKiB;
      kernel = partitionTable.partitions.kernel.sizeKiB;
      recoveryRamdisk = partitionTable.partitions.recovery_ramdisk.sizeKiB;
      recoveryVendor = partitionTable.partitions.recovery_vendor.sizeKiB;
      dts = partitionTable.partitions.dts.sizeKiB;
      dto = partitionTable.partitions.dto.sizeKiB;
      recoveryVbmeta = partitionTable.partitions.recovery_vbmeta.sizeKiB;
      erecoveryVbmeta = partitionTable.partitions.erecovery_vbmeta.sizeKiB;
      vbmeta = partitionTable.partitions.vbmeta.sizeKiB;
    };
  };

  # The published kernel source ships no MAR device tree; the firmware does. The
  # DTO packet is a 4096-byte Huawei wrapper around a standard Android DTBO
  # container holding 367 gzipped overlays, keyed by board ID.
  deviceTreeEvidence = {
    exactMarTargetAvailable = true;
    source = "candidates.nearestVersion evidencePackets";

    overlay = {
      container = "android-dtbo";
      magic = "0xd7b7ab1e";
      wrapperBytes = 4096;
      entryCount = 367;
      idsUnique = true;

      # Selection is by board ID. 7829 occurs exactly once in the table, and
      # that entry's own fragment for this board matches all four identity
      # fields `profile.nix` recorded, independently confirming them.
      selected = {
        boardId = 7829;
        tableIndex = 329;
        gzippedBytes = 45298;
        fdtBytes = 462100;
        fragment = 157;
        matchesProfile = {
          boardName = "MAR_LX3m_VF";
          hardwareVersion = "HL5MARM";
          productName = "MAR-LX3m";
          # `hisi,boardid` stores the board ID as one decimal digit per cell.
          boardIdDigits = [7 8 2 9];
        };
      };

      # Each entry carries `hisi,dtbo_idx` equal to its own table index, and a
      # family-wide board descriptor table. So MAR_LX3m_VF also appears in the
      # entries for boards 7958 and 7886; only 7829 is this unit.
      selfDeclaredIndexEqualsTableIndex = true;
      otherEntriesNamingThisBoard = [7958 7886];
    };

    base = {
      wrapperBytes = 10240;
      compression = "gzip";
      fdtBytes = 483477;
      model = "kirin710";
      compatible = "hisilicon,kirin710";
      carriesBoardIdentity = false;
    };

    # `profile.nix` records `boot.dtboIndex = 26` from `ro.boot.dtbo_idx`, which
    # is the index the bootloader selected in the DTO installed on this unit.
    # In `.563` index 26 is board 7408, an unrelated STK model, and board 7829
    # sits at 329. Both records are right; the index is per-build and is not a
    # portable selector. Select by board ID.
    runtimeIndexIsNotPortable = {
      deviceReported = 26;
      boardAtThatIndexIn563 = 7408;
      thisBoardIndexIn563 = 329;
    };
  };

  # Container layout of the four boot-side payloads, read out of the `.563`
  # packets. Huawei does not use one combined boot image: the kernel and the
  # ramdisk are two separate, separately signed Android boot images, which is
  # why Mobile NixOS's combined `mkbootimg` output cannot satisfy this device.
  bootContainers = {
    exact = true;
    source = "candidates.nearestVersion evidencePackets";

    kernel = {
      partition = "kernel";
      # The first 4096 bytes are a Huawei wrapper, not part of the boot image
      # and not covered by AVB. Its only content is the ASCII name "kernel"
      # repeated three times in an otherwise near-empty structure.
      wrapperBytes = 4096;
      wrapperNonZeroBytes = 1738;
      header = {
        magic = "ANDROID!";
        version = 1;
        size = 1648;
        pageSize = 2048;
        kernelSize = 18661866;
        kernelAddr = 3145728;
        ramdiskSize = 0;
        ramdiskAddr = 3120562176;
        secondSize = 0;
        tagsAddr = 3128950784;
        # 0x1400014a: Android 10.0.0, security patch level 2020-10.
        osVersion = 335544650;
        name = "";
        recoveryDtboSize = 0;
        recoveryDtboOffset = 0;
      };
      payload = {
        offset = 6144;
        compression = "gzip";
      };
      # No `console=`, so a serial console has to be added deliberately.
      cmdline = "loglevel=4 page_tracker=on unmovable_isolate1=2:192M,3:224M,4:256M printktimer=0xfff0a000,0x534,0x538 androidboot.selinux=enforcing buildvariant=user";
      carriesRamdisk = false;
    };

    # The three ramdisk-side images share one shape: header version 0 at offset
    # zero, no Huawei wrapper, no kernel, gzipped newc cpio at 2048.
    ramdiskSideCommon = {
      wrapperBytes = 0;
      headerMagic = "ANDROID!";
      headerVersion = 0;
      pageSize = 2048;
      kernelSize = 0;
      kernelAddr = 268468224;
      ramdiskAddr = 285212672;
      tagsAddr = 268435712;
      osVersion = 335544650;
      payloadOffset = 2048;
      compression = "gzip";
      archive = "newc-cpio";
    };

    ramdisk = {
      partition = "ramdisk";
      compressedBytes = 796503;
      uncompressedBytes = 1827840;
      cpioEntries = 11;
      cmdline = "buildvariant=user";
      # A minimal Android 10 first-stage ramdisk, nothing more.
      topLevel = ["apex" "cache" "debug_ramdisk" "dev" "eng" "init" "mnt" "patch_avb_key" "patch_hw" "proc" "sys"];
    };

    recovery_ramdisk = {
      partition = "recovery_ramdisk";
      compressedBytes = 27962135;
      uncompressedBytes = 65640704;
      cpioEntries = 1957;
      cmdline = "buildvariant=user";
      # A complete recovery root: its own init.rc, sepolicy, fstabs and
      # /system, so this is the full second system, not an initrd stub.
      carriesFullRoot = true;
    };

    recovery_vendor = {
      partition = "recovery_vendor";
      compressedBytes = 11313251;
      uncompressedBytes = 28586496;
      cpioEntries = 221;
      cmdline = "";
      # Overlaid onto the recovery root; every path is under /vendor.
      topLevel = ["vendor"];
    };

    # How much of each partition stock actually occupies, AVB image size plus
    # any unsigned wrapper. The capacities are in `partitions.nix`; a
    # replacement gets the whole partition, not just what is unused here.
    # `ramdisk` is the number that decides the port target: the partition is
    # 2 MiB total, so a Mobile NixOS initrd cannot go there at all.
    stockOccupiedBytes = {
      kernel = 4096 + 18665472;
      ramdisk = 798720;
      recovery_ramdisk = 27965440;
      recovery_vendor = 11317248;
    };
    # AVB adds an embedded vbmeta and a 64-byte footer at the partition tail,
    # so a replacement cannot use the last few KiB either.
    avbTailOverheadBytes = 2048;
  };

  # The verified-boot topology, read out of the three vbmeta packets. Every
  # figure below was parsed from the images, and each boot-side image's own
  # embedded key was checked against the key its parent pins.
  avbChain = {
    exact = true;
    toolRelease = "avbtool 1.1.0";
    algorithm = "SHA256_RSA2048";
    publicKeyBlobBytes = 520;

    # There is no rollback protection in force anywhere: every vbmeta parsed,
    # top-level and per-partition, carries `rollbackIndex = 0`. The locations
    # exist and are assigned, but all indices are zero, so a downgrade is not
    # blocked by AVB. It is blocked by the bootloader lock instead.
    rollbackIndexesAllZero = true;
    vbmetasParsed = 7;

    # Three independent roots, each its own signed vbmeta with its own key.
    roots = {
      vbmeta = {
        partition = "vbmeta";
        packetBytes = 16384;
        descriptorsBytes = 8136;
        # Pure chaining - no hash or hashtree descriptor at this level.
        chainedPartitions = {
          kernel = 1;
          vbmeta_system = 2;
          vbmeta_vendor = 3;
          ramdisk = 4;
          vbmeta_odm = 5;
          version = 6;
          vbmeta_hw_product = 7;
          vbmeta_cust = 8;
          eng_vendor = 9;
          eng_system = 10;
          preload = 11;
          preas = 19;
          preavs = 20;
        };
      };

      recovery_vbmeta = {
        partition = "recovery_vbmeta";
        packetBytes = 7104;
        descriptorsBytes = 1888;
        # Recovery reuses the normal-boot `kernel` partition under the same
        # rollback index location, so touching `kernel` moves recovery too.
        chainedPartitions = {
          kernel = 1;
          recovery_ramdisk = 17;
          recovery_vendor = 18;
        };
      };

      erecovery_vbmeta = {
        partition = "erecovery_vbmeta";
        packetBytes = 7104;
        descriptorsBytes = 1896;
        # Names no partition that normal boot or recovery names.
        chainedPartitions = {
          erecovery_kernel = 25;
          erecovery_ramdisk = 26;
          erecovery_vendor = 27;
        };
      };
    };

    # Keys are per partition class, not one key for everything. Identifiers are
    # the first 16 hex digits of sha256 over the 520-byte blob.
    pinnedKeyClasses = {
      "b9fa2383a09e7b20" = ["kernel" "ramdisk" "erecovery_kernel"];
      "725d717afa3fb841" = ["recovery_ramdisk" "erecovery_ramdisk"];
      "7283bf37e95c8f27" = ["recovery_vendor" "erecovery_vendor"];
      "d756490f2ff0beac" = ["version" "vbmeta_hw_product" "vbmeta_cust"];
      "70df8070d9aca17e" = ["preas" "preavs"];
      "32e54a8ef0efc1de" = ["vbmeta_system"];
      "85a44352c0abe54e" = ["vbmeta_vendor"];
      "36a7ebd03a685a63" = ["vbmeta_odm"];
      "75e0a84f08a14f3b" = ["eng_vendor"];
      "5616c8cb53678b57" = ["eng_system"];
      "d4c81fde4f27fd7d" = ["preload"];
    };

    # Each root's own signing key, verified by the bootloader against a key
    # this repository cannot read. That check is the only unverified link.
    rootKeys = {
      vbmeta = "36f6331c4a7a5d49";
      recovery_vbmeta = "56a3bc0b6f2a797f";
      erecovery_vbmeta = "d404d21309294dfe";
    };

    # Each boot-side image carries an AVBf footer in its last 64 bytes and an
    # embedded vbmeta. All four digests were recomputed here as
    # sha256(salt ++ image[avbRegionStart .. avbRegionStart + imageSize]) and
    # all four matched, and each image's embedded key equals the key its parent
    # pins for that partition. So the chain is proven from every root down to
    # the bytes.
    hashDescriptors = {
      kernel = {
        # AVB coverage starts after the Huawei wrapper, which is unsigned.
        avbRegionStart = 4096;
        imageSize = 18665472;
        salt = "dc45c533da95bfc754ad9bfe63745b784ac7141cbb9265f2293f81efcef66b74";
        digest = "4f956d4a968789a088ed5c9e4df749060042e1fa9956dfb0fab3e46183f807b2";
        recomputed = true;
        embeddedKeyMatchesPin = true;
        # The only property descriptor anywhere in the four.
        properties."com.android.build.boot.os_version" = "10";
      };
      ramdisk = {
        avbRegionStart = 0;
        imageSize = 798720;
        salt = "9f1ac9c11a672bd5cba30ee5391288445fd16a14d64350b2ffad8bc63bb5fec3";
        digest = "6b6a1c455f87cad8fa3de081fa3b1438bbf9ab25631452a5a8ca87260ccfcd38";
        recomputed = true;
        embeddedKeyMatchesPin = true;
      };
      recovery_ramdisk = {
        avbRegionStart = 0;
        imageSize = 27965440;
        salt = "28909d0817f4529fb1acf6cb714ffaaaf79446902f96ee924aac487f76ad2e1a";
        digest = "a900ca60bccaa466ee0ce364dc845216032b946a6a1e6617ed9a22f2b34a0817";
        recomputed = true;
        embeddedKeyMatchesPin = true;
      };
      recovery_vendor = {
        avbRegionStart = 0;
        imageSize = 11317248;
        salt = "54a8a2ca707dc8fd398366289a43e0068af9b4713475ea5ce7ebd23e5fab6e65";
        digest = "5bd307c5891e9701bc631af471af2c0f156220f543fed4babfb2014f1cc47d90";
        recomputed = true;
        embeddedKeyMatchesPin = true;
      };
    };

    # Each erecovery payload is byte-identical to the image it shadows, so the
    # hash descriptor inside it names that image's partition rather than the
    # erecovery one its parent chained. Whether Huawei's bootloader resolves a
    # descriptor name to the partition it loaded or to the literal name is not
    # observable from the firmware. The consistency of the pattern across all
    # three argues for the former, since the latter would make erecovery
    # verify recovery's partitions and defeat its purpose. Treated as an
    # inference, not a fact.
    erecoveryDescriptorNameMismatch = {
      affects = ["erecovery_kernel" "erecovery_ramdisk" "erecovery_vendor"];
      resolutionVerified = false;
    };

    # Nothing here supplies a private key. The chain says exactly which key
    # must sign each partition; it does not make signing possible.
    signingPossible = false;
  };
}
