#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import BinaryIO, TypedDict
from zipfile import BadZipFile, ZipFile


MAGIC = b"\x55\xaa\x5a\xa5"
BUFFER_SIZE = 1024 * 1024
FIXED_HEADER_SIZE = 60
NAME_SIZE = 16


class InspectionError(Exception):
    pass


class StreamDigest(TypedDict):
    sha256: str
    size: int


def digest_stream(stream: BinaryIO, limit: int | None = None) -> StreamDigest:
    digest = hashlib.sha256()
    size = 0
    while limit is None or size < limit:
        amount = BUFFER_SIZE if limit is None else min(BUFFER_SIZE, limit - size)
        block = stream.read(amount)
        if not block:
            break
        digest.update(block)
        size += len(block)
    if limit is not None and size != limit:
        raise InspectionError(f"truncated payload: expected {limit} bytes, read {size}")
    return {"sha256": digest.hexdigest(), "size": size}


def find_magic(stream: BinaryIO) -> tuple[int, bytes]:
    offset = 0
    overlap = b""
    while block := stream.read(BUFFER_SIZE):
        window = overlap + block
        index = window.find(MAGIC)
        if index >= 0:
            absolute = offset - len(overlap) + index
            stream.seek(absolute)
            return absolute, stream.read(len(MAGIC))
        overlap = window[-(len(MAGIC) - 1) :]
        offset += len(block)
    raise InspectionError("Huawei UPDATE.APP magic not found")


def decode_field(value: bytes) -> str:
    return value.split(b"\0", 1)[0].decode("ascii", errors="replace")


def inspect_update_app(stream: BinaryIO, size: int) -> dict[str, object]:
    leading_size, magic = find_magic(stream)
    packets: list[dict[str, object]] = []
    offset = leading_size

    while magic == MAGIC:
        fixed_tail = stream.read(FIXED_HEADER_SIZE - len(MAGIC))
        if len(fixed_tail) != FIXED_HEADER_SIZE - len(MAGIC):
            raise InspectionError(f"truncated packet header at offset {offset}")

        fixed = magic + fixed_tail
        header_length, unknown = struct.unpack_from("<II", fixed, 4)
        data_length = struct.unpack_from("<I", fixed, 24)[0]
        if header_length < FIXED_HEADER_SIZE + NAME_SIZE:
            raise InspectionError(
                f"invalid header length {header_length} at offset {offset}"
            )
        if offset + header_length + data_length > size:
            raise InspectionError(f"packet at offset {offset} exceeds UPDATE.APP size")

        header_tail = stream.read(header_length - FIXED_HEADER_SIZE)
        if len(header_tail) != header_length - FIXED_HEADER_SIZE:
            raise InspectionError(f"truncated packet header at offset {offset}")

        payload = digest_stream(stream, data_length)
        packet_end = offset + header_length + data_length
        padding_length = (-packet_end) % 4
        padding = stream.read(padding_length)
        if len(padding) != padding_length:
            raise InspectionError(f"truncated packet padding at offset {packet_end}")
        if any(padding):
            raise InspectionError(f"non-zero packet padding at offset {packet_end}")

        packets.append(
            {
                "offset": offset,
                "headerLength": header_length,
                "unknown": unknown,
                "hardwareId": fixed[12:20].hex(),
                "sequence": fixed[20:24].hex(),
                "dataLength": data_length,
                "date": decode_field(fixed[28:44]),
                "time": decode_field(fixed[44:60]),
                "name": decode_field(header_tail[:NAME_SIZE]),
                "payloadSha256": payload["sha256"],
                "paddingLength": padding_length,
            }
        )

        offset = packet_end + padding_length
        if offset == size:
            magic = b""
            break
        magic = stream.read(len(MAGIC))
        if magic != MAGIC:
            raise InspectionError(f"invalid packet magic at offset {offset}")

    if not packets:
        raise InspectionError("UPDATE.APP contains no packets")

    return {
        "size": size,
        "leadingBytes": leading_size,
        "packetCount": len(packets),
        "packets": packets,
    }


def digest_path(path: Path) -> StreamDigest:
    with path.open("rb") as stream:
        return digest_stream(stream)


def inspect_raw(path: Path) -> dict[str, object]:
    source = digest_path(path)
    with path.open("rb") as stream:
        update_app = inspect_update_app(stream, source["size"])
    update_app["sha256"] = source["sha256"]
    return {
        "format": "update.app",
        "source": str(path),
        "sourceSha256": source["sha256"],
        "sourceSize": source["size"],
        "updateApp": update_app,
    }


def locate_entry(archive: ZipFile, basename: str) -> str | None:
    matches = [
        info.filename
        for info in archive.infolist()
        if Path(info.filename).name.upper() == basename
    ]
    if len(matches) > 1:
        raise InspectionError(f"archive contains multiple {basename} entries")
    return matches[0] if matches else None


def inspect_zip(path: Path, expected_version: str | None) -> dict[str, object]:
    source = digest_path(path)
    try:
        with ZipFile(path) as archive:
            update_name = locate_entry(archive, "UPDATE.APP")
            if update_name is None:
                raise InspectionError("archive has no UPDATE.APP entry")

            version_name = locate_entry(archive, "VERSION.MBN")
            version = None
            if version_name is not None:
                version = archive.read(version_name).decode("utf-8").strip()
            if expected_version is not None and version != expected_version:
                raise InspectionError(
                    f"version mismatch: expected {expected_version!r}, got {version!r}"
                )

            update_info = archive.getinfo(update_name)
            with archive.open(update_info) as stream:
                update_digest = digest_stream(stream, update_info.file_size)
            with archive.open(update_info) as stream:
                update_app = inspect_update_app(stream, update_info.file_size)
            update_app["sha256"] = update_digest["sha256"]

            entries = [
                {
                    "name": info.filename,
                    "size": info.file_size,
                    "compressedSize": info.compress_size,
                    "crc32": f"{info.CRC:08x}",
                }
                for info in archive.infolist()
            ]
    except (BadZipFile, UnicodeDecodeError) as error:
        raise InspectionError(str(error)) from error

    return {
        "format": "zip",
        "source": str(path),
        "sourceSha256": source["sha256"],
        "sourceSize": source["size"],
        "version": version,
        "updateAppEntry": update_name,
        "updateAppZipCrcVerified": True,
        "entries": entries,
        "updateApp": update_app,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inspect a Huawei OTA ZIP or raw UPDATE.APP without extracting it"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--expected-version")
    parser.add_argument("--compact", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source: Path = args.source
    expected_version: str | None = args.expected_version
    compact: bool = args.compact

    if not source.is_file():
        print(f"error: source is not a file: {source}", file=sys.stderr)
        return 2

    try:
        with source.open("rb") as stream:
            signature = stream.read(4)
        if signature != b"PK\x03\x04" and expected_version is not None:
            raise InspectionError("--expected-version requires an OTA ZIP")
        report = (
            inspect_zip(source, expected_version)
            if signature == b"PK\x03\x04"
            else inspect_raw(source)
        )
    except (InspectionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    json.dump(
        report,
        sys.stdout,
        indent=None if compact else 2,
        separators=(",", ":") if compact else None,
        sort_keys=True,
    )
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
