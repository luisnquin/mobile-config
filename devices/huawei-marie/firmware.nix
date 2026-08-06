{
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
        auditedAt = "2026-08-05";
        revision = "a511283e6e13c2a25da82e722e92e3704671f17d";
        source = "https://github.com/ProfessorJTJ/professorjtj.github.io/tree/a511283e6e13c2a25da82e722e92e3704671f17d";
        datasets = [
          "normal"
          "base-archive"
          "downgrade"
        ];
        exactMatch = false;
        closestSameRegion = {
          indexRomId = 594102;
          version = "MAR-LGRP2-OVS 10.0.0.514";
          region = "hw-la";
          restoreCompatible = false;
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

  partitionGeometryCandidate = {
    exact = false;
    source = "MAR_10_EMUI10.0.0: Code_Opensource/kernel/include/linux/hisi/libra_partition.h";
    storage = "UFS";
    sizesKiB = {
      ramdisk = 2 * 1024;
      kernel = 24 * 1024;
      recoveryRamdisk = 32 * 1024;
      recoveryVendor = 16 * 1024;
      dts = 8 * 1024;
      dto = 24 * 1024;
      recoveryVbmeta = 2 * 1024;
      erecoveryVbmeta = 2 * 1024;
      vbmeta = 4 * 1024;
    };
  };
}
