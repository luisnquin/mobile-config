{
  description = "Mobile NixOS port for the Xiaomi Redmi 9A (dandelion, MT6765)";

  # Mobile NixOS is not a flake. It is consumed as a plain source tree and given
  # its own `system`, which makes it use the Nixpkgs it pins itself under
  # `npins/`. That is deliberate: this port was validated against exactly that
  # Nixpkgs, and adding a second, independent `nixpkgs` input here would let the
  # two drift apart silently.
  inputs.mobile-nixos = {
    url = "github:mobile-nixos/mobile-nixos/2c132754323fc1915e8d21dcfc0ef68ab084c6fb";
    flake = false;
  };

  outputs =
    { self, mobile-nixos }:
    let
      # Hosts that can produce an aarch64 image. x86_64 cross-compiles.
      buildSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forEachSystem =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) buildSystems
        );

      # Mobile NixOS' own entry point to its pinned Nixpkgs. Used here only to
      # get `applyPatches`; the eval below builds its own package set.
      pkgsFor = system: import "${mobile-nixos}/pkgs.nix" { inherit system; };

      # Android boot header v2 is not expressible in upstream Mobile NixOS, and
      # dandelion's bootloader will not accept a v0 or v1 image. Patching the
      # source tree is the honest way to say so: the patch is reviewable, and it
      # cannot silently stop applying the way an overlay can silently no-op.
      mobileNixosFor =
        system:
        (pkgsFor system).applyPatches {
          name = "mobile-nixos-dandelion";
          src = mobile-nixos;
          patches = [ ./patches/mobile-nixos/0001-android-bootimg-header-v2.patch ];
        };

      # `configuration` is whatever you would otherwise put in `local.nix`.
      # Passing `system` explicitly matters: Mobile NixOS falls back to
      # `builtins.currentSystem`, which pure flake evaluation forbids.
      evalFor =
        system: configuration:
        import (mobileNixosFor system) {
          inherit system configuration;
          device = ./devices/xiaomi-dandelion;
        };
    in
    {
      # Escape hatch for consumers that want their own configuration on top:
      #   (dandelion.lib.evalFor "x86_64-linux" ./my-config.nix).outputs
      lib = { inherit evalFor; };

      packages = forEachSystem (
        system:
        let
          eval = evalFor system { };
        in
        {
          # The image that has actually been booted on hardware. It is flashed
          # to `recovery`, not `boot`; see README.
          default = eval.outputs.android.android-bootimg;
          boot-img = eval.outputs.android.android-bootimg;

          android-recovery = eval.outputs.android.android-recovery;
          fastboot-images = eval.outputs.android.android-fastboot-images;

          kernel = eval.config.mobile.boot.stage-1.kernel.package;
        }
      );

      devShells = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.android-tools
              pkgs.dtc
              pkgs.python3
            ];
          };
        }
      );
    };
}
