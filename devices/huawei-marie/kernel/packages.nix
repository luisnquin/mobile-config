{
  bc,
  bison,
  clang,
  coreutils,
  cpio,
  fetchzip,
  fetchurl,
  file,
  findutils,
  flex,
  gnugrep,
  gnumake,
  gnutar,
  gzip,
  lib,
  openssl,
  patch,
  patchelf,
  perl,
  python3,
  rsync,
  runCommand,
  stdenv,
  which,
  zlib,
}:

let
  source = import ./source.nix { inherit fetchurl; };
  toolchainSources = import ./toolchains.nix { inherit fetchzip; };
  configComparison = import ./config-comparison.nix;
  toolchainRuntimePath = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    zlib
  ];
  prepareToolchain =
    name: sourcePackage:
    runCommand name {
      nativeBuildInputs = [
        file
        findutils
        patchelf
        python3
      ];
    } ''
      mkdir "$out"
      cp -a ${sourcePackage}/. "$out/"
      chmod -R u+w "$out"
      patchShebangs "$out"

      while IFS= read -r -d $'\0' executable; do
        description="$(file -b "$executable")"
        if grep -Eq 'ELF 64-bit LSB.*executable.*x86-64.*dynamically linked' <<< "$description"; then
          patchelf \
            --set-interpreter '${stdenv.cc.bintools.dynamicLinker}' \
            --set-rpath "${toolchainRuntimePath}:$out/lib64:$out/lib" \
            "$executable"
        elif grep -Eq 'ELF 64-bit LSB shared object, x86-64' <<< "$description"; then
          patchelf \
            --set-rpath "${toolchainRuntimePath}:$out/lib64:$out/lib" \
            "$executable"
        fi
      done < <(find "$out" -type f -print0)
    '';
  clangToolchain = prepareToolchain "android-clang-r346389c" toolchainSources.clang;
  gccToolchain = prepareToolchain "android-aarch64-gcc-4.9" toolchainSources.gcc;
  candidateKernel = runCommand "huawei-marie-kernel-candidate-4.14.116" {
    nativeBuildInputs = [
      bc
      bison
      clang
      cpio
      flex
      gnumake
      gnutar
      gzip
      openssl
      patch
      perl
      python3
      rsync
      stdenv.cc
      which
    ];
  } ''
    mkdir source build "$out"
    tar -xzf ${source} -C source Code_Opensource/kernel
    chmod -R u+w source
    patchShebangs source/Code_Opensource/kernel
    substituteInPlace source/Code_Opensource/kernel/Makefile \
      --replace-fail /bin/pwd ${coreutils}/bin/pwd
    patch -d source/Code_Opensource/kernel -p1 \
      < ${../../../patches/linux/kirin710/0008-selinux-ignore-host-pf-max.patch}

    export HOME="$TMPDIR"
    export KBUILD_BUILD_USER=nix
    export KBUILD_BUILD_HOST=nix
    export KBUILD_BUILD_TIMESTAMP='Thu Jan  1 00:00:01 UTC 1970'
    export LD_LIBRARY_PATH="${toolchainRuntimePath}:${clangToolchain}/lib64:${gccToolchain}/lib"

    makeArgs=(
      -C source/Code_Opensource/kernel
      ARCH=arm64
      O="$PWD/build"
      HOSTCC=${clang}/bin/clang
      HOSTCXX=${clang}/bin/clang++
      HOSTCFLAGS=-O2\ -fcommon
      CLANG_PREBUILTS_PATH=${clangToolchain}/
      CROSS_COMPILE=${gccToolchain}/bin/aarch64-linux-android-
      CLANG_TRIPLE=aarch64-linux-gnu-
    )

    make "''${makeArgs[@]}" merge_kirin710_defconfig
    make -j"$NIX_BUILD_CORES" "''${makeArgs[@]}" Image.gz

    install -m 0444 build/arch/arm64/boot/Image.gz "$out/Image.gz"
    install -m 0444 build/.config "$out/config"
    test "$(stat -c %s "$out/Image.gz")" -le $((24 * 1024 * 1024))
    sha256sum "$out/Image.gz" > "$out/SHA256SUMS"
    stat -c '%s' "$out/Image.gz" > "$out/Image.gz.size"
  '';
  resolvedConfig = runCommand "huawei-marie-kernel-config" {
    nativeBuildInputs = [
      bc
      bison
      clang
      flex
      gnumake
      gnutar
      gzip
      perl
      stdenv.cc
    ];
  } ''
    mkdir source build "$out"
    tar -xzf ${source} -C source Code_Opensource/kernel
    chmod -R u+w source
    substituteInPlace source/Code_Opensource/kernel/Makefile \
      --replace-fail /bin/pwd ${coreutils}/bin/pwd
    make -C source/Code_Opensource/kernel \
      ARCH=arm64 \
      CLANG_PREBUILTS_PATH=${clang}/ \
      O="$PWD/build" \
      merge_kirin710_defconfig
    install -m 0444 build/.config "$out/config"
  '';
  report = builtins.toJSON {
    source = {
      storePath = toString source;
      version = source.version;
      hash = source.outputHash;
    };
    kernel = {
      version = "4.14.116";
      output = "arch/arm64/boot/Image.gz";
      defconfig = source.defconfig;
      defconfigSha256 = source.defconfigSha256;
      observedConfigSha256 = source.observedConfigSha256;
      resolvedConfigSha256 = source.resolvedConfigSha256;
      resolvedConfigStorePath = toString resolvedConfig;
      configComparison = configComparison;
    };
    toolchain = {
      documentedKernelBuild = {
        gcc = "aarch64-linux-android-4.9";
        clang = "r346389c";
      };
      configGeneration = {
        clang = clang.version;
        exactVendorToolchain = false;
        targetCompilerUsed = false;
      };
    };
    partitionTable = {
      path = source.partitionTable;
      sha256 = source.partitionTableSha256;
      storage = "UFS";
      candidateOnly = true;
    };
    deviceTree = source.sourceEvidence.deviceTree;
    sourceEvidence = source.sourceEvidence;
  };
