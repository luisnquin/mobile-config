{fetchzip}: {
  clang = fetchzip {
    pname = "android-clang";
    version = "r346389c";
    url = "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/3f889f9c9d42bae85728fa89ba5f92a01704fd83/clang-r346389c.tar.gz";
    hash = "sha256-UvqrNXQp7gwovv0RbrK4MfYz6EJ0ZjczWGeZONz2h3M=";
    stripRoot = false;

    passthru = {
      branch = "android10-release";
      repositoryCommit = "3f889f9c9d42bae85728fa89ba5f92a01704fd83";
      subtreeId = "1bb5686fdeb7da8aa19c2213f2a86dfaeb43e440";
      compilerCommit = "b55f2d4ebfd35bf643d27dbca1bb228957008617";
      llvmCommit = "3c393fe7a7e13b0fba4ac75a01aa683d7a5b11cd";
      matchesRunningKernelCompiler = true;
    };
  };

  gcc = fetchzip {
    pname = "android-aarch64-gcc";
    version = "4.9-android10-release";
    url = "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/84fb09fafc92a3d9b4d160f049d46c3c784cc941.tar.gz";
    hash = "sha256-+id2QK891C8dRCcc6XceL0C89GSVjf3ZOgF27RuvKWk=";
    stripRoot = false;

    passthru = {
      branch = "android10-release";
      repositoryCommit = "84fb09fafc92a3d9b4d160f049d46c3c784cc941";
      treeId = "aa53ed1b5448a14f441fc81ced693c73679a4d6f";
      matchesRunningKernelCompiler = null;
    };
  };
}
