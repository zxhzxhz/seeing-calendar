#!/usr/bin/env python3
"""版本号自增器：每次更新前跑一次，保证产物可追踪。

用法：
    python scripts/bump_version.py          # 1.0.1 -> 1.0.2（补丁位，默认）
    python scripts/bump_version.py minor    # 1.0.2 -> 1.1.0
    python scripts/bump_version.py major    # 1.1.0 -> 2.0.0
    python scripts/bump_version.py --show   # 只查看当前版本

同时会在 CHANGELOG.md 顶部插入对应的版本小节占位。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = ROOT / "project.yml"
CHANGELOG = ROOT / "CHANGELOG.md"
PATTERN = re.compile(r'(MARKETING_VERSION:\s*")(\d+)\.(\d+)\.(\d+)(")')


def read_version() -> tuple[int, int, int]:
    match = PATTERN.search(PROJECT.read_text(encoding="utf-8"))
    if not match:
        raise SystemExit("project.yml 中未找到 MARKETING_VERSION")
    return int(match.group(2)), int(match.group(3)), int(match.group(4))


def write_version(version: tuple[int, int, int]) -> None:
    text = PROJECT.read_text(encoding="utf-8")
    text = PATTERN.sub(lambda m: f'{m.group(1)}{version[0]}.{version[1]}.{version[2]}{m.group(5)}', text, count=1)
    PROJECT.write_text(text, encoding="utf-8")


def insert_changelog(version: tuple[int, int, int]) -> None:
    if not CHANGELOG.exists():
        return
    text = CHANGELOG.read_text(encoding="utf-8")
    marker = "## [Unreleased]"
    heading = f"## [{version[0]}.{version[1]}.{version[2]}]"
    if heading in text:
        return
    if marker in text:
        text = text.replace(marker, f"{marker}\n\n### 待归档\n\n- （填写本次变更）\n", 1)
    else:
        text = f"# Changelog\n\n{heading}\n\n- （填写本次变更）\n\n" + text
    CHANGELOG.write_text(text, encoding="utf-8")


def main(argv: list[str]) -> int:
    current = read_version()
    if "--show" in argv:
        print(f"{current[0]}.{current[1]}.{current[2]}")
        return 0

    part = "patch"
    for candidate in ("major", "minor", "patch"):
        if candidate in argv:
            part = candidate
            break

    major, minor, patch = current
    if part == "major":
        major, minor, patch = major + 1, 0, 0
    elif part == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1

    write_version((major, minor, patch))
    insert_changelog((major, minor, patch))
    print(f"{current[0]}.{current[1]}.{current[2]} -> {major}.{minor}.{patch}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
