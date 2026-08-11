#!/usr/bin/env python3
"""Decode and query the public Huawei firmware index (`firmwards.hash` datasets).

The datasets are not text, so grepping a downloaded `.hash` file always reports
zero matches regardless of content. Four transforms are stacked:

  1. urlsafe-base64 sextets; each group of 3 characters is one 18-bit
     little-endian code (`c0 | c1 << 6 | c2 << 12`)
  2. classic LZW over a 256-entry byte dictionary. On reaching 2**18 - 1 the
     dictionary resets to 256 entries but `prev` is carried across the reset,
     so the next emitted entry still extends the pre-reset string.
  3. every output byte is shifted by -24 (mod 256)
  4. the result is UTF-8 JSON: a list of fixed-arity records

Two record schemas exist and they are not interchangeable.

Download datasets (`normal`, `base-archive`, `downgrade`) carry CDN locations:

    [romId, "MODEL - REGION", gbcGroup, version, baseUrl, "YYYY/MM/DD"]

`baseUrl` is a directory; the manifest is `baseUrl + "full/filelist.xml"` and it
supplies per-file size, MD5 and SHA-256. `gbcGroup` is the region group of that
*row*, not the set of groups the package serves - a base package's own
`filelist.xml` may declare many `GBCINFO` groups, because Huawei bases are
region-independent and region lives in CUST/PRELOAD.

The search dataset (`v2`) carries component tuples but no CDN location:

    [model, "REGION - gbcGroup", [cust, preload], [[base, cust, preload], ...], _, _]

It is the only dataset that proves which base pairs with which CUST/PRELOAD, so
a build may be confirmed to exist there while being undownloadable anywhere.
"""

import argparse
import json
import sys

ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
SEXTET = {ch: i for i, ch in enumerate(ALPHABET)}
DICT_CAP = (1 << 18) - 1
BYTE_SHIFT = 24


def codes(payload):
    for i in range(0, len(payload) - 2, 3):
        yield (
            SEXTET[payload[i]]
            | (SEXTET[payload[i + 1]] << 6)
            | (SEXTET[payload[i + 2]] << 12)
        )


def lzw_decode(sequence):
    table = {i: bytes([i]) for i in range(256)}
    nxt = 256
    out = bytearray()
    prev = None
    for code in sequence:
        if code in table:
            entry = table[code]
        elif prev is not None:
            entry = prev + prev[:1]
        else:
            raise ValueError(f"unresolvable code {code} with no previous entry")
        out += entry
        if prev is not None:
            table[nxt] = prev + entry[:1]
            nxt += 1
            if nxt >= DICT_CAP:
                table = {i: bytes([i]) for i in range(256)}
                nxt = 256
        prev = entry
    return bytes(out)


def decode(payload):
    raw = lzw_decode(codes(payload.strip()))
    plain = bytes((b - BYTE_SHIFT) & 0xFF for b in raw)
    return json.loads(plain.decode("utf-8"))


def is_search_schema(records):
    return bool(records) and isinstance(records[0][0], str)


def rows(records):
    """Normalise both schemas to dicts with a shared `schema` discriminator."""
    if is_search_schema(records):
        for model, region, current, combos, *_ in records:
            code, _, group = region.partition(" - ")
            for combo in combos:
                yield {
                    "schema": "search",
                    "model": model,
                    "region": code,
                    "gbcGroup": group,
                    "base": combo[0] if len(combo) > 0 else None,
                    "cust": combo[1] if len(combo) > 1 else None,
                    "preload": combo[2] if len(combo) > 2 else None,
                    "installedCust": current[0] if len(current) > 0 else None,
                    "installedPreload": current[1] if len(current) > 1 else None,
                }
        return
    for rom_id, model_region, group, version, base_url, date in records:
        model, _, code = model_region.partition(" - ")
        yield {
            "schema": "download",
            "romId": rom_id,
            "model": model.strip(),
            "region": code.strip(),
            "gbcGroup": group,
            "version": version,
            "baseUrl": base_url,
            "fileListUrl": base_url + "full/filelist.xml",
            "date": date,
        }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dataset", help="path to a firmwards.hash file, or - for stdin")
    ap.add_argument(
        "--match",
        action="append",
        default=[],
        metavar="TEXT",
        help="case-insensitive substring every reported row must contain; repeatable (AND)",
    )
    ap.add_argument("--rom-id", type=int, help="report only this ROM ID")
    ap.add_argument("--json", action="store_true", help="emit matching rows as JSON")
    ap.add_argument(
        "--raw", action="store_true", help="emit the decoded JSON and exit"
    )
    args = ap.parse_args()

    payload = (sys.stdin if args.dataset == "-" else open(args.dataset)).read()
    records = decode(payload)

    if args.raw:
        json.dump(records, sys.stdout, ensure_ascii=False)
        return

    needles = [n.lower() for n in args.match]
    hits, total = [], 0
    for row in rows(records):
        total += 1
        if args.rom_id is not None and row.get("romId") != args.rom_id:
            continue
        blob = " ".join(str(v) for v in row.values()).lower()
        if all(n in blob for n in needles):
            hits.append(row)

    if args.json:
        json.dump(hits, sys.stdout, ensure_ascii=False, indent=2)
        return

    schema = "search" if is_search_schema(records) else "download"
    print(f"{args.dataset}: {schema} schema, {len(records)} records, {total} rows")
    print(f"matching: {len(hits)}")
    seen = set()
    for row in hits:
        key = tuple(sorted(row.items(), key=lambda kv: kv[0]))
        if key in seen:
            continue
        seen.add(key)
        if schema == "download":
            print(
                f"  {row['romId']} {row['model']} {row['region']} "
                f"{row['gbcGroup']} {row['version']} {row['date']}"
            )
            print(f"      {row['fileListUrl']}")
        else:
            print(
                f"  {row['model']} {row['region']} {row['gbcGroup']} "
                f"{row['base']} + {row['cust']} + {row['preload']}"
            )


if __name__ == "__main__":
    main()
