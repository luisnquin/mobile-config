{
  observed = {
    source = "/proc/config.gz";
    collectedAt = "2026-08-05T19:30:46Z";
    compressedBytes = 36364;
    compressedSha256 = "ff6169b5e7c56825160e587649f2de37d23e909f9c755d3dba3e12ac12fd4082";
    decompressedLines = 6142;
    decompressedSha256 = "39e8fe7311c7af288e344fa1b98315597e57ca5fee3f1c250dc16b265a379bf3";
  };

  officialDefconfig = {
    path = "Code_Opensource/kernel/arch/arm64/configs/merge_kirin710_defconfig";
    lines = 6124;
    sha256 = "ff92640a274167b03baf3758e85df1a325b13880b2c8228b42c710b6d38d5e76";
  };

  sourceVsObserved = {
    exact = false;
    sourceOnly = [
      "# CONFIG_CRYPTO_RSA is not set"
      "# CONFIG_HISEE_SUPPORT_INSE_ENCRYPT is not set"
      "# CONFIG_MODULE_SIG is not set"
      "# CONFIG_SYSTEM_DATA_VERIFICATION is not set"
      "# CONFIG_SYSTEM_TRUSTED_KEYRING is not set"
    ];
    observedOnly = [
      "# CONFIG_DM_ANDROID_VERITY is not set"
      "# CONFIG_HUAWEI_MINCORE_CLASSIC is not set"
      "# CONFIG_MODULE_SIG_SHA1 is not set"
      "# CONFIG_MODULE_SIG_SHA224 is not set"
      "# CONFIG_MODULE_SIG_SHA256 is not set"
      "# CONFIG_MODULE_SIG_SHA384 is not set"
      "# CONFIG_PKCS7_TEST_KEY is not set"
      "# CONFIG_SECONDARY_TRUSTED_KEYRING is not set"
      "# CONFIG_SIGNED_PE_FILE_VERIFICATION is not set"
      "# CONFIG_SYSTEM_EXTRA_CERTIFICATE is not set"
      "CONFIG_CRYPTO_RSA=y"
      "CONFIG_GENERAL_SEE_PINCODE=y"
      "CONFIG_HISEE_SUPPORT_INSE_ENCRYPT=y"
      "CONFIG_MODULE_SIG=y"
      "CONFIG_MODULE_SIG_ALL=y"
      "CONFIG_MODULE_SIG_FORCE=y"
      "CONFIG_MODULE_SIG_HASH=\"sha512\""
      "CONFIG_MODULE_SIG_KEY=\"huawei_signing_key.pem\""
      "CONFIG_MODULE_SIG_SHA512=y"
      "CONFIG_SYSTEM_DATA_VERIFICATION=y"
      "CONFIG_SYSTEM_TRUSTED_KEYRING=y"
      "CONFIG_SYSTEM_TRUSTED_KEYS=\"\""
      "CONFIG_UNIX_SCM=y"
    ];
  };

  resolvedDefconfig = {
    makeTarget = "merge_kirin710_defconfig";
    sha256 = "72c9005eca79f426fbbd44c368f742acb8a89846db17bedc358792b5e268fdd1";
    lines = 6064;
    adaptations = [
      "replace vendor /bin/pwd with the pinned Coreutils path"
      "use pinned Nixpkgs Clang only to build host Kconfig tools"
    ];
    targetCompilerUsed = false;
    addedAssignments = [];
    droppedAssignments = [
      "# CONFIG_CONTEXTHUB_SWING is not set"
      "# CONFIG_CONTEXTHUB_SWING_DBG is not set"
      "# CONFIG_CORESIGHT is not set"
      "# CONFIG_HISILICON_PLATFORM_TELE_MNTN is not set"
      "# CONFIG_HISI_DDRC_KERNEL_CODE_PROTECTION is not set"
      "# CONFIG_HISI_DPM_PLATFORM_EARTH is not set"
      "# CONFIG_HISI_DPM_PLATFORM_JUPITER is not set"
      "# CONFIG_HISI_DPM_PLATFORM_MERCURY is not set"
      "# CONFIG_HISI_DPM_PLATFORM_NEPTUNE is not set"
      "# CONFIG_HISI_DPM_PLATFORM_PLUTO is not set"
      "# CONFIG_HISI_DPM_PLATFORM_SATURN is not set"
      "# CONFIG_HISI_DPM_PLATFORM_URANUS is not set"
      "# CONFIG_HISI_DPM_PLATFORM_VENUS is not set"
      "# CONFIG_HISI_ENABLE_MIDEA_MONITOR is not set"
      "# CONFIG_HISI_FREQDUMP_PLATFORM_VENUS is not set"
      "# CONFIG_HISI_LPM3_DEBUG is not set"
      "# CONFIG_HISI_NPU_PM is not set"
      "# CONFIG_HISI_PERF_STAT is not set"
      "# CONFIG_HISI_PERF_STAT64 is not set"
      "# CONFIG_HISI_PMU_DUMP is not set"
      "# CONFIG_HISI_TCPC is not set"
      "# CONFIG_HISI_USB_TYPEC is not set"
      "# CONFIG_HISI_WATCHPOINT_CB is not set"
      "# CONFIG_HUAWEI_EIMA_ACCESS_CONTROL is not set"
      "# CONFIG_HUAWEI_ENG_EIMA is not set"
      "# CONFIG_HUAWEI_ROOT_SCAN_DUMMY_API is not set"
      "# CONFIG_NPU_DEVDRV is not set"
      "# CONFIG_SND_SOC_CODEC_STUB is not set"
      "# CONFIG_TEE_ANTIROOT_CLIENT_ENG_DEBUG is not set"
      "CONFIG_GATOR=m"
      "CONFIG_HISI_DPM_PLATFORM_MARS=y"
      "CONFIG_HISI_FREQDUMP_PLATFORM=y"
      "CONFIG_HUAWEI_EIMA=y"
      "CONFIG_HW_ROOT_SCAN_RODATA_MEASUREMENT_API=y"
      "CONFIG_TEE_ANTIROOT_CLIENT=y"
      "CONFIG_TEE_KERNEL_MEASUREMENT_API=y"
    ];
  };

  buildFeasibility = {
    configGenerationWorks = true;
    configGenerationReproducible = true;
    exactStockConfig = false;
    exactClangPackaged = true;
    exactClangIdentityVerified = true;
    androidGcc49CandidatePackaged = true;
    androidGcc49ExactIdentityKnown = false;
    productionModuleSigningKeyAvailable = false;
    exactStockEquivalentKernelReady = false;
    candidateKernelBuild = {
      complete = true;
      builtAt = "2026-08-06";
      output = "arch/arm64/boot/Image.gz";
      sha256 = "d3b8569c4bfbe5ef6ffc280a59ab049ecb1e1f065207ea48c5bbafc069d1efd4";
      sizeBytes = 18523241;
      # Against the 24 MiB `kernel` candidate, which is itself unconfirmed.
      fitsCandidateKernelCapacity = true;
      stockEquivalent = false;
      bootProven = false;
    };
  };
}
