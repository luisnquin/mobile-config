{
  coreutils,
  jq,
  lib,
  runCommand,
}: {
  kernel,
  ramdisk,
  # This device has two device trees, on two partitions: `dts` holds the base
  # FDT and `dto` an Android DTBO container the bootloader picks an entry from.
  # Neither is a payload built here - both stay stock - but the kernel is a bare
  # Image.gz with no appended DT, so it cannot boot without them and a boot set
  # that does not name them is under-described. Required, not optional, so the
  # pair has to be stated before this builder can produce a manifest at all.
  deviceTrees,
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
assert lib.assertMsg (
  builtins.isAttrs deviceTrees
  && lib.all (side: builtins.hasAttr side deviceTrees && builtins.isAttrs deviceTrees.${side}) [
    "base"
    "overlay"
  ]
) "deviceTrees must describe both the base and the overlay";
assert lib.assertMsg (
  builtins.isString deviceTrees.base.partition
  && deviceTrees.base.partition != ""
  && builtins.isString deviceTrees.overlay.partition
  && deviceTrees.overlay.partition != ""
) "each device tree must name the partition it is read from";
# `ro.boot.dtbo_idx` is an index into whichever DTO happened to be installed,
# and it does not survive a firmware change: in the `.563` package this board is
# at 329 while 26 is a different board. Selecting by index is therefore how you
# boot someone else's device tree, so the contract only accepts a board ID.
assert lib.assertMsg (
  deviceTrees.overlay.selectedBy == "board-id" && builtins.isInt deviceTrees.overlay.boardId
) "the overlay must be selected by integer board ID, never by table index";
  runCommand "huawei-marie-split-images" {
    nativeBuildInputs = [
      coreutils
      jq
    ];
    deviceTreesJson = builtins.toJSON deviceTrees;
    passthru.contract = {
      inherit
        deviceTrees
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
      --argjson deviceTrees "$deviceTreesJson" \
      '{
        schema: 2,
        layout: "huawei-split",
        flashCommandsIncluded: false,
        requiredNotWritten: {
          deviceTrees: $deviceTrees
        },
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
