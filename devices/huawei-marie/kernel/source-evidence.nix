{
  inspectedAt = "2026-08-05";

  files = {
    architectureMakefile = {
      path = "Code_Opensource/kernel/arch/arm64/Makefile";
      sha256 = "47d873409ba66238217469abd1757a5a274896cc2eabe1c6adeda402fbb20b50";
    };
    bootMakefile = {
      path = "Code_Opensource/kernel/arch/arm64/boot/Makefile";
      sha256 = "7fc08c86592f18a017db5aac795548e17f3a78607afb0e3c3839921b38ddfd79";
    };
    dtsMakefile = {
      path = "Code_Opensource/kernel/arch/arm64/boot/dts/Makefile";
      sha256 = "641900ebac89b4b0e693a1b33d47c39b9875f712e4bab8dec5e6c64b42c99af2";
    };
    modemVersion = {
      path = "Code_Opensource/kernel/drivers/hisi/modem/config/product/kirin710/config/product_config_version.h";
      sha256 = "5986d90522720c2cf6275bbe431e0173a6719ca003fb0c11a5789c41a89f84f5";
    };
  };

  kernelOutput = {
    path = "arch/arm64/boot/Image.gz";
    compression = "gzip";
    includesDeviceTree = false;
    appendedDeviceTreeConfig = false;
  };

  deviceTree = {
    sourcePath = "Code_Opensource/kernel/arch/arm64/boot/dts";
    dtsAndDtsiFileCount = 306;
    exactIdentityFilenamePatterns = [
      "kirin710"
      "libra"
      "mar"
      "marie"
    ];
    exactIdentityNamedSource = false;
    generatedInputs = {
      config = "Code_Opensource/kernel/arch/arm64/boot/dts/auto-generate/config";
      overlay = "Code_Opensource/kernel/arch/arm64/boot/dts/auto-generate/overlay";
      presentInArchive = false;
    };
    dtbsTargetSelfContained = false;
    exactMarTargetAvailable = false;
  };

  familyEvidence = {
    modemProduct = "Miami V100R001C20B388";
    runningBaseband = "21C20B388S000C000";
    sharedVersionSegment = "C20B388";
    marLcdEffectHeaderCount = 25;
    supportsKirin710MiamiFamilyMatch = true;
    provesExactMarL03BSourceMatch = false;
  };
}
