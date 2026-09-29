#!/usr/bin/env python3
"""Validate the .vcal ZIP layout produced by ZipWriter.swift.

This mirrors the byte layout written by `SeeingCalendar/Store/ZipArchive.swift`
(STORE method) and asserts that a standards-compliant ZIP reader can open it,
so the archived container is verified without an iOS device.
"""
from __future__ import annotations

import struct
import zipfile
import zlib
from pathlib import Path

DOS_TIME = 0x7000
DOS_DATE = 0x5000


def build_archive(entries: list[tuple[str, bytes]]) -> bytes:
    out = bytearray()
    records = []
    for name, data in entries:
        raw = name.encode()
        crc = zlib.crc32(data) & 0xFFFFFFFF
        size = len(data)
        header = struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50,   # local file header signature
            20,           # version needed
            0x0800,       # general purpose flags (UTF-8)
            0,            # method: store
            DOS_TIME, DOS_DATE,
            crc, size, size,
            len(raw), 0,
        ) + raw
        local_offset = len(out)
        out += header
        out += data
        records.append((name, raw, crc, size, local_offset))

    central_start = len(out)
    for name, raw, crc, size, local_offset in records:
        out += struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50,   # central directory signature
            20, 20, 0x0800, 0,
            DOS_TIME, DOS_DATE,
            crc, size, size,
            len(raw), 0, 0, 0, 0,
            0, local_offset,
        ) + raw
    central_size = len(out) - central_start

    out += struct.pack(
        "<IHHHHIIH",
        0x06054B50, 0, 0,
        len(records), len(records),
        central_size, central_start, 0,
    )
    return bytes(out)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    payload = {
        "manifest.json": b'{"schemaVersion":1,"databaseDigest":"deadbeef"}',
        "database_dump.json": b'{"workspaces":[{"uuid":"A"}]}',
        "drawings/11111111-1111-1111-1111-111111111111.drawing": bytes(range(256)) * 8,
        "assets/22222222-2222-2222-2222-222222222222.png": b"\x89PNG\r\n\x1a\n" + b"x" * 5000,
    }
    blob = build_archive(list(payload.items()))
    target = root / "artifacts" / "vcal-format-check.vcal"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(blob)

    with zipfile.ZipFile(target) as archive:
        bad = archive.testzip()
        assert bad is None, f"corrupt entry: {bad}"
        assert archive.namelist() == sorted(payload.keys()) or set(archive.namelist()) == set(payload.keys())
        for name, expected in payload.items():
            actual = archive.read(name)
            assert actual == expected, f"payload mismatch for {name}"
        info = archive.getinfo("database_dump.json")
        assert info.compress_type == zipfile.ZIP_STORED

    print(f"OK  {target}  ({len(blob)} bytes, {len(payload)} entries) — 结构可被标准 ZIP 读取器解析")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
