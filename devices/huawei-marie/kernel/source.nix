{ fetchurl }:

let
  sourceEvidence = import ./source-evidence.nix;
in
fetchurl {
  pname = "huawei-marie-open-source";
  version = "EMUI10.0.0-2020-04-14";
  url = "https://download-c1.huawei.com/download/downloadCenter?downloadId=00F0B9BD37CB1EA9A7FB19BE5533765F&version=A042679BF17C7E3C87722835F6D1383C&siteCode=worldwide";
  hash = "sha256-mRdZwcML6LC4XtH6+yvdhEzvKdgsS/+tRGTuCl9E3xE=";

  passthru = {
    inherit sourceEvidence;
    defconfig = "Code_Opensource/kernel/arch/arm64/configs/merge_kirin710_defconfig";
    defconfigSha256 = "ff92640a274167b03baf3758e85df1a325b13880b2c8228b42c710b6d38d5e76";
    resolvedConfigSha256 = "72c9005eca79f426fbbd44c368f742acb8a89846db17bedc358792b5e268fdd1";
    observedConfigSha256 = "39e8fe7311c7af288e344fa1b98315597e57ca5fee3f1c250dc16b265a379bf3";
    partitionTable = "Code_Opensource/kernel/include/linux/hisi/libra_partition.h";
    partitionTableSha256 = "3724ec918433ccd927c5458e14c58a19ff6ea9da6e792c891ede33ca00d3b7d6";
    buildInstructions = "Code_Opensource/README_Kernel.txt";
    buildInstructionsSha256 = "93296aa7b7e9cc33e76d885ad79c5f431742b5c5f4d9180e6949410198c4cfb0";
    versionInstructions = "Code_Opensource/README_Version.txt";
    versionInstructionsSha256 = "8386674ed92277031d5fb636116d5751742150634429186a1277b88e2f98115c";
  };
}
