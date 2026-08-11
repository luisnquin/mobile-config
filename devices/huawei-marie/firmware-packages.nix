{
  fetchurl,
  python3,
  runCommand,
  unzip,
  writeShellApplication,
}: let
  firmware = import ./firmware.nix;
  fetchArtifact = artifact:
    fetchurl {
      name = artifact.fileName;
      inherit (artifact) url hash;
    };
  cust = fetchArtifact firmware.artifacts.cust;
  preload = fetchArtifact firmware.artifacts.preload;

  # Non-exact bases. The observed `.564` is published nowhere, so these exist to
  # supply a device tree, partition geometry, boot container layouts and the AVB
  # topology. They are never a restore path: a restore has to reproduce the exact
  # bytes `.564` signed. Not an AVB rollback matter - see firmware.nix `avbChain`,
  # where every parsed vbmeta carries `rollbackIndex = 0`.
  baseCandidate = name: candidate:
    fetchurl {
      name = "huawei-marie-base-candidate-${name}.zip";
      inherit (candidate) url hash;
    };
  candidates = firmware.artifacts.base.publicIndexAudit.candidates;
  report = builtins.toJSON {
    cust = {
      storePath = toString cust;
      version = firmware.observed.cust;
    };
    preload = {
      storePath = toString preload;
      version = firmware.observed.preload;
    };
  };
in {
  huawei-marie-firmware-inspect = writeShellApplication {
    name = "huawei-marie-firmware-inspect";
    runtimeInputs = [python3];
    text = ''
      exec python3 ${./tools/inspect-ota.py} "$@"
    '';
    meta.description = "Inspect a Huawei OTA ZIP or UPDATE.APP without extracting it";
  };

  huawei-marie-firmware-extract = writeShellApplication {
    name = "huawei-marie-firmware-extract";
    runtimeInputs = [python3];
    text = ''
      exec python3 ${./tools/extract-ota-packet.py} "$@"
    '';
    meta.description = "Extract named packets from a Huawei OTA ZIP or UPDATE.APP";
  };

  huawei-marie-firmware-index-decode = writeShellApplication {
    name = "huawei-marie-firmware-index-decode";
    runtimeInputs = [python3];
    text = ''
      exec python3 ${./tools/decode-firmware-index.py} "$@"
    '';
    meta.description = "Decode and query a Huawei firmwards.hash firmware index dataset";
  };

  huawei-marie-stock-cust = cust;
  huawei-marie-stock-preload = preload;
  huawei-marie-base-candidate-563 = baseCandidate "563" candidates.nearestVersion;
  huawei-marie-base-candidate-514 = baseCandidate "514" candidates.closestSameRegion;
  huawei-marie-stock-audit =
    runCommand "huawei-marie-stock-audit.json" {
      nativeBuildInputs = [unzip];
    } ''
      test "$(unzip -p ${cust} VERSION.mbn)" = '${firmware.observed.cust}'
      test "$(unzip -p ${preload} VERSION.mbn)" = '${firmware.observed.preload}'
      unzip -p ${cust} UPDATE.APP > /dev/null
      unzip -p ${preload} UPDATE.APP > /dev/null
      printf '%s\n' '${report}' > "$out"
    '';
}