in
{
  huawei-marie-kernel-source = source;
  huawei-marie-kernel-config = resolvedConfig;
  huawei-marie-kernel-candidate = candidateKernel;
  huawei-marie-clang-r346389c = clangToolchain;
  huawei-marie-gcc-4-9 = gccToolchain;

  huawei-marie-kernel-toolchain-audit = runCommand "huawei-marie-kernel-toolchain-audit" {
    nativeBuildInputs = [ gnugrep ];
  } ''
    mkdir "$out"
    ${clangToolchain}/bin/clang --version | tee "$out/clang-version"
    grep -Fq 'Android (5220042 based on r346389c) clang version 8.0.7' "$out/clang-version"
    grep -Fq '${toolchainSources.clang.compilerCommit}' "$out/clang-version"
    grep -Fq '${toolchainSources.clang.llvmCommit}' "$out/clang-version"

    ${gccToolchain}/bin/aarch64-linux-android-gcc --version | tee "$out/gcc-version"
    grep -Fq '(GCC) 4.9.x 20150123' "$out/gcc-version"
  '';

  huawei-marie-kernel-source-audit = runCommand "huawei-marie-kernel-source-audit.json" {
    nativeBuildInputs = [
      coreutils
      gnugrep
      gnutar
      gzip
    ];
  } ''
    extract() {
      tar -xOzf ${source} "$1"
    }

    extract '${source.defconfig}' > defconfig
    test "$(sha256sum defconfig | cut -d ' ' -f 1)" = '${source.defconfigSha256}'
    grep -Fxq '# CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE is not set' defconfig
    test "$(sha256sum ${resolvedConfig}/config | cut -d ' ' -f 1)" = '${source.resolvedConfigSha256}'
    grep -Fxq '# CONFIG_MODULE_SIG is not set' "${resolvedConfig}/config"
    test "$(wc -l < "${resolvedConfig}/config")" = '${toString configComparison.resolvedDefconfig.lines}'

    extract '${source.partitionTable}' > libra_partition.h
    test "$(sha256sum libra_partition.h | cut -d ' ' -f 1)" = '${source.partitionTableSha256}'
    grep -Eq '\{PART_RAMDISK,[[:space:]]*238\*1024,[[:space:]]*2\*1024,[[:space:]]*UFS_PART_3\}' libra_partition.h
    grep -Eq '\{PART_KERNEL,[[:space:]]*522\*1024,[[:space:]]*24\*1024,[[:space:]]*UFS_PART_3\}' libra_partition.h
    grep -Eq '\{PART_RECOVERY_RAMDISK,[[:space:]]*558\*1024,[[:space:]]*32\*1024,[[:space:]]*UFS_PART_3\}' libra_partition.h
    grep -Eq '\{PART_DTS,[[:space:]]*606\*1024,[[:space:]]*8\*1024,[[:space:]]*UFS_PART_3\}' libra_partition.h
    grep -Eq '\{PART_DTO,[[:space:]]*614\*1024,[[:space:]]*24\*1024,[[:space:]]*UFS_PART_3\}' libra_partition.h
    grep -Eq '\{PART_VBMETA,[[:space:]]*724\*1024,[[:space:]]*4\*1024,[[:space:]]*UFS_PART_3\}' libra_partition.h

    extract Code_Opensource/kernel/Makefile > Makefile
    grep -Eq '^VERSION[[:space:]]*=[[:space:]]*4$' Makefile
    grep -Eq '^PATCHLEVEL[[:space:]]*=[[:space:]]*14$' Makefile
    grep -Eq '^SUBLEVEL[[:space:]]*=[[:space:]]*116$' Makefile
    grep -Eq '^export CFG_PLATFORM[[:space:]]*:=[[:space:]]*kirin710$' Makefile

    extract '${source.sourceEvidence.files.architectureMakefile.path}' > arm64-Makefile
    test "$(sha256sum arm64-Makefile | cut -d ' ' -f 1)" = '${source.sourceEvidence.files.architectureMakefile.sha256}'
    grep -Fq '$(build)=$(boot)/dts/auto-generate/config dtbs' arm64-Makefile
    grep -Fq '$(build)=$(boot)/dts/auto-generate/overlay dtbs' arm64-Makefile

    extract '${source.sourceEvidence.files.bootMakefile.path}' > arm64-boot-Makefile
    test "$(sha256sum arm64-boot-Makefile | cut -d ' ' -f 1)" = '${source.sourceEvidence.files.bootMakefile.sha256}'

    extract '${source.sourceEvidence.files.dtsMakefile.path}' > arm64-dts-Makefile
    test "$(sha256sum arm64-dts-Makefile | cut -d ' ' -f 1)" = '${source.sourceEvidence.files.dtsMakefile.sha256}'

    extract '${source.sourceEvidence.files.modemVersion.path}' > modem-version.h
    test "$(sha256sum modem-version.h | cut -d ' ' -f 1)" = '${source.sourceEvidence.files.modemVersion.sha256}'
    grep -Fq '${source.sourceEvidence.familyEvidence.modemProduct}' modem-version.h

    extract '${source.buildInstructions}' > README_Kernel.txt
    test "$(sha256sum README_Kernel.txt | cut -d ' ' -f 1)" = '${source.buildInstructionsSha256}'
    grep -Fq 'clang-r346389c' README_Kernel.txt
    grep -Fq 'aarch64-linux-android-4.9' README_Kernel.txt
    grep -Fq 'out/arch/arm64/boot/Image.gz' README_Kernel.txt

    extract '${source.versionInstructions}' > README_Version.txt
    test "$(sha256sum README_Version.txt | cut -d ' ' -f 1)" = '${source.versionInstructionsSha256}'
    grep -Fq 'phone software version 2020-04-14' README_Version.txt

    tar -tzf ${source} > archive-files
    test "$(grep -Ec '^Code_Opensource/kernel/arch/arm64/boot/dts/.+\.(dts|dtsi)$' archive-files)" = '${toString source.sourceEvidence.deviceTree.dtsAndDtsiFileCount}'
    if grep -Eq '^Code_Opensource/kernel/arch/arm64/boot/dts/auto-generate/' archive-files; then
      exit 1
    fi
    if grep -Ei '^Code_Opensource/kernel/arch/arm64/boot/dts/(.*/)?[^/]*(kirin710|libra|marie)[^/]*\.(dts|dtsi)$' archive-files; then
      exit 1
    fi
    if grep -Ei '^Code_Opensource/kernel/arch/arm64/boot/dts/(.*/)?([^/]*[-_.])?mar([-_.][^/]*)?\.(dts|dtsi)$' archive-files; then
      exit 1
    fi

    printf '%s\n' '${report}' > "$out"
  '';
}
