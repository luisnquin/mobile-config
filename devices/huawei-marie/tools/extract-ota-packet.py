#!/usr/bin/env python3

"""Extract named packets from a Huawei OTA ZIP or raw UPDATE.APP.

Companion to `inspect-ota.py`, which deliberately never writes. Extraction is
kept separate so inspection stays side-effect free, and every payload written
here reports its SHA-256 so it can be checked against an inspection report.

The packet walk mirrors `inspect-ota.py`: a 60-byte fixed header whose first
four bytes are the magic, a variable header tail whose first 16 bytes are the
packet name, the payload, then zero padding to a 4-byte boundary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import BinaryIO, Iterator
from zipfile import BadZipFile, ZipFile

MAGIC = b"\x55\xaa\x5a\xa5"
BUFFER_SIZE = 1024 * 1024
FIXED_HEADER_SIZE = 60
NAME_SIZE = 16


class ExtractionError(Exception):
    pass


def find_magic(stream: BinaryIO) -> int:
    offset = 0
    overlap = b""
    while block := stream.read(BUFFER_SIZE):
        window = overlap + block
        index = window.find(MAGIC)
        if index >= 0:
            return offset - len(overlap) + index
        overlap = window[-(len(MAGIC) - 1) :]
        offset += len(block)
    raise ExtractionError("Huawei UPDATE.APP magic not found")


def walk(stream: BinaryIO, size: int) -> Iterator[tuple[str, int, int]]:
    """Yield (name, payloadOffset, dataLength) for every packet in order."""
    offset = find_magic(stream)
    stream.seek(offset)

    while True:
        fixed = stream.read(FIXED_HEADER_SIZE)
        if len(fixed) != FIXED_HEADER_SIZE or fixed[:4] != MAGIC:
            raise ExtractionError(f"invalid packet header at offset {offset}")

        header_length = struct.unpack_from("<I", fixed, 4)[0]
        data_length = struct.unpack_from("<I", fixed, 24)[0]
        if header_length < FIXED_HEADER_SIZE + NAME_SIZE:
            raise ExtractionError(
                f"invalid header length {header_length} at offset {offset}"
            )

        header_tail = stream.read(header_length - FIXED_HEADER_SIZE)
        if len(header_tail) != header_length - FIXED_HEADER_SIZE:
            raise ExtractionError(f"truncated packet header at offset {offset}")

        name = header_tail[:NAME_SIZE].split(b"\0", 1)[0].decode("ascii", "replace")
        yield name, offset + header_length, data_length

        packet_end = offset + header_length + data_length
        padding = (-packet_end) % 4
        stream.seek(packet_end + padding)
        offset = packet_end + padding
        if offset >= size:
            return


def copy_payload(stream: BinaryIO, length: int, target: Path | None) -> str:
    digest = hashlib.sha256()
    remaining = length
    handle = target.open("wb") if target is not None else None
    try:
        while remaining:
            block = stream.read(min(BUFFER_SIZE, remaining))
            if not block:
                raise ExtractionError(
                    f"truncated payload: {length - remaining} of {length} bytes"
                )
            digest.update(block)
            if handle is not None:
                handle.write(block)
            remaining -= len(block)
    finally:
        if handle is not None:
            handle.close()
    return digest.hexdigest()


def extract(stream: BinaryIO, size: int, wanted: set[str], out: Path | None) -> list:
    results = []
    seen = set()
    for name, payload_offset, data_length in walk(stream, size):
        if wanted and name not in wanted:
            continue
        seen.add(name)
        target = None if out is None else out / f"{name}.img"
        stream.seek(payload_offset)
        sha256 = copy_payload(stream, data_length, target)
        results.append(
            {
                "name": name,
                "offset": payload_offset,
                "size": data_length,
                "sha256": sha256,
                "path": None if target is None else str(target),
            }
        )
        # UPDATE.APP is deflated inside the ZIP, so walking past the last wanted
        # packet costs a full decompression of everything after it.
        if wanted and seen >= wanted:
            break
    missing = sorted(wanted - seen)
    if missing:
        raise ExtractionError(f"packets not present: {', '.join(missing)}")
    return results


def open_source(path: Path):
    """Return (stream, size) for a raw UPDATE.APP or the one inside an OTA ZIP."""
    with path.open("rb") as probe:
        signature = probe.read(4)

    if signature != b"PK\x03\x04":
        stream = path.open("rb")
        return stream, path.stat().st_size

    try:
        archive = ZipFile(path)
    except BadZipFile as error:
        raise ExtractionError(str(error)) from error
    matches = [
        info
        for info in archive.infolist()
        if Path(info.filename).name.upper() == "UPDATE.APP"
    ]
    if len(matches) != 1:
        raise ExtractionError(f"archive has {len(matches)} UPDATE.APP entries")
    # ZipExtFile is seekable for stored and deflated entries in CPython.
    return archive.open(matches[0]), matches[0].file_size


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path)
    parser.add_argument(
        "--packet",
        action="append",
        default=[],
        metavar="NAME",
        help="packet name to extract; repeatable. Omit to act on every packet.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="directory to write <NAME>.img into. Omit to hash without writing.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.source.is_file():
        print(f"error: source is not a file: {args.source}", file=sys.stderr)
        return 2
    if args.output_dir is not None:
        args.output_dir.mkdir(parents=True, exist_ok=True)

    try:
        stream, size = open_source(args.source)
        with stream:
            results = extract(stream, size, set(args.packet), args.output_dir)
    except (ExtractionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    json.dump(results, sys.stdout, indent=2, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
