{
  description = "Mobile NixOS ports for phones and tablets";

  # Mobile NixOS is not a flake. Consumed as a source tree and given its own
  # `system`, it uses the Nixpkgs it pins under npins/, which is the one every
  # device here was validated against.
  inputs.mobile-nixos = {
    url = "github:mobile-nixos/mobile-nixos/2c132754323fc1915e8d21dcfc0ef68ab084c6fb";
    flake = false;
  };

  outputs =
    { self, mobile-nixos }:
    let
      devices = {
        xiaomi-dandelion = ./devices/xiaomi-dandelion;
      };

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

      pkgsFor = system: import "${mobile-nixos}/pkgs.nix" { inherit system; };

      # Android boot header v2 is not expressible upstream, and dandelion's
      # bootloader rejects v0 and v1. A patch fails loudly; an overlay would
      # silently no-op.
      mobileNixosFor =
        system:
        (pkgsFor system).applyPatches {
          name = "mobile-nixos-patched";
          src = mobile-nixos;
          patches = [ ./patches/mobile-nixos/0001-android-bootimg-header-v2.patch ];
        };

      # `system` must be explicit: Mobile NixOS otherwise falls back to
      # `builtins.currentSystem`, which pure flake evaluation forbids.
      evalFor =
        system: device: configuration:
        import (mobileNixosFor system) {
          inherit system configuration;
          device = devices.${device};
        };

      outputsFor =
        system: device:
        let
          eval = evalFor system device { };
        in
        {
          "${device}-boot-img" = eval.outputs.android.android-bootimg;
          "${device}-recovery-img" = eval.outputs.android.android-recovery;
          "${device}-fastboot-images" = eval.outputs.android.android-fastboot-images;
          "${device}-kernel" = eval.config.mobile.boot.stage-1.kernel.package;
        };
    in
    {
      lib = { inherit devices evalFor; };

      packages = forEachSystem (
        system:
        builtins.foldl' (acc: device: acc // outputsFor system device) { } (
          builtins.attrNames devices
        )
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
