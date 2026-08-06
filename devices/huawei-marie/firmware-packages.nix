{
  fetchurl,
  python3,
  runCommand,
  unzip,
  writeShellApplication,
}:

let
  firmware = import ./firmware.nix;
  fetchArtifact =
    artifact:
    fetchurl {
      name = artifact.fileName;
      inherit (artifact) url hash;
    };
  cust = fetchArtifact firmware.artifacts.cust;
  preload = fetchArtifact firmware.artifacts.preload;
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
in
{
  huawei-marie-firmware-inspect = writeShellApplication {
    name = "huawei-marie-firmware-inspect";
    runtimeInputs = [ python3 ];
    text = ''
      exec python3 ${./tools/inspect-ota.py} "$@"
    '';
    meta.description = "Inspect a Huawei OTA ZIP or UPDATE.APP without extracting it";
  };

  huawei-marie-stock-cust = cust;
  huawei-marie-stock-preload = preload;
  huawei-marie-stock-audit = runCommand "huawei-marie-stock-audit.json" {
    nativeBuildInputs = [ unzip ];
  } ''
    test "$(unzip -p ${cust} VERSION.mbn)" = '${firmware.observed.cust}'
    test "$(unzip -p ${preload} VERSION.mbn)" = '${firmware.observed.preload}'
    unzip -p ${cust} UPDATE.APP > /dev/null
    unzip -p ${preload} UPDATE.APP > /dev/null
    printf '%s\n' '${report}' > "$out"
  '';
}
