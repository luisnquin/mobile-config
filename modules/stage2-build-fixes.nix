# Build fixes for packages that only enter the closure through stage-2. The
# boot image never evaluated these, so they first failed when
# `config.mobile.outputs.generatedFilesystems.rootfs` was built.
#
#   gadget-tool  CMakeLists.txt:1 says `cmake_minimum_required(VERSION 3.0)`.
#                nixpkgs' cmake is 4.x, which removed the <3.5 compatibility
#                path outright: "Compatibility with CMake < 3.5 has been removed
#                from CMake." The pinned upstream is a bare revision with no
#                releases (mobile-nixos/overlay/gt @ 7f9c45d9), so the
#                policy escape hatch is the fix rather than a version bump.
#
#                It is not optional: mobile-nixos/modules/adb.nix:64
#                runs `gt enable $gadget` in the stage-2 adbd service, which is
#                this port's only access channel once stage-1 hands over.
#
#   redis        src/Makefile lists `module_tests` in `all`, and `install`
#                depends on `all`, so a plain build compiles the test fixtures
#                in tests/modules -- whose Makefile hardcodes `CC = gcc` under a
#                comment calling itself "a hack to override the default CC".
#                There is no `gcc` on a cross build's PATH, only the prefixed
#                compiler, so every fixture fails with `gcc: command not found`
#                and takes the build down with it. Nothing installed depends on
#                them; `make test` keeps its own dependency on the target and is
#                not run anyway, because nixpkgs drops doCheck when the build
#                platform cannot execute the host platform.
#
# `mkAfter` is load-bearing. Mobile NixOS defines its own `gadget-tool` in
# mobile-nixos/overlay/overlay.nix:44, and its overlay is appended after
# the ones contributed by device modules. An unordered overlay here is silently
# discarded -- the derivation hash does not move and the same build failure
# repeats. Verified by probing each entry of `config.nixpkgs.overlays`:
# ours defined `gadget-tool`, and so did the Mobile NixOS overlay two positions
# later.
{ lib, ... }:

{
  nixpkgs.overlays = lib.mkAfter [
    (final: prev: {
      gadget-tool = prev.gadget-tool.overrideAttrs (old: {
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
      });

      redis = prev.redis.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/Makefile \
            --replace-fail '$(TLS_MODULE) module_tests' '$(TLS_MODULE)'
        '';
      });
    })
  ];
}
