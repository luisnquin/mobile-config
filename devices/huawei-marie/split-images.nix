{
  coreutils,
  jq,
  lib,
  runCommand,
}: {
  kernel,
  ramdisk,
  evidence,
  kernelCapacityBytes,
  ramdiskCapacityBytes,
  kernelFormat,
  ramdiskFormat,
  ramdiskCompression,
}:
assert lib.assertMsg (
  builtins.isAttrs evidence
  && lib.all (
    name: builtins.hasAttr name evidence && builtins.isString evidence.${name} && evidence.${name} != ""
  ) [
    "kernelCapacity"
    "kernelFormat"
    "ramdiskCapacity"
    "ramdiskFormat"
  ]
) "evidence must identify the source for each capacity and format";
assert lib.assertMsg (
  builtins.isInt kernelCapacityBytes && kernelCapacityBytes > 0
) "kernelCapacityBytes must be positive";
assert lib.assertMsg (
  builtins.isInt ramdiskCapacityBytes && ramdiskCapacityBytes > 0
) "ramdiskCapacityBytes must be positive";
assert lib.assertMsg (
  builtins.elem kernelFormat [
    "raw-image.gz"
    "huawei-wrapper"
  ]
) "unsupported kernelFormat";
assert lib.assertMsg (
  builtins.elem ramdiskFormat [
    "compressed-cpio"
    "huawei-wrapper"
  ]
) "unsupported ramdiskFormat";
assert lib.assertMsg (
  builtins.elem ramdiskCompression [
    "gzip"
    "xz"
  ]
) "unsupported ramdiskCompression";
  runCommand "huawei-marie-split-images" {
    nativeBuildInputs = [
      coreutils
      jq
    ];
    passthru.contract = {
      inherit
        evidence
        kernelCapacityBytes
        kernelFormat
        ramdiskCapacityBytes
        ramdiskCompression
        ramdiskFormat
        ;
      layout = "huawei-split";
      flashCommandsIncluded = false;
    };
  } ''
    install -D -m 0444 ${lib.escapeShellArg (toString kernel)} "$out/kernel"
    install -D -m 0444 ${lib.escapeShellArg (toString ramdisk)} "$out/ramdisk"

    kernel_size=$(stat -c %s "$out/kernel")
    ramdisk_size=$(stat -c %s "$out/ramdisk")
    test "$kernel_size" -le ${toString kernelCapacityBytes}
    test "$ramdisk_size" -le ${toString ramdiskCapacityBytes}

    kernel_sha256=$(sha256sum "$out/kernel" | cut -d ' ' -f 1)
    ramdisk_sha256=$(sha256sum "$out/ramdisk" | cut -d ' ' -f 1)

    jq -n \
      --arg kernelSha256 "$kernel_sha256" \
      --argjson kernelSize "$kernel_size" \
      --arg kernelFormat ${lib.escapeShellArg kernelFormat} \
      --arg kernelCapacityEvidence ${lib.escapeShellArg evidence.kernelCapacity} \
      --arg kernelFormatEvidence ${lib.escapeShellArg evidence.kernelFormat} \
      --argjson kernelCapacity ${toString kernelCapacityBytes} \
      --arg ramdiskSha256 "$ramdisk_sha256" \
      --argjson ramdiskSize "$ramdisk_size" \
      --arg ramdiskFormat ${lib.escapeShellArg ramdiskFormat} \
      --arg ramdiskCompression ${lib.escapeShellArg ramdiskCompression} \
      --argjson ramdiskCapacity ${toString ramdiskCapacityBytes} \
      --arg ramdiskCapacityEvidence ${lib.escapeShellArg evidence.ramdiskCapacity} \
      --arg ramdiskFormatEvidence ${lib.escapeShellArg evidence.ramdiskFormat} \
      '{
        schema: 1,
        layout: "huawei-split",
        flashCommandsIncluded: false,
        artifacts: {
          kernel: {
            file: "kernel",
            sha256: $kernelSha256,
            sizeBytes: $kernelSize,
            capacityBytes: $kernelCapacity,
            format: $kernelFormat,
            evidence: {
              capacity: $kernelCapacityEvidence,
              format: $kernelFormatEvidence
            }
          },
          ramdisk: {
            file: "ramdisk",
            sha256: $ramdiskSha256,
            sizeBytes: $ramdiskSize,
            capacityBytes: $ramdiskCapacity,
            format: $ramdiskFormat,
            compression: $ramdiskCompression,
            evidence: {
              capacity: $ramdiskCapacityEvidence,
              format: $ramdiskFormatEvidence
            }
          }
        }
      }' > "$out/manifest.json"
  ''
